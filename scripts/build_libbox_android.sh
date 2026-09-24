#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
core_dir="${BMRAY_CORE_DIR:-$repo_dir/build/sing-box}"
bash "$repo_dir/scripts/prepare_core.sh"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.0.13004108"
test -f "$ANDROID_NDK_HOME/source.properties" || { echo 'Install Android NDK 28.0.13004108' >&2; exit 1; }
cd "$core_dir"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
export PATH="$(go env GOPATH)/bin:$PATH"
lib_dir="$repo_dir/packages/vpn_plugin/android/libs"
mkdir -p "$lib_dir"
gomobile bind -target=android/arm64,android/arm,android/amd64 -androidapi 24 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0 \
  -ldflags='-X github.com/sagernet/sing-box/constant.Version=1.13.13-bmray.1 -s -w -buildid= -checklinkname=0' \
  -o "$lib_dir/libbox.aar" ./experimental/libbox
sha256sum "$lib_dir/libbox.aar" | cut -d ' ' -f 1 > "$lib_dir/libbox.aar.sha256"
