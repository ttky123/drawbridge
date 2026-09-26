#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DEST="$HOME/Applications/Drawbridge.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "이 설치 스크립트는 macOS 전용입니다."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew가 필요합니다: https://brew.sh"
  exit 1
fi

brew list node >/dev/null 2>&1 || brew install node
brew list cloudflared >/dev/null 2>&1 || brew install cloudflared

cd "$ROOT"
npm ci
./scripts/build-macos.sh
mkdir -p "$HOME/Applications"
ditto "$ROOT/dist/Drawbridge.app" "$DEST"
codesign --verify --deep --strict "$DEST"

echo "설치 완료: $DEST"
echo "Drawbridge에서 '외부 연결'을 누르면 서버와 임시 HTTPS 터널이 자동으로 시작됩니다."
open "$DEST"
