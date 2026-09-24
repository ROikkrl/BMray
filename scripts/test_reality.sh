#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
core_dir="${BMRAY_CORE_DIR:-$repo_dir/build/sing-box}"
bash "$repo_dir/scripts/prepare_core.sh"
test_dir="$repo_dir/build/reality-test"
mkdir -p "$test_dir"
if [[ ! -f "$test_dir/xray.zip" ]]; then
  curl -fsSL --retry 3 https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip -o "$test_dir/xray.zip"
fi
(cd "$test_dir" && echo '1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df  xray.zip' | sha256sum -c -)
unzip -oq "$test_dir/xray.zip" xray -d "$test_dir"
chmod +x "$test_dir/xray"
cd "$core_dir"
BMRAY_TEST_XRAY="$test_dir/xray" go test -tags with_utls -count=1 -timeout 2m -run TestBMrayRealityXray -v ./common/tls
