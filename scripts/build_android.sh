#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BMRAY_KEYSTORE_FILE:?Укажите путь к своему keystore в BMRAY_KEYSTORE_FILE}"
: "${BMRAY_KEY_ALIAS:?Укажите BMRAY_KEY_ALIAS}"
: "${BMRAY_KEYSTORE_PASSWORD:?Укажите BMRAY_KEYSTORE_PASSWORD}"
: "${BMRAY_KEY_PASSWORD:?Укажите BMRAY_KEY_PASSWORD}"
test -f "$BMRAY_KEYSTORE_FILE" || { echo "Keystore не найден: $BMRAY_KEYSTORE_FILE" >&2; exit 1; }
if [[ ! -f packages/vpn_plugin/android/libs/libbox.aar ]]; then
  bash scripts/build_libbox_android.sh
fi
flutter pub get
flutter build apk --release --no-pub
flutter build appbundle --release --no-pub
echo "Готово: build/app/outputs/flutter-apk/app-release.apk и build/app/outputs/bundle/release/app-release.aab"
