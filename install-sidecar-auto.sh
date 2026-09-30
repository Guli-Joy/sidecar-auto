#!/bin/bash
# Install the bundled Sidecar CLI, display probe, one-shot controllers, and
# login-ready announcement. This installer builds in a temporary directory,
# validates every output, and only then replaces the installed executables.
#
# It intentionally does not install BetterDisplay, create a virtual screen,
# start Sidecar, grant TCC permissions, or create Shortcuts on the user's
# behalf. Those actions either require a separate license or an interactive
# macOS consent prompt.

set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${SIDECAR_RECONNECT_ROOT:-$ROOT/Sources/sidecarctl}"
BIN_DIR="${SIDECAR_AUTO_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${SIDECAR_AUTO_CONFIG_DIR:-$HOME/.config/sidecar-auto}"
CONFIG_FILE="$CONFIG_DIR/config"
STAGE=""
INSTALL_STAGE=""
CONFIG_STAGE=""
BUILD_ONLY=0

fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
warn() { printf '提示：%s\n' "$*" >&2; }

for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        -h|--help)
            cat <<USAGE
usage: $0 [--build-only]

  --build-only  build and validate all macOS helpers without installing them
USAGE
            exit 0
            ;;
        *) fail "未知参数：$arg" ;;
    esac
done

cleanup() {
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$INSTALL_STAGE" ] || rm -rf "$INSTALL_STAGE"
    [ -z "$CONFIG_STAGE" ] || rm -f "$CONFIG_STAGE"
}
trap cleanup EXIT

check_platform() {
    [ "$(uname -s)" = "Darwin" ] || fail "此安装程序只能在 macOS 上运行"

    local version major arch sdk sdk_version swift_path clang_path
    version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    [ -n "$version" ] || fail "无法读取 macOS 版本"
    major="${version%%.*}"
    case "$major" in
        ''|*[!0-9]*) fail "无法识别 macOS 版本：$version" ;;
    esac
    [ "$major" -ge 13 ] || fail "需要 macOS 13 或更高版本（当前：$version）"

    arch="$(uname -m)"
    case "$arch" in
        arm64|x86_64) ;;
        *) fail "不支持的 Mac 架构：$arch" ;;
    esac

    command -v swiftc >/dev/null 2>&1 || \
        fail "找不到 swiftc。请先运行 xcode-select --install，完成后重新运行本安装器"
    command -v clang >/dev/null 2>&1 || \
        fail "找不到 clang。请先运行 xcode-select --install，完成后重新运行本安装器"
    command -v xcrun >/dev/null 2>&1 || \
        fail "找不到 xcrun。请安装 Xcode Command Line Tools 后重新运行本安装器"

    swift_path="$(xcrun --find swiftc 2>/dev/null || true)"
    clang_path="$(xcrun --find clang 2>/dev/null || true)"
    [ -x "$swift_path" ] || fail "Xcode Command Line Tools 未提供可执行的 swiftc；请运行 xcode-select --install"
    [ -x "$clang_path" ] || fail "Xcode Command Line Tools 未提供可执行的 clang；请运行 xcode-select --install"
    SWIFTC="$swift_path"
    CLANG="$clang_path"
    sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [ -n "$sdk" ] && [ -d "$sdk" ] || \
        fail "找不到 macOS SDK。请完成 Xcode Command Line Tools 安装后重新运行"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
    MACOS_SDK="$sdk"

    printf '预检通过：macOS %s (%s)，macOS SDK %s\n' "$version" "$arch" "${sdk_version:-未知}"
    printf '使用工具：swiftc=%s clang=%s\n' "$swift_path" "$clang_path"
}

check_sources() {
    [ -x "$SOURCE_ROOT/build.sh" ] || \
        fail "找不到随附的 sidecarctl 构建脚本：$SOURCE_ROOT/build.sh"
    local source
    for source in \
        "$ROOT/DisplayState.swift" \
        "$ROOT/sidecar-bluetooth-radio.c" \
        "$ROOT/sidecar-connect-once.sh" \
        "$ROOT/sidecar-connect-wireless-once.sh" \
        "$ROOT/sidecar-ipad-usb-detect.sh" \
        "$ROOT/sidecar-disconnect-once.sh" \
        "$ROOT/sidecar-hotkey.sh" \
        "$ROOT/sidecar-login-ready.sh" \
        "$ROOT/sidecar-doctor.sh"; do
        [ -r "$source" ] || fail "缺少安装源文件：$source"
    done
}

# BetterDisplay is an independent GUI product. Detection here is deliberately
# filesystem-only: invoking its executable can launch the app and cause a
# first-run permission dialog. The connection script will perform its own
# bounded CLI check when the user explicitly requests headless Sidecar.
detect_betterdisplay() {
    local app cli version plist candidate
    BETTERDISPLAY_APP=""
    BETTERDISPLAY_CLI=""
    for candidate in \
        "/Applications/BetterDisplay.app" \
        "$HOME/Applications/BetterDisplay.app"; do
        if [ -d "$candidate" ]; then
            BETTERDISPLAY_APP="$candidate"
            break
        fi
    done
    if command -v betterdisplaycli >/dev/null 2>&1; then
        BETTERDISPLAY_CLI="$(command -v betterdisplaycli)"
    elif [ -n "$BETTERDISPLAY_APP" ] &&
         [ -x "$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay" ]; then
        BETTERDISPLAY_CLI="$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay"
    fi

    if [ -n "$BETTERDISPLAY_APP" ]; then
        plist="$BETTERDISPLAY_APP/Contents/Info.plist"
        version=""
        if [ -x /usr/libexec/PlistBuddy ] && [ -f "$plist" ]; then
            version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
        fi
        printf 'BetterDisplay：已发现%s' "$BETTERDISPLAY_APP"
        [ -z "$version" ] || printf '（版本 %s）' "$version"
        printf '\n'
        if [ -n "$BETTERDISPLAY_CLI" ]; then
            printf 'BetterDisplay CLI：已发现（仅记录路径，不启动应用）\n'
        else
            warn "BetterDisplay.app 存在，但未找到 CLI 可执行文件；请更新或检查安装完整性"
        fi
    else
        printf 'BetterDisplay：未发现（实体显示器模式不需要；无显示器模式需要它）\n'
    fi
    printf 'BetterDisplay Pro/试用：安装器不会启动、激活或验证许可证；无显示器模式首次连接时需要用户在 BetterDisplay 内完成授权。\n'
}

build_outputs() {
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-install.XXXXXX")"
    mkdir -p "$STAGE/cli-build"

    # These three jobs have no shared output and can run concurrently. The
    # connection action itself remains serialized later because it changes
    # display topology and owns a single Sidecar session.
    (
        cd "$SOURCE_ROOT"
        SDKROOT="$MACOS_SDK" BUILD_DIR="$STAGE/cli-build" ./build.sh --cli-only --build-only
    ) >"$STAGE/build-sidecarctl.log" 2>&1 &
    local cli_pid=$!
    (
        SDKROOT="$MACOS_SDK" "$SWIFTC" -O "$ROOT/DisplayState.swift" -o "$STAGE/display-state"
    ) >"$STAGE/build-display-state.log" 2>&1 &
    local display_pid=$!
    (
        SDKROOT="$MACOS_SDK" "$CLANG" -O2 -framework IOBluetooth "$ROOT/sidecar-bluetooth-radio.c" \
            -o "$STAGE/sidecar-bluetooth-radio"
    ) >"$STAGE/build-bluetooth.log" 2>&1 &
    local bluetooth_pid=$!

    local failed=0
    if ! wait "$cli_pid"; then
        failed=1
        printf '构建失败：sidecarctl\n' >&2
        sed -n '1,120p' "$STAGE/build-sidecarctl.log" >&2 || true
    fi
    if ! wait "$display_pid"; then
        failed=1
        printf '构建失败：display-state\n' >&2
        sed -n '1,120p' "$STAGE/build-display-state.log" >&2 || true
    fi
    if ! wait "$bluetooth_pid"; then
        failed=1
        printf '构建失败：sidecar-bluetooth-radio\n' >&2
        sed -n '1,120p' "$STAGE/build-bluetooth.log" >&2 || true
    fi
    [ "$failed" -eq 0 ] || fail "依赖构建失败；请根据上面的日志修复 Xcode Command Line Tools 后重试"
    [ -x "$STAGE/cli-build/sidecarctl" ] || fail "sidecarctl 构建完成但找不到输出文件"
    cp "$STAGE/cli-build/sidecarctl" "$STAGE/sidecarctl"
    chmod 0755 "$STAGE/sidecarctl"

    local script
    for script in \
        "$ROOT/sidecar-connect-once.sh" \
        "$ROOT/sidecar-connect-wireless-once.sh" \
        "$ROOT/sidecar-ipad-usb-detect.sh" \
        "$ROOT/sidecar-disconnect-once.sh" \
        "$ROOT/sidecar-hotkey.sh" \
        "$ROOT/sidecar-login-ready.sh" \
        "$ROOT/sidecar-doctor.sh"; do
        bash -n "$script" || fail "Shell 语法检查失败：$script"
    done
}

verify_outputs() {
    local file name
    for name in sidecarctl display-state sidecar-bluetooth-radio; do
        file="$STAGE/$name"
        [ -f "$file" ] && [ -x "$file" ] || fail "构建产物不可执行：$name"
        /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O' || \
            fail "构建产物不是有效的 macOS Mach-O 文件：$name"
    done

    # sidecarctl's help path exits 64 by design. Accept that usage status, but
    # reject a dynamic-linker or architecture failure. display-state may return
    # 2 if WindowServer is unavailable; that still proves the process launched.
    local code
    set +e
    "$STAGE/sidecarctl" --help >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -eq 64 ] || fail "sidecarctl 无法启动（退出码 $code）"

    set +e
    "$STAGE/display-state" >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -eq 0 ] || [ "$code" -eq 2 ] || \
        fail "display-state 无法启动（退出码 $code）"
}

if [ "${CI:-}" = "true" ]; then
    BUILD_ONLY=1
fi

install_outputs() {
    mkdir -p "$BIN_DIR" "$CONFIG_DIR" || fail "无法创建安装目录"
    INSTALL_STAGE="$BIN_DIR/.sidecar-auto-install.$$"
    rm -rf "$INSTALL_STAGE"
    mkdir -p "$INSTALL_STAGE"

    # Prepare a new configuration before replacing any installed executable.
    # It is installed with a same-directory rename after the binaries are ready.
    if [ ! -e "$CONFIG_FILE" ]; then
        CONFIG_STAGE="$CONFIG_DIR/.config.$$"
        cat > "$CONFIG_STAGE" <<'EOF'
# Set this to the exact iPad name when more than one iPad is visible.
IPAD_NAME="iPad"
# Optional: set the target iPad USB serial when more than one iPad may be
# plugged in. The detector prints the currently enumerated serial to stdout.
# IPAD_USB_SERIAL_NUMBER=""
# Attempt to enable the Mac-side Handoff preferences before wireless Sidecar.
# The iPad's Handoff switch still must be enabled on the iPad.
AUTO_ENABLE_HANDOFF=1
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
EOF
        chmod 0600 "$CONFIG_STAGE"
    fi

    local name
    for name in \
        sidecarctl \
        display-state \
        sidecar-bluetooth-radio \
        sidecar-connect-once.sh \
        sidecar-connect-wireless-once.sh \
        sidecar-ipad-usb-detect.sh \
        sidecar-disconnect-once.sh \
        sidecar-hotkey.sh \
        sidecar-login-ready.sh \
        sidecar-doctor.sh; do
        if [ -f "$STAGE/$name" ]; then
            cp "$STAGE/$name" "$INSTALL_STAGE/$name"
        else
            cp "$ROOT/$name" "$INSTALL_STAGE/$name"
        fi
        chmod 0755 "$INSTALL_STAGE/$name"
    done

    # Rename each validated file into place. Rename is atomic per executable,
    # and no existing file is removed before its replacement is ready.
    for name in \
        sidecarctl \
        display-state \
        sidecar-bluetooth-radio \
        sidecar-connect-once.sh \
        sidecar-connect-wireless-once.sh \
        sidecar-ipad-usb-detect.sh \
        sidecar-disconnect-once.sh \
        sidecar-hotkey.sh \
        sidecar-login-ready.sh \
        sidecar-doctor.sh; do
        mv -f "$INSTALL_STAGE/$name" "$BIN_DIR/$name"
    done

    # Never overwrite an existing configuration. Both the initial file and its
    # final name are in CONFIG_DIR, so this rename is atomic on that filesystem.
    if [ -n "$CONFIG_STAGE" ]; then
        if [ ! -e "$CONFIG_FILE" ]; then
            mv "$CONFIG_STAGE" "$CONFIG_FILE"
        else
            rm -f "$CONFIG_STAGE"
        fi
        CONFIG_STAGE=""
    fi
    rm -rf "$INSTALL_STAGE"
    INSTALL_STAGE=""
}

check_platform
check_sources
detect_betterdisplay
build_outputs
verify_outputs
[ "$BUILD_ONLY" -eq 0 ] || {
    printf '\n构建和产物验证通过（未安装）。\n'
    exit 0
}
install_outputs

printf '\n安装完成，已安装：\n'
printf '  %s\n' \
    "$BIN_DIR/sidecarctl" \
    "$BIN_DIR/display-state" \
    "$BIN_DIR/sidecar-bluetooth-radio" \
    "$BIN_DIR/sidecar-connect-once.sh" \
    "$BIN_DIR/sidecar-connect-wireless-once.sh" \
    "$BIN_DIR/sidecar-disconnect-once.sh" \
    "$BIN_DIR/sidecar-ipad-usb-detect.sh" \
    "$BIN_DIR/sidecar-login-ready.sh" \
    "$BIN_DIR/sidecar-doctor.sh"
if [ -f "$CONFIG_FILE" ]; then
    printf '配置文件：%s（已有配置不会被覆盖）\n' "$CONFIG_FILE"
fi

case ":${PATH:-}:" in
    *":$BIN_DIR:"*) ;;
    *)
        printf '\n如果终端找不到 sidecarctl，可把下面一行加入 ~/.zshrc：\n'
        printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
        ;;
esac

cat <<NEXT

接下来只需在 macOS“快捷指令”中各创建一个“运行 Shell 脚本”快捷指令：

  名称：连接 Sidecar
  脚本：exec "$BIN_DIR/sidecar-connect-once.sh" auto

  名称：连接无线 Sidecar（排障）
  脚本：exec "$BIN_DIR/sidecar-connect-wireless-once.sh"

  名称：断开 Sidecar
  脚本：exec "$BIN_DIR/sidecar-disconnect-once.sh"

诊断命令（只读，不连接 iPad）：
  "$BIN_DIR/sidecar-doctor.sh"

安装器没有启动 Sidecar，也没有创建快捷指令或授予隐私权限。
首次无线连接请在 Mac 解锁、iPad 唤醒并允许 Bluetooth 权限提示时完成一次授权。
无显示器模式请先打开 BetterDisplay，确认虚拟屏幕功能和 Pro/试用资格；实体显示器模式不需要 BetterDisplay。
NEXT
