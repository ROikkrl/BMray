# BMray REALITY compatibility patch

Base: sing-box v1.13.13, commit `78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba`.
Android core version: `1.13.13-bmray.1`. Upstream GPL-3.0 licensing applies.

The patch preserves hybrid X25519MLKEM768 key shares instead of removing them,
adds hybrid key exchange to the pinned Firefox preset, uses the ECDHE key
corresponding to the offered key share, and announces REALITY protocol
compatibility version 26.3.27. It also uses the configured clock consistently.
The HMAC certificate authentication check remains unchanged; no permissive
certificate fallback or automatic disabling of verification is added.

Primary implementation references:
- https://github.com/SagerNet/sing-box/issues/4520
- https://github.com/XTLS/REALITY/commit/8cdf7bf9c7f09cb9814bf08c3eb877f68b85fba8
- https://github.com/XTLS/Xray-core/commit/af7eb68
- https://github.com/MetaCubeX/mihomo/pull/2983

`bash scripts/test_reality.sh` runs a pinned Xray 26.9.9 server on loopback.
It generates ephemeral keys and transfers a 136 KiB HTTPS response over
VLESS Vision using Firefox and Chrome, then checks rejection of incorrect
public keys and short IDs. No real subscription data is used in CI.

`bash scripts/build_libbox_android.sh` builds the exact source and patch for
Android arm64, armv7 and x86_64 using Go 1.25.10 and NDK 28.0.13004108.
The resulting AAR and SHA-256 sidecar are generated files. Their checksum
prevents stale or truncated local binaries from being packaged; source
provenance is pinned by the Git commit and Go module checksums.

This Android patch is not applied to the separately downloaded iOS core.
