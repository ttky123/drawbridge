#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0

ok() { echo "✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "△ $1"; }

echo "Drawbridge 업무망 연결 진단"
echo

if command -v node >/dev/null 2>&1; then
  ok "Node.js: $(node --version 2>/dev/null)"
else
  bad "Node.js가 설치되지 않았습니다."
fi

if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"
else
  bad "cloudflared가 설치되지 않았습니다."
fi

if command -v node >/dev/null 2>&1 && [ -f "$ROOT/server.js" ]; then
  TEST_PORT=$((41000 + ($$ % 1000)))
  PORT="$TEST_PORT" node "$ROOT/server.js" >"${TMPDIR:-/tmp}/drawbridge-diagnose-server.log" 2>&1 &
  SERVER_PID=$!
  sleep 1
  if curl --connect-timeout 3 --max-time 5 -fsS "http://127.0.0.1:$TEST_PORT/api/network" >/dev/null 2>&1; then
    ok "내장 서버: localhost:$TEST_PORT"
  else
    bad "내장 서버를 localhost에서 실행할 수 없습니다."
  fi
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
fi

for HOST in api.trycloudflare.com region1.v2.argotunnel.com region2.v2.argotunnel.com; do
  if dscacheutil -q host -a name "$HOST" 2>/dev/null | grep -q 'ip_address:'; then
    ok "DNS: $HOST"
  else
    bad "DNS 차단 또는 조회 실패: $HOST"
  fi
done
if dscacheutil -q host -a name h2.cftunnel.com 2>/dev/null | grep -q 'ip_address:'; then
  ok "DNS: h2.cftunnel.com"
else
  warn "선택 주소 조회 실패: h2.cftunnel.com (SNI 검사망에서만 필요)"
fi

HTTP_CODE=$(curl --connect-timeout 6 --max-time 10 -sS -o /dev/null -w '%{http_code}' https://api.trycloudflare.com 2>/dev/null || true)
if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
  ok "HTTPS 443: api.trycloudflare.com 응답 $HTTP_CODE"
else
  bad "HTTPS 443 차단: api.trycloudflare.com"
fi

TCP_OK=0
for HOST in region1.v2.argotunnel.com region2.v2.argotunnel.com; do
  if nc -G 5 -z "$HOST" 7844 >/dev/null 2>&1; then
    ok "TCP 7844: $HOST"
    TCP_OK=1
  else
    bad "TCP 7844 차단 또는 시간 초과: $HOST"
  fi
done

echo
echo "결과: 성공 $PASS / 실패 $FAIL"
if [ "$TCP_OK" -eq 0 ]; then
  echo "판정: 회사망이 Cloudflare Tunnel의 TCP 7844를 차단하고 있습니다."
  echo "대응: 네트워크 허용을 요청하거나 HTTPS 443 공용 중계 서버를 사용해야 합니다."
  exit 2
fi
if [ "$FAIL" -gt 0 ]; then
  echo "판정: 일부 필수 주소가 차단되어 외부 세션이 불안정할 수 있습니다."
  exit 1
fi
echo "판정: Cloudflare 외부 세션에 필요한 네트워크 연결이 허용되어 있습니다."
