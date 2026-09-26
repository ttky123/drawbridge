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
echo "Drawbridge의 '연결 설정'에서 외부 세션 또는 같은 Wi-Fi 세션을 시작할 수 있습니다."
open "$DEST"
