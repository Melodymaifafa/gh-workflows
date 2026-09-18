# shellcheck shell=bash
# 假命令（gh / curl / sleep / date）共用的函数。被 source，不单独执行。
# 必须兼容 bash 3.2（macOS 自带的 bash），CI 上是 bash 5。

fake_die() {
  echo "FAKE: $*" >&2
  exit 97
}

fake_require_env() {
  if [ -z "${FAKE_DIR:-}" ] || [ -z "${FAKE_GH_DIR:-}" ] || [ -z "${FAKE_LOG:-}" ]; then
    fake_die "$1 called without setup_fake_env (FAKE_DIR/FAKE_GH_DIR/FAKE_LOG unset)"
  fi
}

# 路由 → 文件名：去掉开头的 /，[A-Za-z0-9._-] 以外的字符一律换成 _。
# repos/o/r/issues/7/comments?per_page=100 → repos_o_r_issues_7_comments_per_page_100
fake_route_key() {
  local r="${1#/}"
  printf '%s' "$r" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'
}

# 日志一行一次调用：换行写成 \n，制表符写成 \t。
fake_escape() {
  local s="$1"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# fake_log <line> [body]：追加一行日志；body 另存到 $FAKE_DIR/bodies/<行号>。
fake_log() {
  local n
  mkdir -p "$FAKE_DIR/bodies"
  printf '%s\n' "$(fake_escape "$1")" >>"$FAKE_LOG"
  n="$(wc -l <"$FAKE_LOG" | tr -d ' ')"
  if [ "$#" -ge 2 ]; then
    printf '%s' "$2" >"$FAKE_DIR/bodies/$n"
  fi
}

# fake_next_count <counter-name>：该计数器 +1 后输出新值（从 1 开始）。
fake_next_count() {
  local f="$FAKE_DIR/state/count_$1" n=0
  mkdir -p "$FAKE_DIR/state"
  [ -f "$f" ] && n="$(cat "$f")"
  n=$((n + 1))
  echo "$n" >"$f"
  echo "$n"
}

# fake_slot <dir> <key> <n>：选出第 n 次调用该用的响应「槽」（不带扩展名的路径）。
# 有 key.N.* 就是序列模式：取 key.n，超过最后一个就一直重复最后一个；
# 否则用 key.*；什么都没有输出空串。
fake_slot() {
  local dir="$1" key="$2" n="$3" f base max=0 i
  if [ -e "$dir/$key.$n.json" ] || [ -e "$dir/$key.$n.out" ] || [ -e "$dir/$key.$n.exit" ]; then
    echo "$dir/$key.$n"
    return
  fi
  for f in "$dir/$key".[0-9]*.*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    i="${base#"$key".}"
    i="${i%%.*}"
    case "$i" in *[!0-9]*|'') continue ;; esac
    [ "$i" -gt "$max" ] && max="$i"
  done
  if [ "$max" -gt 0 ]; then
    echo "$dir/$key.$max"
    return
  fi
  if [ -e "$dir/$key.json" ] || [ -e "$dir/$key.out" ] || [ -e "$dir/$key.exit" ]; then
    echo "$dir/$key"
  fi
}

# 找到 PATH 里下一个同名真命令（跳过假命令自己）。
fake_real_cmd() {
  local name="$1" self="$2" dir old_ifs="$IFS"
  IFS=:
  for dir in $PATH; do
    IFS="$old_ifs"
    [ -x "$dir/$name" ] || continue
    [ "$dir/$name" -ef "$self" ] && continue
    echo "$dir/$name"
    return 0
  done
  IFS="$old_ifs"
  return 1
}

# 假时钟：FAKE_NOW（ISO 8601 或 @epoch）+ 假 sleep 累计的秒数。没设 FAKE_NOW 时返回 1。
fake_clock_epoch() {
  local base off=0
  [ -n "${FAKE_NOW:-}" ] || return 1
  base="$(fake_parse_epoch "$FAKE_NOW")" || fake_die "FAKE_NOW='$FAKE_NOW' is not ISO 8601 or @epoch"
  [ -f "$FAKE_DIR/state/clock_offset" ] && off="$(cat "$FAKE_DIR/state/clock_offset")"
  echo $((base + off))
}

# ISO 8601（Z 结尾，可带小数秒）/ YYYY-MM-DD / @epoch / 纯数字 → epoch 秒。
fake_parse_epoch() {
  local s="$1"
  case "$s" in
    @*) s="${s#@}"; case "$s" in ''|*[!0-9]*) return 1 ;; esac; echo "$s"; return ;;
  esac
  if printf '%s' "$s" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    s="${s}T00:00:00Z"
  fi
  printf '%s' "$s" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' || return 1
  s="$(printf '%s' "$s" | sed -E 's/\.[0-9]+Z$/Z/')"
  jq -rn --arg s "$s" '$s | fromdateiso8601'
}
