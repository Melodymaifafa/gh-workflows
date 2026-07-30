#!/usr/bin/env bash
#
# 建一个新仓库并装好整套自动化，一条命令。
#
#   ./newrepo.sh <name> <python|node> [--public]
#
# 做 onboard.sh 之外还差的三件事：建远端仓库（默认 private）、
# 克隆到 ~/projects/<name>、装完把默认分支改成 develop。
#
# 新仓库还没有依赖清单 / lint / 测试，所以 CI 三步默认 skip，
# 免得第一次 push 就满屏红叉。写好代码后删掉 ci.yml 里的
# install_cmd / lint_cmd / test_cmd 三行即可开启。
#
# 没有需要手动补的步骤：Codex connector 是账号级授权，新仓库自动覆盖。
set -euo pipefail

OWNER=Melodymaifafa
PROJECTS="${PROJECTS_DIR:-$HOME/projects}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

name="${1:?usage: newrepo.sh <name> <python|node> [--public]}"
runtime="${2:?usage: newrepo.sh <name> <python|node> [--public]}"
visibility=--private
[ "${3:-}" = --public ] && visibility=--public

slug="$OWNER/$name"
dest="$PROJECTS/$name"

case "$runtime" in
  python | node) ;;
  *)
    echo "runtime must be python or node" >&2
    exit 1
    ;;
esac

if [ -e "$dest" ]; then
  echo "$dest 已存在，先挪走或换个名字" >&2
  exit 1
fi

echo "==> 建仓库 $slug ($visibility)"
# --add-readme 是为了立刻有一笔 commit 和一个 main 分支：onboard.sh 要克隆它。
gh repo create "$slug" "$visibility" --add-readme >/dev/null
echo "    远端已建好"

echo "==> 装自动化"
INSTALL_CMD="${INSTALL_CMD:-skip}" \
  LINT_CMD="${LINT_CMD:-skip}" \
  TEST_CMD="${TEST_CMD:-skip}" \
  "$HERE/onboard.sh" "$name" "$runtime"

# onboard.sh 要求默认分支是 main（它把 main fast-forward 到 develop）。
# 装完必须翻过来：否则 `gh pr create` 不带 --base 会开到 main，
# agent 的 PR 全合错分支（2026-07-30 linear-agent-team 踩过）。
echo "==> 默认分支改成 develop"
gh repo edit "$slug" --default-branch develop >/dev/null
echo "    已切换"

echo "==> 克隆到 $dest"
git clone --quiet "https://github.com/$slug.git" "$dest"
echo "    完成"

cat <<EOF

$dest 已就绪，默认分支 develop，无需人工补步骤。
开工：cd $dest && git checkout -b users/melody/<slug>
EOF
