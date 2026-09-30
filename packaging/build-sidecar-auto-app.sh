#!/usr/bin/env bash
# Build a distributable Sidecar Auto Setup.app with prebuilt helpers.
#
# Release users receive a self-contained app and do not need Swift, clang, or
# Xcode Command Line Tools. The source installer remains available for
# developers in installer/install-sidecar-auto.sh.
#
# Default output is a universal arm64 + x86_64 app. Use --host-only for a
# local build when cross-compiling the other architecture is unavailable.

set -euo pipefail
umask 022

PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$PACKAGING_ROOT/.." && pwd)"
APP_NAME="Sidecar Auto Setup"
OUT_DIR="${SIDECAR_AUTO_APP_OUT_DIR:-$ROOT/dist}"
APP_DIR="$OUT_DIR/$APP_NAME.app"
STAGE=""
VERSION="${SIDECAR_AUTO_VERSION:-0.2.0}"
BUILD_VERSION="${SIDECAR_AUTO_BUILD_VERSION:-}"
SIGNING_IDENTITY="${SIDECAR_AUTO_SIGNING_IDENTITY:-}"
ARCH_SPEC="${SIDECAR_AUTO_ARCHS:-arm64 x86_64}"
MIN_MACOS="${SIDECAR_AUTO_MIN_MACOS:-13.0}"

fail() { printf 'App 构建失败：%s\n' "$*" >&2; exit 1; }
info() { printf '[app] %s\n' "$*"; }

usage() {
    cat <<'USAGE'
用法：build-sidecar-auto-app.sh [选项]

选项：
  --host-only             只构建当前 Mac 架构
  --arch LIST             架构列表，例如 arm64,x86_64
  --output DIR            输出目录（默认：./dist）
  --version VERSION       CFBundleShortVersionString（默认：0.2.0）
  --sign IDENTITY         用 codesign 身份签名；不指定则输出未签名 App
  -h, --help              显示帮助

环境变量：
  SIDECAR_AUTO_ARCHS、SIDECAR_AUTO_APP_OUT_DIR、SIDECAR_AUTO_SIGNING_IDENTITY
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host-only)
            ARCH_SPEC="$(uname -m)"
            shift
            ;;
        --arch)
            [ "$#" -ge 2 ] || fail "--arch 缺少参数"
            ARCH_SPEC="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || fail "--output 缺少参数"
            OUT_DIR="$2"
            APP_DIR="$OUT_DIR/$APP_NAME.app"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || fail "--version 缺少参数"
            VERSION="$2"
            shift 2
            ;;
        --sign)
            [ "$#" -ge 2 ] || fail "--sign 缺少参数"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1"
            ;;
    esac
done

case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*) fail "版本号只能包含字母、数字、点、下划线和连字符" ;;
esac
case "$MIN_MACOS" in
    ''|*[!0-9.]*) fail "最低 macOS 版本格式无效：$MIN_MACOS" ;;
esac

# Accept both "arm64 x86_64" and "arm64,x86_64".
ARCH_SPEC="${ARCH_SPEC//,/ }"
read -r -a ARCHES <<< "$ARCH_SPEC"
[ "${#ARCHES[@]}" -gt 0 ] || fail "没有指定构建架构"
for arch in "${ARCHES[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *) fail "不支持的架构：${arch}（只能使用 arm64 或 x86_64）" ;;
    esac
done

if [ -z "$BUILD_VERSION" ]; then
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
        BUILD_VERSION="$(git -C "$ROOT" rev-list --count HEAD)"
    else
        BUILD_VERSION="0"
    fi
fi
case "$BUILD_VERSION" in
    ''|*[!0-9]*) fail "构建版本必须是非负整数：$BUILD_VERSION" ;;
esac

[ "$(uname -s)" = "Darwin" ] || fail "此脚本只能在 macOS 上运行"
SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
CLANG="$(xcrun --find clang 2>/dev/null || true)"
LIPO="$(xcrun --find lipo 2>/dev/null || true)"
[ -x "$SWIFTC" ] || fail "找不到 swiftc；请安装 Xcode Command Line Tools"
[ -x "$CLANG" ] || fail "找不到 clang；请安装 Xcode Command Line Tools"
[ -x "$LIPO" ] || fail "找不到 lipo；请安装 Xcode Command Line Tools"
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -d "$SDK" ] || fail "无法找到 macOS SDK"

for required in \
    "$ROOT/Sources/SidecarAutoSetup/main.swift" \
    "$ROOT/Sources/DisplayState/DisplayState.swift" \
    "$ROOT/Sources/BluetoothRadio/sidecar-bluetooth-radio.c" \
    "$ROOT/Sources/VirtualDisplay/sidecar-virtual-display.m" \
    "$ROOT/vendor/sidecarctl/Sources/CLI/main.swift" \
    "$ROOT/vendor/sidecarctl/Sources/Shared" \
    "$ROOT/scripts/sidecar-connect-once.sh" \
    "$ROOT/scripts/sidecar-connect-wireless-once.sh" \
    "$ROOT/scripts/sidecar-disconnect-once.sh" \
    "$ROOT/scripts/sidecar-doctor.sh" \
    "$ROOT/scripts/sidecar-hotkey.sh" \
    "$ROOT/scripts/sidecar-ipad-usb-detect.sh" \
    "$ROOT/scripts/sidecar-login-ready.sh" \
    "$ROOT/config/config.example" \
    "$ROOT/launchd/com.sidecarauto.login-ready.plist.template" \
    "$PACKAGING_ROOT/AppIcon.icns" \
    "$PACKAGING_ROOT/SidecarAutoSetup-Info.plist"; do
    [ -e "$required" ] || fail "缺少打包输入：$required"
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-app.XXXXXX")"
trap 'if [ -n "${STAGE:-}" ]; then rm -rf "$STAGE"; fi' EXIT
mkdir -p "$STAGE/arch" "$STAGE/app/Contents/MacOS" \
    "$STAGE/app/Contents/Resources/bin" \
    "$STAGE/app/Contents/Resources/scripts" \
    "$STAGE/app/Contents/Resources/config" \
    "$STAGE/app/Contents/Resources/launchd" \
    "$STAGE/app/Contents/Resources/ThirdParty"

compile_arch() {
    local arch="$1"
    local target="${arch}-apple-macosx${MIN_MACOS}"
    local dir="$STAGE/arch/$arch"
    mkdir -p "$dir"
    info "编译 ${arch}：Sidecar Auto 设置助手"
    "$SWIFTC" -O -parse-as-library -target "$target" -sdk "$SDK" \
        -framework SwiftUI -framework AppKit -framework ApplicationServices \
        -framework CoreBluetooth -framework CoreGraphics \
        "$ROOT/Sources/SidecarAutoSetup/main.swift" -o "$dir/SidecarAutoSetup"
    info "编译 ${arch}：sidecarctl"
    (
        cd "$ROOT/vendor/sidecarctl"
        TARGET_ARCH="$arch" TARGET_OS_VERSION="$MIN_MACOS" SDKROOT="$SDK" \
            BUILD_DIR="$dir/sidecarctl-build" ./build.sh --cli-only --build-only
    )
    cp "$dir/sidecarctl-build/sidecarctl" "$dir/sidecarctl"
    chmod 0755 "$dir/sidecarctl"
    info "编译 ${arch}：display-state"
    "$SWIFTC" -O -target "$target" -sdk "$SDK" \
        "$ROOT/Sources/DisplayState/DisplayState.swift" -o "$dir/display-state" \
        -framework AppKit -framework CoreGraphics
    info "编译 ${arch}：sidecar-bluetooth-radio"
    "$CLANG" -O2 -arch "$arch" -mmacosx-version-min="$MIN_MACOS" \
        -isysroot "$SDK" -framework IOBluetooth \
        "$ROOT/Sources/BluetoothRadio/sidecar-bluetooth-radio.c" \
        -o "$dir/sidecar-bluetooth-radio"
    info "编译 ${arch}：sidecar-virtual-display"
    "$CLANG" -O2 -fobjc-arc -arch "$arch" -mmacosx-version-min="$MIN_MACOS" \
        -isysroot "$SDK" -framework AppKit -framework CoreGraphics -framework Foundation \
        "$ROOT/Sources/VirtualDisplay/sidecar-virtual-display.m" \
        -o "$dir/sidecar-virtual-display"
}

for arch in "${ARCHES[@]}"; do
    compile_arch "$arch"
done

make_universal() {
    local name="$1"
    local destination="$STAGE/app/Contents/Resources/bin/$name"
    local inputs=()
    local arch
    for arch in "${ARCHES[@]}"; do
        inputs+=("$STAGE/arch/$arch/$name")
    done
    if [ "${#inputs[@]}" -eq 1 ]; then
        cp "${inputs[0]}" "$destination"
    else
        "$LIPO" -create "${inputs[@]}" -output "$destination"
    fi
    chmod 0755 "$destination"
}

make_universal sidecarctl
make_universal display-state
make_universal sidecar-bluetooth-radio
make_universal sidecar-virtual-display
# The GUI executable belongs in Contents/MacOS, rather than Resources/bin.
# Reuse the same universal assembly helper and then remove the staging copy
# so code signing cannot mistake it for a second nested executable.
make_universal SidecarAutoSetup
cp "$STAGE/app/Contents/Resources/bin/SidecarAutoSetup" \
   "$STAGE/app/Contents/MacOS/SidecarAutoSetup"
rm -f "$STAGE/app/Contents/Resources/bin/SidecarAutoSetup"
chmod 0755 "$STAGE/app/Contents/MacOS/SidecarAutoSetup"

for script in \
    sidecar-connect-once.sh \
    sidecar-connect-wireless-once.sh \
    sidecar-disconnect-once.sh \
    sidecar-doctor.sh \
    sidecar-hotkey.sh \
    sidecar-ipad-usb-detect.sh \
    sidecar-login-ready.sh; do
    bash -n "$ROOT/scripts/$script" || fail "Shell 语法检查失败：$script"
    cp "$ROOT/scripts/$script" "$STAGE/app/Contents/Resources/scripts/$script"
    chmod 0755 "$STAGE/app/Contents/Resources/scripts/$script"
done
cp "$ROOT/config/config.example" "$STAGE/app/Contents/Resources/config/config.example"
cp "$ROOT/launchd/com.sidecarauto.login-ready.plist.template" \
   "$STAGE/app/Contents/Resources/launchd/com.sidecarauto.login-ready.plist.template"
cp "$ROOT/vendor/sidecarctl/LICENSE" \
   "$STAGE/app/Contents/Resources/ThirdParty/sidecarctl-LICENSE"
cp "$ROOT/docs/NOTICE.md" "$STAGE/app/Contents/Resources/ThirdParty/NOTICE.md"
cp "$PACKAGING_ROOT/AppIcon.icns" "$STAGE/app/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/VirtualDisplay/sidecar-virtual-display.m" \
   "$STAGE/app/Contents/Resources/ThirdParty/sidecar-virtual-display-source.m"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD_VERSION__/$BUILD_VERSION/g" \
    "$PACKAGING_ROOT/SidecarAutoSetup-Info.plist" \
    > "$STAGE/app/Contents/Info.plist"
plutil -lint "$STAGE/app/Contents/Info.plist" >/dev/null

sign_nested() {
    [ -n "$SIGNING_IDENTITY" ] || return 0
    local options=(--force --options runtime --sign "$SIGNING_IDENTITY")
    if [ "$SIGNING_IDENTITY" != "-" ]; then
        options+=(--timestamp)
    fi
    local executable
    for executable in \
        "$STAGE/app/Contents/MacOS/SidecarAutoSetup" \
        "$STAGE/app/Contents/Resources/bin/sidecarctl" \
        "$STAGE/app/Contents/Resources/bin/display-state" \
        "$STAGE/app/Contents/Resources/bin/sidecar-bluetooth-radio" \
        "$STAGE/app/Contents/Resources/bin/sidecar-virtual-display"; do
        codesign "${options[@]}" "$executable"
    done
    codesign "${options[@]}" --entitlements "$PACKAGING_ROOT/SidecarAutoSetup.entitlements" \
        "$STAGE/app/Contents/MacOS/SidecarAutoSetup"
    codesign "${options[@]}" "$STAGE/app"
}

if [ -n "$SIGNING_IDENTITY" ]; then
    command -v codesign >/dev/null 2>&1 || fail "指定了签名身份，但找不到 codesign"
    sign_nested
fi

mkdir -p "$OUT_DIR"
rm -rf "$APP_DIR"
mv "$STAGE/app" "$APP_DIR"
STAGE=""

for executable in \
    "$APP_DIR/Contents/MacOS/SidecarAutoSetup" \
    "$APP_DIR/Contents/Resources/bin/sidecarctl" \
    "$APP_DIR/Contents/Resources/bin/display-state" \
    "$APP_DIR/Contents/Resources/bin/sidecar-bluetooth-radio" \
    "$APP_DIR/Contents/Resources/bin/sidecar-virtual-display"; do
    /usr/bin/file "$executable" | grep -q 'Mach-O' || fail "不是 Mach-O 产物：$executable"
done

if [ "${#ARCHES[@]}" -gt 1 ]; then
    for executable in \
        "$APP_DIR/Contents/MacOS/SidecarAutoSetup" \
        "$APP_DIR/Contents/Resources/bin/sidecarctl" \
        "$APP_DIR/Contents/Resources/bin/display-state" \
        "$APP_DIR/Contents/Resources/bin/sidecar-bluetooth-radio" \
        "$APP_DIR/Contents/Resources/bin/sidecar-virtual-display"; do
        arch_info="$(lipo -info "$executable")"
        for arch in "${ARCHES[@]}"; do
            printf '%s\n' "$arch_info" | grep -qw "$arch" || \
                fail "产物缺少架构 ${arch}：$executable"
        done
    done
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

info "完成：$APP_DIR"
if [ -z "$SIGNING_IDENTITY" ]; then
    info "这是未签名构建；发布给普通用户前请使用 Developer ID 签名并提交 Apple 公证。"
fi
