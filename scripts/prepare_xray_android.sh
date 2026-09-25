#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="packages/vpn_plugin/android/src/main/jniLibs"
mkdir -p "$output"
for spec in \
  'arm64-v8a f18625edf2360df8f857d8a2d947f69dd137b31849e7b9b530200d7e5f482766' \
  'amd64 7317be77220ae9fba70692bccb079dc91e405a42b77d904c324d54820d815532'; do
  read -r archive_abi checksum <<< "$spec"
  if [[ "$archive_abi" == amd64 ]]; then
    android_abi=x86_64
  else
    android_abi="$archive_abi"
  fi
  target="$output/$android_abi/libxraycli.so"
  if [[ -s "$target" ]]; then continue; fi
  archive="build/xray/Xray-android-$archive_abi.zip"
  mkdir -p "$(dirname "$archive")" "$(dirname "$target")"
  curl -fsSL --retry 3 \
    "https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-android-$archive_abi.zip" \
    -o "$archive"
  echo "$checksum  $archive" | sha256sum -c -
  entry="$(unzip -Z1 "$archive" | awk '$0 == "xray" || $0 ~ /\/xray$/ {print; exit}')"
  test -n "$entry"
  unzip -p "$archive" "$entry" > "$target"
  chmod 755 "$target"
  file "$target"
done
