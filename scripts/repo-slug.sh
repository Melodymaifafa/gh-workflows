#!/usr/bin/env bash
#
# 从一个 git remote 的 URL 里取出 owner/repo。
#
#   repo-slug.sh <remote-url>
#
# 巡检的日志要按 owner/repo 归类，而调用方仓库的 remote 既有 https 写法
# 也有 ssh 写法，两种都要认。
set -euo pipefail

url="${1-}"

if [ -z $url ]; then
  echo "::error::repo-slug.sh needs a remote URL"
  exit 1
fi

slug="${url#*github.com}"
slug="${slug#[:/]}"
slug="${slug%.git}"

printf '%s\n' $slug
