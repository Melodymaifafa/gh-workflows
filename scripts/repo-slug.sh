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

# 主机名不分大小写（GitHub.com 也是 github.com），所以拿小写版认前缀；
# 切的还是原 URL，owner/repo 的大小写原样保留。
lower="$(tr '[:upper:]' '[:lower:]' <<<"$url")"
case "$lower" in
  https://github.com/*)   prefix="https://github.com/" ;;
  ssh://git@github.com/*) prefix="ssh://git@github.com/" ;;
  git@github.com:*)       prefix="git@github.com:" ;;
  *)
    echo "::error::not a github.com remote: '$url'"
    exit 1
    ;;
esac

slug="${url:${#prefix}}"
slug="${slug%.git}"

# 剩下的必须正好是 owner/repo 两段，多一段少一段都不是仓库地址；
# 「.」「..」也不是名字，放过去调用方拿它拼路径就跳出了日志目录。
if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::cannot read owner/repo from '$url'"
  exit 1
fi
case "/$slug/" in
  */./* | */../*)
    echo "::error::cannot read owner/repo from '$url'"
    exit 1
    ;;
esac

printf '%s\n' "$slug"
