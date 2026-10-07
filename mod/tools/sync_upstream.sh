#!/usr/bin/env bash
# 把 mod 同步到官方最新版本，并把冲突文件 / hook 清单直接打出来。
#
#   bash mod/tools/sync_upstream.sh            # 只检查，不动工作区
#   bash mod/tools/sync_upstream.sh --apply    # 真的执行 rebase
#
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # 仓库根目录

REPO="$PWD"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "############ 1) 拉官方最新"
git fetch upstream main || { echo "fetch 失败"; exit 1; }
echo "  官方最新：$(git log --oneline -1 upstream/main)"

CUR=$(git rev-parse --abbrev-ref HEAD)
echo "  当前分支：$CUR"

echo
echo "############ 2) mod 相对官方的提交"
git log --oneline "upstream/main..$CUR" || true

echo
echo "############ 3) 预演（哪些文件会冲突）"
# 用 merge-tree 做无副作用的预演
BASE=$(git merge-base "$CUR" upstream/main)
# merge-tree 的旧式输出里，"changed in both" 后面紧跟 base/our/their 三行，
# 从 base 行取出文件路径即可拿到"双方都改过"的文件清单。
CONFLICTS=$(git merge-tree "$BASE" "$CUR" upstream/main 2>/dev/null \
  | awk '/^changed in both/{f=1;next} f && /^  base/{print $4; f=0}' | sort -u)
if [ -n "$CONFLICTS" ]; then
  echo "$CONFLICTS" | sed 's/^/  ⚠ /'
  echo "  → 共 $(echo "$CONFLICTS" | wc -l | tr -d ' ') 个文件会冲突"
  echo "  → 这些正是 hook 所在文件；对照下面第 4 步的清单按语义重放即可"
  echo "  → lib/mod/ 里的代码不会冲突（官方没有这个目录）"
else
  echo "  （预演没报冲突；实际 rebase 仍可能冲突）"
fi

echo
echo "############ 4) 本次 mod 的全部改动点（按 hook 标记）"
grep -rn "MOD-HOOK" lib/ --include=*.dart | sed "s#$REPO/##" | sort

echo
echo "############ 5) mod 独占的目录（理论上不会和官方冲突）"
echo "  lib/mod/"
git ls-files lib/mod | head -30

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "只做了检查。确认无误后执行："
  echo "  bash mod/tools/sync_upstream.sh --apply"
  exit 0
fi

echo
echo "############ 6) 执行 rebase"
git rebase upstream/main || {
  echo
  echo "!! rebase 停下来了。处理办法："
  echo "   1) git status 看冲突文件；只会在上面第 4 步列出的文件里"
  echo "   2) 按 hook 语义手工重放（lib/mod/ 里的代码一般不需要改）"
  echo "   3) git add <file> && git rebase --continue"
  echo "   4) 完成后跑 flutter analyze，必须 0 error"
  exit 1
}
echo "  完成。别忘了 flutter analyze。"
