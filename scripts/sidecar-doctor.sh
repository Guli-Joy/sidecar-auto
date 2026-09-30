#!/bin/bash
# Read-only Sidecar installation and environment diagnostic.
# This script never connects/disconnects Sidecar, changes radios, starts
# BetterDisplay, creates displays, or writes configuration.

set -u

CONFIG="${SIDECAR_AUTO_CONFIG:-$HOME/.config/sidecar-auto/config}"
: "${BIN_DIR:=${SIDECAR_AUTO_BIN_DIR:-$HOME/.local/bin}}"
: "${SIDECAR_BIN:=$BIN_DIR/sidecarctl}"
: "${DISPLAY_STATE_BIN:=$BIN_DIR/display-state}"
: "${USB_DETECT_BIN:=${SIDECAR_USB_DETECT_BIN:-$BIN_DIR/sidecar-ipad-usb-detect.sh}}"
: "${NETWORKSETUP_BIN:=/usr/sbin/networksetup}"
: "${SYSTEM_PROFILER_BIN:=/usr/sbin/system_profiler}"
: "${BETTERDISPLAY_CLI:=}"
: "${BETTERDISPLAY_APP:=}"
: "${VIRTUAL_DISPLAY_NAME:=SidecarHeadlessFallback}"
: "${VIRTUAL_DISPLAY_BACKEND:=auto}"
: "${VIRTUAL_DISPLAY_HELPER:=$BIN_DIR/sidecar-virtual-display}"
: "${IPAD_NAME:=}"

# The connection scripts use a shell-readable config, but a diagnostic should
# never execute configuration contents. Read only plain KEY=value fields.
config_value() {
    local key="$1"
    [ -r "$CONFIG" ] || return 0
    /usr/bin/awk -v key="$key" '
        {
            line = $0
            sub(/^[ \t]*/, "", line)
            if (line ~ /^#/ || index(line, "=") == 0) next
            name = line
            sub(/=.*/, "", name)
            if (name != key) next
            value = substr(line, index(line, "=") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            if (length(value) >= 2) {
                first = substr(value, 1, 1)
                last = substr(value, length(value), 1)
                if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047"))
                    value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$CONFIG"
}

loaded="$(config_value SIDECAR_BIN)"; [ -z "$loaded" ] || SIDECAR_BIN="$loaded"
loaded="$(config_value DISPLAY_STATE_BIN)"; [ -z "$loaded" ] || DISPLAY_STATE_BIN="$loaded"
loaded="$(config_value SIDECAR_USB_DETECT_BIN)"; [ -z "$loaded" ] || USB_DETECT_BIN="$loaded"
loaded="$(config_value BETTERDISPLAY_CLI)"; [ -z "$loaded" ] || BETTERDISPLAY_CLI="$loaded"
loaded="$(config_value BETTERDISPLAY_APP)"; [ -z "$loaded" ] || BETTERDISPLAY_APP="$loaded"
loaded="$(config_value VIRTUAL_DISPLAY_NAME)"; [ -z "$loaded" ] || VIRTUAL_DISPLAY_NAME="$loaded"
loaded="$(config_value VIRTUAL_DISPLAY_BACKEND)"; [ -z "$loaded" ] || VIRTUAL_DISPLAY_BACKEND="$loaded"
loaded="$(config_value VIRTUAL_DISPLAY_HELPER)"; [ -z "$loaded" ] || VIRTUAL_DISPLAY_HELPER="$loaded"
loaded="$(config_value IPAD_NAME)"; [ -z "$loaded" ] || IPAD_NAME="$loaded"

run_limited() {
    local seconds="$1"
    shift
    if [ -x /usr/bin/perl ]; then
        /usr/bin/perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    else
        "$@"
    fi
}

section() { printf '\n== %s ==\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
note() { printf '[INFO] %s\n' "$*"; }
problem() { printf '[CHECK] %s\n' "$*"; }

section "系统与编译工具"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    ok "macOS $(/usr/bin/sw_vers -productVersion 2>/dev/null || printf 'unknown') ($(uname -m))"
else
    problem "当前系统不是 macOS"
fi
if command -v swiftc >/dev/null 2>&1; then ok "swiftc: $(command -v swiftc)"; else problem "缺少 swiftc / Xcode Command Line Tools"; fi
if command -v clang >/dev/null 2>&1; then ok "clang: $(command -v clang)"; else problem "缺少 clang / Xcode Command Line Tools"; fi
if command -v xcrun >/dev/null 2>&1; then
    sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [ -d "$sdk" ] && ok "macOS SDK: $sdk" || problem "无法找到 macOS SDK"
else
    problem "缺少 xcrun"
fi

section "安装产物与配置"
for binary in \
    "$SIDECAR_BIN" \
    "$DISPLAY_STATE_BIN" \
    "$BIN_DIR/sidecar-bluetooth-radio" \
    "$VIRTUAL_DISPLAY_HELPER" \
    "$USB_DETECT_BIN" \
    "$BIN_DIR/sidecar-connect-once.sh" \
    "$BIN_DIR/sidecar-connect-wireless-once.sh" \
    "$BIN_DIR/sidecar-disconnect-once.sh" \
    "$BIN_DIR/sidecar-login-ready.sh"; do
    if [ -x "$binary" ]; then ok "$binary"; else problem "找不到或不可执行：$binary"; fi
done
if [ -r "$CONFIG" ]; then
    ok "配置文件：$CONFIG"
    printf 'IPAD_NAME=%s\n' "${IPAD_NAME:-未设置}"
    printf 'VIRTUAL_DISPLAY_NAME=%s\n' "$VIRTUAL_DISPLAY_NAME"
    printf 'VIRTUAL_DISPLAY_BACKEND=%s\n' "$VIRTUAL_DISPLAY_BACKEND"
else
    problem "配置文件不存在：$CONFIG"
fi

section "Sidecar 状态（只读）"
if [ -x "$SIDECAR_BIN" ]; then
    # snapshot performs one SidecarCore enumeration for both the configured
    # target and every visible session. This keeps the diagnostic consistent
    # with the smart shortcut and avoids status/list races during discovery.
    if [ -n "$IPAD_NAME" ]; then
        snapshot_output="$(run_limited 8 "$SIDECAR_BIN" snapshot "$IPAD_NAME" 2>&1)"
    else
        snapshot_output="$(run_limited 8 "$SIDECAR_BIN" snapshot 2>&1)"
    fi
    snapshot_code=$?
    printf '%s\n' "$snapshot_output"
    if [ "$snapshot_code" -ne 0 ]; then
        problem "Sidecar 快照读取失败（退出码 $snapshot_code）"
    else
        target_state="$(printf '%s\n' "$snapshot_output" | /usr/bin/perl -MJSON::PP -0777 -ne '$d=eval { decode_json($_) }; print(($d && ref($d->{target}) eq "HASH") ? ($d->{target}{state}//"unknown") : "unknown")')"
        case "$target_state" in
            connected) ok "目标 iPad 当前已连接" ;;
            disconnected|not_found) note "目标 iPad 当前未连接" ;;
            *) problem "无法确定目标 iPad 的 Sidecar 状态：$target_state" ;;
        esac
    fi
else
    problem "sidecarctl 不存在，跳过 Sidecar 状态"
fi

section "USB 与显示拓扑（只读）"
if [ -x "$USB_DETECT_BIN" ]; then
    usb_output="$(run_limited 8 "$USB_DETECT_BIN" 2>&1)"
    usb_code=$?
    printf '%s\n' "$usb_output"
    case "$usb_code" in
        0) ok "检测到一台匹配的 iPad USB 数据设备" ;;
        1) note "未检测到 iPad USB 数据设备（智能模式将选择无线）" ;;
        3) problem "检测到多台 iPad USB 设备，请设置 IPAD_USB_SERIAL_NUMBER" ;;
        *) problem "USB 检测失败（退出码 $usb_code）" ;;
    esac
else
    problem "USB 检测程序不存在"
fi
if [ -x "$DISPLAY_STATE_BIN" ]; then
    display_output="$(run_limited 8 "$DISPLAY_STATE_BIN" 2>&1)"
    display_code=$?
    printf '%s\n' "$display_output"
    [ "$display_code" -eq 0 ] || problem "显示拓扑读取失败（退出码 $display_code）"
else
    problem "display-state 不存在"
fi

section "无线前置条件（只读）"
if [ -x "$NETWORKSETUP_BIN" ]; then
    wifi_device="$(run_limited 5 "$NETWORKSETUP_BIN" -listallhardwareports 2>/dev/null | awk '/^Hardware Port: Wi-Fi$/ { getline; if ($1 == "Device:") { print $2; exit } }')"
    if [ -n "$wifi_device" ]; then
        wifi_output="$(run_limited 5 "$NETWORKSETUP_BIN" -getairportpower "$wifi_device" 2>&1)"
        printf '%s\n' "$wifi_output"
    else
        problem "无法识别 Wi-Fi 接口"
    fi
else
    problem "networksetup 不存在"
fi
if [ -x "$SYSTEM_PROFILER_BIN" ]; then
    bluetooth_output="$(run_limited 8 "$SYSTEM_PROFILER_BIN" SPBluetoothDataType -json 2>&1)"
    bluetooth_code=$?
    if [ "$bluetooth_code" -eq 0 ]; then
        printf '%s\n' "$bluetooth_output" | grep -E '"controller_state"|"controller_address"' | head -4
        if printf '%s\n' "$bluetooth_output" | grep -Eq '"controller_state"[[:space:]]*:[[:space:]]*"attrib_on"'; then
            ok "Mac 蓝牙报告为开启"
        else
            problem "无法确认 Mac 蓝牙已开启"
        fi
    else
        problem "蓝牙状态读取失败（退出码 $bluetooth_code）"
    fi
else
    problem "system_profiler 不存在"
fi

section "虚拟屏后端（只读，不启动）"
case "$VIRTUAL_DISPLAY_BACKEND" in
    builtin|auto)
        if [ -x "$VIRTUAL_DISPLAY_HELPER" ]; then
            virtual_output="$(run_limited 5 "$VIRTUAL_DISPLAY_HELPER" status 2>&1)"
            printf '%s\n' "$virtual_output"
            printf '%s\n' "$virtual_output" | grep -Eq '(^|[[:space:]])online=1([[:space:]]|$)' && ok "项目内置虚拟屏在线" || note "项目内置虚拟屏当前未在线（连接时按需创建）"
        else
            problem "项目内置虚拟屏 helper 不存在：$VIRTUAL_DISPLAY_HELPER"
        fi
        ;;
esac
section "BetterDisplay（只读，不启动）"
if [ -z "$BETTERDISPLAY_APP" ]; then
    for candidate in "/Applications/BetterDisplay.app" "$HOME/Applications/BetterDisplay.app"; do
        [ -d "$candidate" ] && BETTERDISPLAY_APP="$candidate" && break
    done
fi
if [ -z "$BETTERDISPLAY_CLI" ] && command -v betterdisplaycli >/dev/null 2>&1; then
    BETTERDISPLAY_CLI="$(command -v betterdisplaycli)"
fi
if [ -z "$BETTERDISPLAY_CLI" ] && [ -n "$BETTERDISPLAY_APP" ] && [ -x "$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay" ]; then
    BETTERDISPLAY_CLI="$BETTERDISPLAY_APP/Contents/MacOS/BetterDisplay"
fi
if [ -n "$BETTERDISPLAY_APP" ]; then
    ok "BetterDisplay.app：$BETTERDISPLAY_APP"
else
    if [ "$VIRTUAL_DISPLAY_BACKEND" = "betterdisplay" ]; then
        problem "未发现 BetterDisplay（当前配置要求 BetterDisplay）"
    else
        note "未发现 BetterDisplay（当前配置可使用项目内置虚拟屏）"
    fi
fi
if [ -n "$BETTERDISPLAY_CLI" ]; then
    ok "BetterDisplay CLI：$BETTERDISPLAY_CLI"
else
    if [ "$VIRTUAL_DISPLAY_BACKEND" = "betterdisplay" ]; then problem "未发现 BetterDisplay CLI"; else note "未发现 BetterDisplay CLI（当前配置未强制使用它）"; fi
fi
if [ -n "$BETTERDISPLAY_CLI" ] && /usr/bin/pgrep -x BetterDisplay >/dev/null 2>&1; then
    pro_output="$(run_limited 8 "$BETTERDISPLAY_CLI" get -proAvailable 2>&1)"
    pro_code=$?
    printf '%s\n' "$pro_output"
    [ "$pro_code" -eq 0 ] && note "BetterDisplay 已运行；上面是只读 Pro 能力查询结果" || problem "无法查询 BetterDisplay Pro 状态（退出码 $pro_code）"
else
    note "BetterDisplay 未运行，跳过 CLI 查询以避免启动 GUI 或触发授权提示"
fi

section "结论"
note "这是只读诊断；未连接或断开 Sidecar，未修改 Wi-Fi、蓝牙、Handoff、BetterDisplay 或配置文件。"
