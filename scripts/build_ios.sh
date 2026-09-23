#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'IPA собирается только на macOS с Xcode.' >&2
  exit 1
fi
flutter pub get
(cd ios && pod install && ruby .symlinks/plugins/vpn_plugin/tool/add_extension_target.rb)
flutter build ipa --release
echo 'Готово: build/ios/ipa/*.ipa'
