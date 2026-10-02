#!/usr/bin/env bash
# Build, sign, notarize and package a Sidecar Auto release.
# Credentials are read from the user's keychain profile only.
set -euo pipefail
umask 022

PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$PACKAGING_ROOT/.." && pwd)"
OUT_DIR="$ROOT/dist/release"
VERSION=""
IDENTITY="${SIDECAR_AUTO_SIGNING_IDENTITY:-}"
KEYCHAIN_PROFILE="${SIDECAR_AUTO_NOTARY_PROFILE:-}"
ARCHES="arm64,x86_64"

fail() { printf '发布失败：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
用法：release-sidecar-auto.sh --version VERSION --identity IDENTITY --keychain-profile PROFILE [选项]

选项：
  --version VERSION          发布版本，例如 1.0.1
  --identity IDENTITY        Developer ID Application 签名身份
  --keychain-profile NAME    notarytool 已保存的钥匙串 profile
  --arch LIST                架构列表，默认 arm64,x86_64
  --output DIR               输出目录，默认 dist/release
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || fail "--version 缺少参数"; VERSION="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || fail "--identity 缺少参数"; IDENTITY="$2"; shift 2 ;;
        --keychain-profile) [ "$#" -ge 2 ] || fail "--keychain-profile 缺少参数"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --arch) [ "$#" -ge 2 ] || fail "--arch 缺少参数"; ARCHES="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || fail "--output 缺少参数"; OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done

[ -n "$VERSION" ] || fail "必须指定 --version"
[ -n "$IDENTITY" ] || fail "必须指定 Developer ID Application 身份"
[ -n "$KEYCHAIN_PROFILE" ] || fail "必须指定 notarytool 钥匙串 profile"
case "$VERSION" in ''|*[!A-Za-z0-9._-]*) fail "版本号格式无效" ;; esac
[ "$(uname -s)" = "Darwin" ] || fail "发布脚本只能在 macOS 运行"
command -v xcrun >/dev/null 2>&1 || fail "找不到 xcrun"
command -v codesign >/dev/null 2>&1 || fail "找不到 codesign"
command -v ditto >/dev/null 2>&1 || fail "找不到 ditto"

mkdir -p "$OUT_DIR"
APP_OUT="$OUT_DIR/Sidecar Auto Setup.app"
ZIP_OUT="$OUT_DIR/Sidecar-Auto-Setup.zip"
DMG_OUT="$OUT_DIR/Sidecar-Auto-Setup.dmg"

"$PACKAGING_ROOT/build-sidecar-auto-app.sh" \
    --arch "$ARCHES" --version "$VERSION" --sign "$IDENTITY" --output "$OUT_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_OUT"
ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"
xcrun notarytool submit "$ZIP_OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_OUT"
spctl --assess --type execute --verbose=4 "$APP_OUT"
"$PACKAGING_ROOT/make-dmg.sh" --app "$APP_OUT" --output "$OUT_DIR" --version "$VERSION"
shasum -a 256 "$OUT_DIR/Sidecar-Auto-Setup.dmg" > "$OUT_DIR/SHA256SUMS"
printf '发布完成：%s\n校验和：%s\n' "$OUT_DIR/Sidecar-Auto-Setup.dmg" "$OUT_DIR/SHA256SUMS"
