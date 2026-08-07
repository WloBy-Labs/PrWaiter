#!/bin/bash
# 发布一个版本：校验齐活之后打 tag 并推上去，剩下的交给 GitHub Actions ——
# 它会构建、签名、打 DMG 并创建 Release。
#
# 发布前要准备好：
#   1. VERSION 写上新版本号
#   2. CHANGELOG.md 加上对应小节
#   3. release_notes/v<版本>.md 写好发布说明（没有的话 CI 会自动生成，但不如手写）
#   4. 全部提交并推送
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "工作区不干净，请先提交改动"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG 已存在"; exit 1; }

grep -q "^## \[$VERSION\]" CHANGELOG.md || {
    echo "CHANGELOG.md 里没有 [$VERSION] 小节"; exit 1
}

NOTES="release_notes/$TAG.md"
[ -f "$NOTES" ] || echo "提醒：$NOTES 不存在，CI 会用自动生成的说明"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || { echo "当前在 $BRANCH 分支，发版请在 main 上进行"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || {
    echo "本地 main 与 origin/main 不一致，请先推送"; exit 1
}

./test.sh >/dev/null || { echo "测试没过"; exit 1; }

git tag -a "$TAG" -m "PrWaiter $TAG"
git push origin "$TAG"

# 变量后面紧跟中文逗号时必须加花括号，否则 bash 会把逗号算进变量名
echo "已推送 ${TAG}，GitHub Actions 正在构建并发布："
echo "  https://github.com/WloBy-Labs/PrWaiter/actions"
