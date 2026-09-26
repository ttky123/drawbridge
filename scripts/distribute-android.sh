#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo "사용법: $0 <Firebase 테스터 이메일>" >&2
  exit 1
fi
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
firebase appdistribution:distribute "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
  --app "1:1013027211868:android:5244aa069cb42f4763f499" \
  --testers "$1" \
  --release-notes "Drawbridge 0.6.0 - 보드 필기와 화면 주석을 별도 레이어로 분리"
