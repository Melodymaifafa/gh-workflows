#!/usr/bin/env bash
#
# 从一个 git remote 的 URL 里取出 owner/repo。
#
#   repo-slug.sh <remote-url>
#
# 巡检的日志要按 owner/repo 归类，而调用方仓库的 remote 既有 https 写法
# 也有 ssh 写法，两种都要认。
#
# 只认 github.com 本身：别的主机（含 notgithub.com 这种仿冒名）一律报错，
# 不能把原样的 URL 或别家主机上的路径当成 owner/repo 交给调用方。
set -euo pipefail

url="${1-}"

if [ -z "$url" ]; then
  echo "::error::repo-slug.sh needs a remote URL"
  exit 1
fi

case "$url" in
  https://github.com/*)   slug="${url#https://github.com/}" ;;
  ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
  git@github.com:*)       slug="${url#git@github.com:}" ;;
  *)
    echo "::error::not a github.com remote: '$url'"
    exit 1
    ;;
esac

slug="${slug%.git}"

# 剩下的必须正好是 owner/repo 两段，多一段少一段都不是仓库地址。
if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::cannot read owner/repo from '$url'"
  exit 1
fi

printf '%s\n' "$slug"
