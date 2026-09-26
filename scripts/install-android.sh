#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "Android 태블릿을 USB로 연결하고 개발자 옵션의 USB 디버깅을 허용하세요." >&2
  exit 1
fi
"$ADB" reverse tcp:3000 tcp:3000
"$ADB" install -r "$APK"
echo "Drawbridge가 설치되었습니다. 서버 주소는 http://127.0.0.1:3000 을 사용하세요."
