#!/usr/bin/env bash
# Disposable signing key: these packages are for device testing, not Google Play.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export BMRAY_KEYSTORE_FILE="$test_dir/bmray-test.jks"
export BMRAY_KEY_ALIAS=bmray-test
export BMRAY_KEYSTORE_PASSWORD=android
export BMRAY_KEY_PASSWORD=android
keytool -genkeypair -noprompt -keystore "$BMRAY_KEYSTORE_FILE" \
  -storepass "$BMRAY_KEYSTORE_PASSWORD" -keypass "$BMRAY_KEY_PASSWORD" \
  -alias "$BMRAY_KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 30 \
  -dname 'CN=BMray Test Build' -storetype JKS
bash scripts/build_android.sh
echo 'Тестовая подпись. Для установки следующей такой сборки может потребоваться удаление приложения.'
