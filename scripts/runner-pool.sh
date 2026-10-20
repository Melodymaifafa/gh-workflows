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
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    curl -q -sf -X POST https://api.pushover.net/1/messages.json \
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
image="ghwf-runner:$(shasum -a 256 "$context_dir/Dockerfile" | cut -c1-12)"
# 用本池专用的 builder 建：建完（成不成都）清掉它的缓存、停掉它，主人别的构建缓存不碰。
ensure_image() {
  local builder=ghwf-runner rc=0
  docker image inspect "$image" >/dev/null 2>&1 && return 0
  echo "构建镜像 $image"
  docker buildx inspect "$builder" >/dev/null 2>&1 ||
    docker buildx create --name "$builder" --driver docker-container >/dev/null
  docker buildx build --builder "$builder" --load -q -t "$image" "$context_dir" >/dev/null || rc=$?
  docker buildx prune --builder "$builder" -af >/dev/null 2>&1 || true
  docker buildx stop "$builder" >/dev/null 2>&1 || true
  return "$rc"
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
  # job 删掉的数据只在虚拟机里腾出地方，Mac 上的磁盘文件不会自己缩：不 trim 就只涨不缩
  # （2026-10-12 实测 19 GB，里面只用了 9 GB；trim 一次回到 4 GB）
  colima ssh -- sudo fstrim -a >/dev/null 2>&1 || true
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

# runner 接到 job 会打出 Running job。用 grep -c 把日志读完：grep -q 一匹配就走，
# 日志长了 docker logs 吃 SIGPIPE，pipefail 下整条判成「没接到」，会把在跑的 job 当空闲的收掉。
took_job() { docker logs "$1" 2>&1 | grep -c 'Running job' >/dev/null; }

# 池里每个容器一行「容器名 仓库 idle|busy|stale」。stale = 空闲、但用的不是现在的镜像：
# 不收掉的话，改了 Dockerfile 要等它们哪天接到 job 才换新（2026-10-12 补 yaml 时旧的空闲 runner 会接着红）。
list_runners() {
  local name repo img
  docker ps --filter label=ghwf.pool=1 --format '{{.Names}} {{.Label "ghwf.repo"}} {{.Image}}' |
    while read -r name repo img; do
      [ -n "$name" ] || continue
      if took_job "$name"; then
        echo "$name $repo busy"
      elif [ "$img" != "$image" ]; then
        echo "$name $repo stale"
      else
        echo "$name $repo idle"
      fi
    done
}

# decide <名单文件> <容器总数上限>，stdin 是 list_runners 的输出。输出：
#   remove <容器名>   收掉空闲的：仓库撤了变量，或镜像旧了（stale，它的仓库照常补一个新的）
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
    case "$st" in
      stale) ;;
      idle) grep -qxF "$repo" "$repos_file" && continue ;;
      *) continue ;;
    esac
    # 不在这一轮把它的位置让出去：它也许正好接到 job，收不成（下一轮它要么没了，要么算忙的）
    echo "remove $name"
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
  local action target for_repo rows spawn_failed=
  # docker ps 偶尔失败时 rows 是空的，decide 会当成一个 runner 都没有、给每个仓库重开一套
  rows="$(list_runners)" || { echo "列不出池里的容器，这一轮不补" >&2; return 0; }
  while read -r action target for_repo; do
    case "$action" in
      # 刚才那一眼之后它也许接到了 job：接到了就不收；reclaim 收不成就不补，下一轮重看
      remove)
        took_job "$target" ||
          { docker rm -f "$target" >/dev/null && echo "收掉空闲的 $target（仓库撤了 GHWF_RUNNER，或镜像旧了）"; } ;;
      reclaim)
        took_job "$target" && continue
        docker rm -f "$target" >/dev/null || continue
        echo "满了，收掉闲着的 $target 腾给 $for_repo"
        if spawn "$for_repo"; then echo "给 $for_repo 补了一个空闲 runner"; else spawn_failed="$for_repo"; fi ;;
      spawn)
        if spawn "$target"; then echo "给 $target 补了一个空闲 runner"; else spawn_failed="$target"; fi ;;
      full) ;;  # 满了就等，不刷屏
    esac
  done < <(decide "$state/repos" "$(($(awk 'NF' "$state/repos" | wc -l) + MAX_EXTRA_RUNNERS))" <<<"$rows")
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
    if ! ensure_docker; then
      alert docker "🤖 本机 runner 停了" "colima 里的 docker 起不来，私有仓库的 job 会一直排队（最多 24 小时后 GitHub 取消）。在 Mac 上跑 colima start 看报错。"
      sleep 15
      continue
    fi
    recover docker "colima 里的 docker 又连上了。"
    now="$(date +%s)"
    if [ $((now - last_refresh)) -ge "$REFRESH_SECONDS" ]; then
      last_refresh="$now"
      refresh_repos || echo "读不到仓库名单，沿用上一份" >&2
      prune
    fi
    # 先看磁盘再构建：构建要下 Ubuntu 的包，正是磁盘守的那点空间
    if [ -f "$state/repos" ] && check_disk; then
      if ensure_image; then
        recover image "runner 镜像又建好了。"
        tick
      else
        alert image "🤖 本机 runner 镜像建不出来" "docker build ${image} 失败，私有仓库的 job 会一直排队。在 Mac 上到 gh-workflows 跑 docker build runner/ 看报错。"
      fi
    fi
    sleep 15
  done
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main
