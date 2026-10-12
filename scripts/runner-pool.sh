#!/usr/bin/env bash
# 本机 runner 池（pm2 常驻，装法见 README「本机 runner」）：仓库变量 GHWF_RUNNER 设成 ghwf-local 的私有仓库，
# 在主人 Mac 的 colima 虚拟机里常备一个空闲 runner，流水线的 job 派到这里跑，不花 GitHub 的分钟。
# 每个容器是一个 JIT runner：只接一个 job，跑完容器就删，下一个 job 拿全新的容器（跟 GitHub 的 runner 一样不留东西）。
# 每个仓库始终留一个空闲的，忙的另算：合并环节会占着 runner 等 CI（最多 30 分钟），只有一个就互相等死。
# 注册用主人本机 gh 的登录（要仓库 admin 权限）；容器只拿到一次性的 JIT 配置，碰不到任何令牌。
# 只看私有仓库：公开仓库谁都能提 PR，陌生人的代码不能在主人的 Mac 上跑。
set -euo pipefail

LABEL="${GHWF_LABEL:-ghwf-local}"
OWNER="${OWNER:-Melodymaifafa}"
# 容器总数上限 = 名单上的仓库数（每个一个空闲的）+ MAX_EXTRA_RUNNERS。空闲的随时会接 job，所以这也是同时跑的 job 上限；
# 跟着仓库数走，开的仓库再多也人人有一个。
MAX_EXTRA_RUNNERS="${MAX_EXTRA_RUNNERS:-4}"
JOB_MEMORY="${JOB_MEMORY:-3g}"       # 单个 job 的内存上限，免得一个 job 撑爆整个虚拟机
REFRESH_SECONDS="${REFRESH_SECONDS:-600}"
here="$(cd "$(dirname "$0")" && pwd)"
context_dir="$here/../runner"
state="${RUNNER_POOL_STATE:-$HOME/.local/state/ghwf-runner-pool}"
secrets="${GH_WORKFLOWS_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"
# 钉死 colima：主人开 Docker Desktop 会把 docker 的默认 context 换走。
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.colima/default/docker.sock}"

gh_owner() { env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"; }

notify() {
  (
    # shellcheck source=/dev/null
    [ -r "$secrets" ] && . "$secrets"
    if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then exit 0; fi
    curl -sf -X POST https://api.pushover.net/1/messages.json \
      --form-string "token=${PUSHOVER_TOKEN}" --form-string "user=${PUSHOVER_USER}" \
      --form-string "title=$1" --form-string "message=$2" >/dev/null
  ) || echo "Pushover 发送失败" >&2
}

# alert <原因> <标题> <正文>：同一原因只推一次，直到 recover 清掉。
alert() {
  echo "$3" >&2
  [ -e "$state/alert-$1" ] && return 0
  notify "$2" "$3"
  touch "$state/alert-$1"
}
recover() {
  [ -e "$state/alert-$1" ] || return 0
  rm -f "$state/alert-$1"
  notify "🤖 本机 runner 恢复了" "$2"
}

ensure_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "连不上 colima 里的 docker，启动 colima"
  colima start >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1
}

# 镜像按 Dockerfile 的内容打标签，改了 Dockerfile 就自动重建。
ensure_image() {
  image="ghwf-runner:$(shasum -a 256 "$context_dir/Dockerfile" | cut -c1-12)"
  docker image inspect "$image" >/dev/null 2>&1 && return 0
  echo "构建镜像 $image"
  docker build -q -t "$image" "$context_dir" >/dev/null
}

# 主人的 Mac 磁盘不大，每个 job 都要下依赖：空间不够就先不补 runner，已经空闲着的照样接 job。
check_disk() {
  local free_gb
  free_gb=$(($(df -k "$HOME" | awk 'NR == 2 { print $4 }') / 1048576))
  if [ "$free_gb" -lt "${MIN_FREE_GB:-5}" ]; then
    alert disk "🤖 Mac 磁盘快满了" "只剩 ${free_gb} GB，本机 runner 先不接新 job。清出空间后自己恢复。"
    return 1
  fi
  recover disk "磁盘空间够了，本机 runner 接着接 job。"
}

# 容器都是 --rm，攒下的只有改 Dockerfile 后的旧镜像。只删本池的（colima 也许还跑着主人别的东西）；
# 还在用的镜像删不掉，忽略报错。
prune() {
  local old
  for old in $(docker images ghwf-runner --format '{{.Repository}}:{{.Tag}}'); do
    [ "$old" = "$image" ] || docker rmi "$old" >/dev/null 2>&1 || true
  done
  docker image prune -f --filter label=ghwf.pool=1 >/dev/null 2>&1 || true
}

# 重读名单：私有仓库里 GHWF_RUNNER 等于本池标签的。单个仓库读失败（不是 404）就照旧留着它。
refresh_repos() {
  local all repo out
  all="$(gh_owner repo list "$OWNER" --visibility private --no-archived --limit 300 --json name --jq '.[].name')" || return 1
  : >"$state/repos.new"
  for repo in $all; do
    if out="$(gh_owner api "repos/$OWNER/$repo/actions/variables/GHWF_RUNNER" --jq .value 2>&1)"; then
      [ "$out" = "$LABEL" ] && echo "$repo" >>"$state/repos.new"
    else
      case "$out" in
        *"HTTP 404"*) ;;
        *) grep -qxF "$repo" "$state/repos" 2>/dev/null && echo "$repo" >>"$state/repos.new" ;;
      esac
    fi
  done
  mv "$state/repos.new" "$state/repos"
}

# 池里每个容器一行「容器名 仓库 idle|busy」。runner 接到 job 会打出 Running job。
list_runners() {
  local name repo
  docker ps --filter label=ghwf.pool=1 --format '{{.Names}} {{.Label "ghwf.repo"}}' |
    while read -r name repo; do
      [ -n "$name" ] || continue
      if docker logs "$name" 2>&1 | grep -q 'Running job'; then
        echo "$name $repo busy"
      else
        echo "$name $repo idle"
      fi
    done
}

# decide <名单文件> <容器总数上限>，stdin 是 list_runners 的输出。输出：
#   remove <容器名>   仓库撤了变量，收掉它空闲的
#   spawn <仓库>      给没空闲 runner 的仓库补一个
#   reclaim <容器名> <仓库>  满了：收掉一个「没 job 在跑的仓库」的空闲 runner，腾给有 job 在跑的这个仓库 ——
#                     runner 只服务注册它的那个仓库，那边的 job 可能正占着 runner 等同仓库的 CI
#   full <仓库>       满了，又没得腾，排队等
decide() {
  local repos_file=$1 max_runners=$2 rows total name repo st victim used=" "
  rows="$(cat)"
  total="$(printf '%s\n' "$rows" | awk 'NF' | wc -l | tr -d ' ')"
  while read -r name repo st; do
    [ -n "$name" ] || continue
    [ "$st" = idle ] || continue
    grep -qxF "$repo" "$repos_file" && continue
    echo "remove $name"
    total=$((total - 1))
    used="$used$name "
  done <<<"$rows"
  while read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s\n' "$rows" | awk -v r="$repo" '$2 == r && $3 == "idle" { f = 1 } END { exit !f }' && continue
    if [ "$total" -lt "$max_runners" ]; then
      echo "spawn $repo"
      total=$((total + 1))
      continue
    fi
    victim=
    if printf '%s\n' "$rows" | awk -v r="$repo" '$2 == r && $3 == "busy" { f = 1 } END { exit !f }'; then
      victim="$(printf '%s\n' "$rows" | awk -v used="$used" '
        $3 == "busy" { hot[$2] = 1 }
        $3 == "idle" { idle[NR] = $1; owner[NR] = $2 }
        END {
          for (i = 1; i <= NR; i++)
            if ((i in idle) && !(owner[i] in hot) && index(used, " " idle[i] " ") == 0) { print idle[i]; exit }
        }')"
    fi
    if [ -n "$victim" ]; then
      echo "reclaim $victim $repo"
      used="$used$victim "
    else
      echo "full $repo"
    fi
  done <"$repos_file"
}

spawn() {
  local repo=$1 name jit
  name="ghwf-${repo}-$(date +%s)"
  jit="$(gh_owner api -X POST "repos/$OWNER/$repo/actions/runners/generate-jitconfig" \
    -f name="$name" -F runner_group_id=1 -f 'labels[]=self-hosted' -f "labels[]=$LABEL" \
    -f work_folder=../work --jq .encoded_jit_config)" || return 1
  docker run -d --rm --name "$name" --label ghwf.pool=1 --label "ghwf.repo=$repo" \
    --memory "$JOB_MEMORY" "$image" --jitconfig "$jit" >/dev/null
}

tick() {
  local action target for_repo spawn_failed=
  while read -r action target for_repo; do
    case "$action" in
      # 刚才那一眼之后它也许接到了 job：接到了就不收；reclaim 收不成就不补，下一轮重看
      remove)
        docker logs "$target" 2>&1 | grep -q 'Running job' ||
          { docker rm -f "$target" >/dev/null && echo "收掉 $target（仓库撤了 GHWF_RUNNER）"; } ;;
      reclaim)
        docker logs "$target" 2>&1 | grep -q 'Running job' && continue
        docker rm -f "$target" >/dev/null || continue
        echo "满了，收掉闲着的 $target 腾给 $for_repo"
        if spawn "$for_repo"; then echo "给 $for_repo 补了一个空闲 runner"; else spawn_failed="$for_repo"; fi ;;
      spawn)
        if spawn "$target"; then echo "给 $target 补了一个空闲 runner"; else spawn_failed="$target"; fi ;;
      full) ;;  # 满了就等，不刷屏
    esac
  done < <(list_runners | decide "$state/repos" "$(($(awk 'NF' "$state/repos" | wc -l) + MAX_EXTRA_RUNNERS))")
  if [ -n "$spawn_failed" ]; then
    alert register "🤖 本机 runner 注册不上" "给 ${spawn_failed} 注册 runner 失败，私有仓库的 job 会一直排队。多半是本机 gh 登录失效：在 Mac 上 gh auth login。"
  else
    recover register "又能注册 runner 了。"
  fi
}

main() {
  mkdir -p "$state"
  local last_refresh=0 now
  while :; do
    if ensure_docker && ensure_image; then
      recover docker "colima 里的 docker 又连上了。"
      now="$(date +%s)"
      if [ $((now - last_refresh)) -ge "$REFRESH_SECONDS" ]; then
        last_refresh="$now"
        refresh_repos || echo "读不到仓库名单，沿用上一份" >&2
        prune
      fi
      [ -f "$state/repos" ] && check_disk && tick
    else
      alert docker "🤖 本机 runner 停了" "colima 里的 docker 起不来，私有仓库的 job 会一直排队（最多 24 小时后 GitHub 取消）。在 Mac 上跑 colima start 看报错。"
    fi
    sleep 15
  done
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main
