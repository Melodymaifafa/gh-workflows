#!/usr/bin/env bash
#
# 从一个 git remote 的 URL 里取出主机名。
#
#   remote-host.sh <remote-url>
#
# 巡检要分清「GitHub 上的仓库」和别处的镜像，而调用方仓库的 remote
# 既有 https 写法也有 ssh 写法，两种都要认。
set -euo pipefail

url="${1-}"

if [ -z "$url" ]; then
  echo "::error::remote-host.sh needs a remote URL"
  exit 1
fi

authority="${url#*://}"
authority="${authority%%/*}"
authority="${authority##*@}"

case "$authority" in
  \[*\]*) host="${authority%%]*}]" ;;
  *) host="${authority%%:*}" ;;
esac

printf '%s\n' "$host"
