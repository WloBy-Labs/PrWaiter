#!/bin/bash
# 发布一个版本：打 tag、构建 .app、上传到 GitHub Release。
# 发布前请先更新 VERSION 和 CHANGELOG.md（新增对应版本小节），并提交。
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
TAG="v$VERSION"

# 0.x 是设计调试阶段，只维护 CHANGELOG，不出包
case "$VERSION" in
    0.*) echo "当前 $VERSION 处于 0.x 设计调试阶段，不发布。等升到 1.0.0 再执行本脚本。"; exit 1;;
esac

[ -z "$(git status --porcelain)" ] || { echo "工作区不干净，请先提交改动"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG 已存在"; exit 1; }

# 从 CHANGELOG 里抽出本版本小节作为 release notes
NOTES=$(awk -v v="## [$VERSION]" '
    index($0, v) == 1              { on = 1; next }
    on && /^(## \[|\[[^]]+\]:)/    { exit }
    on                             { print }
' CHANGELOG.md)
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || { echo "CHANGELOG.md 里没有 [$VERSION] 小节"; exit 1; }

./build.sh
rm -f "PrWaiter-$TAG.zip"
ditto -c -k --keepParent PrWaiter.app "PrWaiter-$TAG.zip"

git tag -a "$TAG" -m "PrWaiter $TAG"
git push origin "$TAG"
gh release create "$TAG" "PrWaiter-$TAG.zip" --title "PrWaiter $TAG" --notes "$NOTES"

echo "已发布 $TAG"
