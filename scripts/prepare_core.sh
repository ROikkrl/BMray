#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
core_dir="${BMRAY_CORE_DIR:-$repo_dir/build/sing-box}"
core_commit=78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba
if [[ ! -d "$core_dir/.git" ]]; then
  git clone --depth 1 --branch v1.13.13 https://github.com/SagerNet/sing-box.git "$core_dir"
fi
[[ "$(git -C "$core_dir" rev-parse HEAD)" == "$core_commit" ]] || { echo 'Unexpected sing-box source revision' >&2; exit 1; }
patch_file="$repo_dir/patches/sing-box/reality-compat.patch"
if ! git -C "$core_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
  git -C "$core_dir" apply --check "$patch_file"
  git -C "$core_dir" apply "$patch_file"
fi
cp "$repo_dir"/patches/sing-box/bmray_reality_*.go "$core_dir/common/tls/"
cp "$repo_dir"/patches/sing-box/bmray_probe.go "$core_dir/experimental/libbox/"
cp "$repo_dir"/patches/sing-box/bmray_probe_test.go "$core_dir/experimental/libbox/"
