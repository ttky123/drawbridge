#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "이 업데이트 스크립트는 macOS 전용입니다."
  exit 1
fi

if [ ! -d .git ]; then
  echo "Git으로 설치한 Drawbridge 폴더에서 실행해야 합니다."
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "로컬 변경 사항이 있어 업데이트를 중단합니다. 먼저 변경을 커밋하거나 임시 보관하세요."
  git status --short
  exit 1
fi

BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
  echo "현재 브랜치가 main이 아닙니다: $BRANCH"
  echo "main 브랜치로 전환한 뒤 다시 실행하세요."
  exit 1
fi

echo "Drawbridge 업데이트를 확인합니다..."
git fetch origin main

LOCAL_REV=$(git rev-parse HEAD)
REMOTE_REV=$(git rev-parse origin/main)
if [ "$LOCAL_REV" = "$REMOTE_REV" ]; then
  echo "소스가 이미 최신입니다. 앱을 다시 빌드하고 설치합니다."
else
  git merge --ff-only origin/main
fi

exec "$ROOT/scripts/install-macos.sh"
