#!/bin/bash
# 이 Mac에서만 쓰는 자체 서명서(DesktopNamer Local)를 한 번 만들어 둔다.
# 이후 build-app.sh가 이 서명서로 서명하므로, 다시 빌드해도 손쉬운 사용 권한이 유지된다.
# 사용: ./scripts/setup-signing.sh   (암호 입력 창이 한두 번 뜰 수 있다)
set -euo pipefail

NAME="DesktopNamer Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "이미 서명서가 있습니다: $NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

echo "서명서 생성 중..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:desktopnamer >/dev/null 2>&1

echo "키체인에 추가 중..."
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P desktopnamer \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "서명서를 신뢰하도록 설정 중... (암호 창이 뜨면 Mac 로그인 암호를 입력하세요)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "완료. 이제 ./scripts/build-app.sh 를 실행하면 이 서명서로 서명합니다."
  echo "처음 한 번은 'codesign이 키에 접근하려고 합니다' 창이 뜰 수 있습니다. '항상 허용'을 누르세요."
else
  echo "서명서를 찾지 못했습니다. 키체인 접근 앱에서 '$NAME' 인증서를 확인해 주세요." >&2
  exit 1
fi
