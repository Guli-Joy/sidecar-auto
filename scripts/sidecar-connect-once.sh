#!/bin/bash
# Connect Sidecar once, only when explicitly invoked by the user.
# The default is auto: a uniquely enumerated iPad USB data device selects
# ForceUSB; otherwise the action selects ForceAWDL. Explicit wired/wireless
# modes remain available for diagnostics. There is no retry or transport
# fallback after the selected request starts.

set -u

CONFIG="${SIDECAR_AUTO_CONFIG:-$HOME/.config/sidecar-auto/config}"
[ -r "$CONFIG" ] && . "$CONFIG"

# Shortcuts asks for a one-time “Run Shell Script” confirmation before this
# process starts.  The generated shortcut sets this flag so the setup helper
# can show a truthful, per-shortcut authorization state without claiming that
# macOS permissions were granted silently.
SLUG="connect-sidecar"
mark_shortcut_invocation() {
    # New templates set an explicit marker.  Keep a bounded parent-process
    # fallback so shortcuts imported before this release can still record the
    # first-run consent after they are launched from Shortcuts.app.
    local launched_by_shortcuts=0 parent="" grandparent=""
    if [ "${SIDECAR_SHORTCUT_INVOCATION:-0}" = "1" ]; then
        launched_by_shortcuts=1
    elif [ -n "${PPID:-}" ]; then
        parent="$(/bin/ps -o command= -p "$PPID" 2>/dev/null || true)"
        grandparent="$(/bin/ps -o command= -p "$(/bin/ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')" 2>/dev/null || true)"
        case "$parent $grandparent" in
            *Shortcuts*|*shortcuts*) launched_by_shortcuts=1 ;;
        esac
    fi
    [ "$launched_by_shortcuts" = "1" ] || return 0
    local state_dir="$HOME/Library/Application Support/Sidecar Auto/Shortcuts"
    local marker="$state_dir/${SLUG}.shell-status"
    mkdir -p "$state_dir" 2>/dev/null || return 0
    {
        printf 'authorized=1\n'
        printf 'timestamp=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } >"$marker.tmp.$$" 2>/dev/null || return 0
    chmod 600 "$marker.tmp.$$" 2>/dev/null || true
    mv -f "$marker.tmp.$$" "$marker" 2>/dev/null || rm -f "$marker.tmp.$$"
}
mark_shortcut_invocation

CONNECTION_MODE="${1:-auto}"
case "$CONNECTION_MODE" in
    auto)
        CONNECT_OPTION=""
        TRANSPORT_LABEL="自动"
        NOTIFY_TITLE="Sidecar"
        ;;
    wired)
        CONNECT_OPTION="--wired"
        TRANSPORT_LABEL="有线"
        NOTIFY_TITLE="USB Sidecar"
        ;;
    wireless)
        CONNECT_OPTION="--wireless"
        TRANSPORT_LABEL="无线"
        NOTIFY_TITLE="无线 Sidecar"
        ;;
    *)
        printf 'usage: %s [auto|wired|wireless]\n' "$0" >&2
        exit 64
        ;;
esac

: "${IPAD_NAME:=iPad}"
: "${SIDECAR_BIN:=$HOME/.local/bin/sidecarctl}"
: "${SIDECAR_USB_DETECT_BIN:=$HOME/.local/bin/sidecar-ipad-usb-detect.sh}"
: "${SIDECAR_BLUETOOTH_RADIO_BIN:=$HOME/.local/bin/sidecar-bluetooth-radio}"
: "${BLUETOOTH_PROFILER_BIN:=/usr/sbin/system_profiler}"
: "${NETWORKSETUP_BIN:=/usr/sbin/networksetup}"
: "${AUTO_ENABLE_HANDOFF:=1}"
: "${DEFAULTS_BIN:=/usr/bin/defaults}"
: "${DISPLAY_STATE_BIN:=$HOME/.local/bin/display-state}"
: "${DISPLAY_VERIFY_SECONDS:=12}"
: "${DISPLAY_VERIFY_INTERVAL:=1}"
# A monitor can remain in CoreGraphics briefly after its cable is removed.
# Do not decide between the physical and headless paths from that transient
# snapshot.  Two equal samples are enough to establish the current topology;
# the bounded window keeps a hotkey from hanging indefinitely during a broken
# display reconfiguration.
: "${DISPLAY_SETTLE_SECONDS:=8}"
: "${DISPLAY_SETTLE_INTERVAL:=1}"
: "${DISPLAY_SETTLE_SAMPLES:=2}"
: "${DISPLAY_SETTLE_MIN_SECONDS:=5}"
: "${SIDECAR_STATUS_TIMEOUT_SECONDS:=10}"
: "${SIDECAR_BLUETOOTH_PREPARE_TIMEOUT_SECONDS:=12}"
: "${SIDECAR_CONNECT_TIMEOUT_SECONDS:=45}"
: "${BETTERDISPLAY_CLI:=}"
: "${BETTERDISPLAY_APP:=}"
# Headless provider: builtin uses the bundled resident helper; betterdisplay
# keeps the existing CLI path; auto prefers builtin and falls back only when
# the private macOS API is unavailable.
: "${VIRTUAL_DISPLAY_BACKEND:=auto}"
: "${VIRTUAL_DISPLAY_HELPER:=$HOME/.local/bin/sidecar-virtual-display}"
: "${BUILTIN_VIRTUAL_DISPLAY_NAME:=SidecarHeadlessFallback}"
# This must be an independent BetterDisplay virtual screen.  A virtual screen
# associated with the iPad is controlled by BetterDisplay's association rules
# and cannot be brought online before Sidecar exists.
: "${VIRTUAL_DISPLAY_NAME:=SidecarHeadlessFallback}"
: "${BETTERDISPLAY_TIMEOUT_SECONDS:=8}"
: "${HEADLESS_DISPLAY_WAIT_SECONDS:=8}"
: "${BETTERDISPLAY_SIDECAR_SPECIFIER:=}"
: "${LOG_FILE:=$HOME/Library/Logs/sidecar-auto.log}"
: "${AUTO_CREATE_VIRTUAL_DISPLAY:=1}"
: "${SOUND_START:=/System/Library/Sounds/Tink.aiff}"
: "${SOUND_SUCCESS:=/System/Library/Sounds/Glass.aiff}"
: "${SOUND_FAILURE:=/System/Library/Sounds/Basso.aiff}"
: "${VOICE:=Tingting}"
: "${SPEAK:=1}"
: "${SIDECAR_AUTO_TEST_MODE:=0}"
PROGRESS_SPEECH_PID=""
ACTIVE_VIRTUAL_DISPLAY_BACKEND=""
BUILTIN_FALLBACK_STARTED_BY_OPERATION=0
BETTERDISPLAY_FALLBACK_CHANGED_BY_OPERATION=0
PRESERVE_FALLBACK_ON_EXIT=0
EXIT_CLEANUP_RUNNING=0
INITIAL_USB_FILE=""
INITIAL_USB_CODE=""
LOCK_DIR="$HOME/Library/Caches/sidecar-auto/explicit-action.lock"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_DIR")" 2>/dev/null || true
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"; }
monotonic_milliseconds() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.0f", 1000 * clock_gettime(CLOCK_MONOTONIC)'
}
notify() {
    [ "$SIDECAR_AUTO_TEST_MODE" = "1" ] && return 0
    /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}
notify_detail() {
    [ "$SIDECAR_AUTO_TEST_MODE" = "1" ] && return 0
    /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}
play_sound() {
    [ "$SIDECAR_AUTO_TEST_MODE" = "1" ] && return 0
    [ -x /usr/bin/afplay ] && [ -r "$1" ] && /usr/bin/afplay "$1" >/dev/null 2>&1 || true
}
speak() {
    [ "$SIDECAR_AUTO_TEST_MODE" = "1" ] && return 0
    [ "${SPEAK:-1}" = "0" ] && return 0
    [ -x /usr/bin/say ] || return 0
    /usr/bin/say -v "$VOICE" "$1" >/dev/null 2>&1 || /usr/bin/say "$1" >/dev/null 2>&1 || true
}
feedback() {
    # Keep these calls synchronous so the spoken state is heard before the
    # script exits, while allowing missing audio devices to be harmless.
    if [[ "$PROGRESS_SPEECH_PID" =~ ^[0-9]+$ ]]; then
        wait "$PROGRESS_SPEECH_PID" 2>/dev/null || true
        PROGRESS_SPEECH_PID=""
    fi
    play_sound "$1"
    speak "$2"
}
feedback_progress() {
    # Keep the start tone immediate while allowing independent read-only
    # preflight to proceed during the progress announcement.
    play_sound "$1"
    if [ "$SIDECAR_AUTO_TEST_MODE" != "1" ] && [ "${SPEAK:-1}" != "0" ] && [ -x /usr/bin/say ]; then
        ( /usr/bin/say -v "$VOICE" "$2" >/dev/null 2>&1 || /usr/bin/say "$2" >/dev/null 2>&1 || true ) &
        PROGRESS_SPEECH_PID=$!
    fi
}
cleanup_owned_fallback() {
    # Only reclaim resources this invocation created or enabled. A user-owned
    # virtual display must survive a failed connection and an interrupted
    # operation. BetterDisplay is never quit here because it may contain other
    # displays or be used by the user for unrelated work.
    [ "$PRESERVE_FALLBACK_ON_EXIT" = "1" ] && return 0
    if [ "$BUILTIN_FALLBACK_STARTED_BY_OPERATION" = "1" ] && [ -x "$VIRTUAL_DISPLAY_HELPER" ]; then
        local builtin_output builtin_code
        builtin_output="$(run_builtin_virtual destroy 2>&1)"
        builtin_code=$?
        if [ "$builtin_code" -eq 0 ]; then
            log "cleaned up built-in virtual display created by this operation"
        else
            log "could not clean up built-in virtual display after interrupted/failed operation (exit=$builtin_code): $builtin_output"
        fi
    fi
    if [ "$BETTERDISPLAY_FALLBACK_CHANGED_BY_OPERATION" = "1" ] && [ -n "${BETTERDISPLAY_CLI_RESOLVED:-}" ]; then
        local better_output better_code
        better_output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -connected=off 2>&1)"
        better_code=$?
        if [ "$better_code" -eq 0 ]; then
            log "cleaned up BetterDisplay virtual fallback changed by this operation"
        else
            log "could not clean up BetterDisplay fallback after interrupted/failed operation (exit=$better_code): $better_output"
        fi
    fi
}
handle_interrupt() {
    log "connection operation interrupted by signal; beginning owned fallback cleanup"
    exit 130
}
cleanup_on_exit() {
    local exit_code=$?
    if [ "$EXIT_CLEANUP_RUNNING" = "1" ]; then
        exit "$exit_code"
    fi
    EXIT_CLEANUP_RUNNING=1
    if [ "$exit_code" -ne 0 ]; then cleanup_owned_fallback; fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT
    exit "$exit_code"
}
run_with_timeout() {
    # macOS does not ship GNU timeout. Perl is present on supported macOS
    # installations and lets each explicit command have a hard upper bound.
    # The direct fallback keeps the helper usable on stripped-down test hosts.
    local seconds="$1"
    shift
    if [ -x /usr/bin/perl ]; then
        /usr/bin/perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    else
        "$@"
    fi
}
run_sidecar_status() {
    run_with_timeout "$SIDECAR_STATUS_TIMEOUT_SECONDS" "$SIDECAR_BIN" status "$@"
}
run_sidecar_snapshot() {
    # `snapshot` performs one SidecarCore device enumeration and returns both
    # the requested target state and the all-device counts. Keeping this as a
    # separate helper makes older diagnostic/status calls below unchanged,
    # while the smart connect gate avoids starting sidecarctl twice.
    run_with_timeout "$SIDECAR_STATUS_TIMEOUT_SECONDS" "$SIDECAR_BIN" snapshot "$@"
}
set_transport_mode() {
    case "$1" in
        wired)
            CONNECTION_MODE="wired"
            CONNECT_OPTION="--wired"
            TRANSPORT_LABEL="有线"
            NOTIFY_TITLE="USB Sidecar"
            ;;
        wireless)
            CONNECTION_MODE="wireless"
            CONNECT_OPTION="--wireless"
            TRANSPORT_LABEL="无线"
            NOTIFY_TITLE="无线 Sidecar"
            ;;
        *) return 64 ;;
    esac
}
resolve_auto_transport() {
    local output code
    if [ ! -x "$SIDECAR_USB_DETECT_BIN" ]; then
        log "auto transport refused: iPad USB detector missing: $SIDECAR_USB_DETECT_BIN"
        feedback "$SOUND_FAILURE" "找不到 iPad 数据连接检测程序，无法判断连接方式，未连接随航"
        notify "$NOTIFY_TITLE" "缺少 iPad USB 数据连接检测程序，未连接随航"
        return 127
    fi

    if [ -n "$INITIAL_USB_FILE" ] && [ -r "$INITIAL_USB_FILE.output" ] && [ -r "$INITIAL_USB_FILE.code" ]; then
        output="$(cat "$INITIAL_USB_FILE.output" 2>/dev/null)"
        code="$(cat "$INITIAL_USB_FILE.code" 2>/dev/null)"
        log "using cached parallel USB probe result (exit=$code)"
    else
        output="$(run_with_timeout 5 "$SIDECAR_USB_DETECT_BIN" 2>&1)"
        code=$?
    fi
    case "$code" in
        0)
            if ! printf '%s\n' "$output" | /usr/bin/grep -Eq '^USB_IPAD_MATCHED([[:space:]]|$)'; then
                log "auto transport refused: USB detector returned unexpected success output: $output"
                feedback "$SOUND_FAILURE" "iPad 数据连接检测结果异常，未连接随航"
                notify_detail "$NOTIFY_TITLE" "USB 检测结果异常，未连接随航。详情：$output"
                return 2
            fi
            set_transport_mode wired || return $?
            log "auto transport selected wired: $output"
            feedback "$SOUND_START" "检测到 iPad 数据线，正在连接有线随航"
            ;;
        1)
            if ! printf '%s\n' "$output" | /usr/bin/grep -Eq '^USB_IPAD_NOT_FOUND([[:space:]]|$)'; then
                log "auto transport refused: USB detector returned unexpected no-match output: $output"
                feedback "$SOUND_FAILURE" "无法确认 iPad 数据线状态，未连接随航"
                notify_detail "$NOTIFY_TITLE" "USB 检测结果异常，未连接随航。详情：$output"
                return 2
            fi
            set_transport_mode wireless || return $?
            log "auto transport selected wireless: $output"
            feedback "$SOUND_START" "没有检测到 iPad 数据线，正在准备无线随航"
            ;;
        3)
            log "auto transport refused: multiple iPad USB devices: $output"
            feedback "$SOUND_FAILURE" "检测到多台 iPad，请配置 USB 序列号后再连接"
            notify_detail "$NOTIFY_TITLE" "检测到多台 iPad USB 设备，已停止以免连接错误设备。请在配置中填写 IPAD_USB_SERIAL_NUMBER。"
            return 3
            ;;
        *)
            log "auto transport refused: USB detector failed (exit=$code): $output"
            feedback "$SOUND_FAILURE" "无法确认 iPad 数据线状态，为避免误连，未连接随航"
            notify_detail "$NOTIFY_TITLE" "无法确认 iPad USB 数据连接状态，未连接随航。详情：$output"
            return 2
            ;;
    esac
}
wifi_device() {
    [ -x "$NETWORKSETUP_BIN" ] || return 1
    run_with_timeout 5 "$NETWORKSETUP_BIN" -listallhardwareports 2>/dev/null |
        /usr/bin/awk '
            /^Hardware Port: Wi-Fi$/ { getline; if ($1 == "Device:") { print $2; exit } }
        '
}
wifi_is_on() {
    local device output
    device="$1"
    output="$(run_with_timeout 5 "$NETWORKSETUP_BIN" -getairportpower "$device" 2>&1)" || return 2
    printf '%s\n' "$output" | /usr/bin/grep -Eqi "(^|[[:space:]])on([[:space:]]|$)"
}
ensure_mac_wifi_on() {
    local device output code
    device="$(wifi_device)"
    if [ -z "$device" ]; then
        log "wireless preflight failed: could not identify the Wi-Fi hardware interface"
        feedback "$SOUND_FAILURE" "无法识别 Mac 的 Wi-Fi 设备，未连接无线随航"
        notify "$NOTIFY_TITLE" "无法识别 Wi-Fi 设备，未连接无线随航"
        return 1
    fi
    if wifi_is_on "$device"; then
        log "wireless preflight: Mac Wi-Fi is already on ($device)"
        return 0
    fi
    output="$(run_with_timeout 10 "$NETWORKSETUP_BIN" -setairportpower "$device" on 2>&1)"
    code=$?
    if [ "$code" -eq 0 ] && wifi_is_on "$device"; then
        log "wireless preflight: enabled Mac Wi-Fi and verified it on ($device)"
        return 0
    fi
    log "wireless preflight failed: could not enable/verify Mac Wi-Fi ($device, exit=$code): $output"
    feedback "$SOUND_FAILURE" "Mac 的 Wi-Fi 未能开启，请检查系统设置或权限"
    notify_detail "$NOTIFY_TITLE" "无法开启或确认 Mac Wi-Fi，未连接无线随航。详情：$output"
    return 1
}
ensure_mac_bluetooth_on() {
    local output code profiler_output profiler_code
    if [ ! -x "$SIDECAR_BLUETOOTH_RADIO_BIN" ]; then
        log "wireless preflight failed: Bluetooth radio helper missing: $SIDECAR_BLUETOOTH_RADIO_BIN"
        feedback "$SOUND_FAILURE" "找不到蓝牙检测程序，无法确认 Mac 蓝牙状态"
        notify "$NOTIFY_TITLE" "缺少蓝牙开关辅助程序，未连接无线随航"
        return 1
    fi
    # system_profiler can read the controller state without invoking the
    # private IOBluetooth preference API. This avoids a first-run TCC prompt
    # from Shortcuts when Bluetooth is already on, which would otherwise hang
    # invisibly on a headless Mac.
    if [ -x "$BLUETOOTH_PROFILER_BIN" ]; then
        profiler_output="$(run_with_timeout 6 "$BLUETOOTH_PROFILER_BIN" SPBluetoothDataType -json 2>&1)"
        profiler_code=$?
        if [ "$profiler_code" -eq 0 ] && printf '%s\n' "$profiler_output" | /usr/bin/grep -Eq '"controller_state"[[:space:]]*:[[:space:]]*"attrib_on"'; then
            log "wireless preflight: Mac Bluetooth is already on (system_profiler)"
            return 0
        fi
        if [ "$profiler_code" -eq 0 ] && printf '%s\n' "$profiler_output" | /usr/bin/grep -Eq '"controller_state"[[:space:]]*:[[:space:]]*"attrib_off"'; then
            log "wireless preflight: system_profiler reports Mac Bluetooth off; attempting to enable it"
        else
            # The JSON includes nearby device names and identifiers; keep that
            # data out of the persistent diagnostic log.
            log "wireless preflight: system_profiler could not confirm Bluetooth state (exit=$profiler_code); attempting helper"
        fi
    fi
    feedback "$SOUND_START" "Mac 蓝牙未确认开启，正在自动开启并核验"
    output="$(run_with_timeout "$SIDECAR_BLUETOOTH_PREPARE_TIMEOUT_SECONDS" "$SIDECAR_BLUETOOTH_RADIO_BIN" prepare 2>&1)"
    code=$?
    if [ "$code" -eq 0 ]; then
        log "wireless preflight: Mac Bluetooth is on: $output"
        return 0
    fi
    if [ "$code" -eq 142 ]; then
        log "wireless preflight failed: Bluetooth helper timed out, likely waiting for the Shortcuts Bluetooth permission prompt: $output"
        feedback "$SOUND_FAILURE" "蓝牙授权提示无法在无屏幕状态下处理，请先接显示器运行一次快捷指令并允许快捷指令使用蓝牙"
        notify "$NOTIFY_TITLE" "需要先在有屏幕时允许快捷指令使用蓝牙；本次未连接"
        return 1
    fi
    log "wireless preflight failed: could not enable/verify Mac Bluetooth (exit=$code): $output"
    feedback "$SOUND_FAILURE" "Mac 蓝牙未能开启或验证，请检查蓝牙设置"
    notify_detail "$NOTIFY_TITLE" "无法开启或确认 Mac 蓝牙，未连接无线随航。详情：$output"
    return 1
}
handoff_pref_is_on() {
    local key="$1" value
    [ -x "$DEFAULTS_BIN" ] || return 2
    value="$(run_with_timeout 5 "$DEFAULTS_BIN" read com.apple.coreservices.useractivityd "$key" 2>/dev/null || true)"
    printf '%s\n' "$value" | /usr/bin/grep -Eqi '^(1|true|yes|on)$'
}
ensure_handoff_on() {
    local advertising_write receiving_write
    if [ "$AUTO_ENABLE_HANDOFF" != "1" ]; then
        log "wireless preflight: automatic Handoff preference changes disabled by configuration"
        return 0
    fi
    if handoff_pref_is_on ActivityAdvertisingAllowed && handoff_pref_is_on ActivityReceivingAllowed; then
        log "wireless preflight: Handoff preference values are enabled; runtime availability is not exposed by a supported status API"
        return 0
    fi
    if [ ! -x "$DEFAULTS_BIN" ]; then
        log "wireless preflight: defaults command unavailable; could not request Mac Handoff enablement"
        speak "无法自动开启 Mac 接力，继续尝试无线随航"
        return 0
    fi
    "$DEFAULTS_BIN" write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true >/dev/null 2>&1
    advertising_write=$?
    "$DEFAULTS_BIN" write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true >/dev/null 2>&1
    receiving_write=$?
    if [ "$advertising_write" -eq 0 ] && [ "$receiving_write" -eq 0 ]; then
        # These preference keys are private macOS implementation details.
        # Writing them is only a best-effort request: reading the stored values
        # back cannot establish the effective Handoff state. Do not restart
        # useractivityd here, since that can interrupt active Continuity tasks.
        log "wireless preflight: requested Mac Handoff preference enablement; effective runtime state is unverified"
        speak "已请求开启 Mac 接力，实际状态无法确认，继续尝试无线随航"
    else
        log "wireless preflight: Handoff preference request failed (advertising_exit=$advertising_write receiving_exit=$receiving_write); runtime state is unknown"
        speak "无法确认 Mac 接力已开启，继续尝试无线随航"
    fi
    return 0
}
prepare_wireless_radios() {
    # Only the Mac radios are under this script's control. Handoff preferences
    # are best-effort on macOS releases that expose them; the iPad's Wi-Fi,
    # Bluetooth and Handoff settings cannot be changed remotely from the Mac.
    ensure_mac_wifi_on || return $?
    ensure_mac_bluetooth_on || return $?
    ensure_handoff_on || return $?
}
resolve_betterdisplay_cli() {
    local candidate app
    BETTERDISPLAY_CLI_RESOLVED=""
    BETTERDISPLAY_APP_RESOLVED=""

    if [ -n "${BETTERDISPLAY_CLI:-}" ] && [ -x "$BETTERDISPLAY_CLI" ]; then
        BETTERDISPLAY_CLI_RESOLVED="$BETTERDISPLAY_CLI"
    elif command -v betterdisplaycli >/dev/null 2>&1; then
        BETTERDISPLAY_CLI_RESOLVED="$(command -v betterdisplaycli)"
    fi

    if [ -n "${BETTERDISPLAY_APP:-}" ] && [ -d "$BETTERDISPLAY_APP" ]; then
        BETTERDISPLAY_APP_RESOLVED="$BETTERDISPLAY_APP"
    elif [ -n "$BETTERDISPLAY_CLI_RESOLVED" ] &&
         [[ "$BETTERDISPLAY_CLI_RESOLVED" == */BetterDisplay.app/Contents/MacOS/BetterDisplay ]]; then
        BETTERDISPLAY_APP_RESOLVED="${BETTERDISPLAY_CLI_RESOLVED%/Contents/MacOS/BetterDisplay}"
    else
        for app in /Applications/BetterDisplay.app "$HOME/Applications/BetterDisplay.app"; do
            if [ -d "$app" ]; then
                BETTERDISPLAY_APP_RESOLVED="$app"
                break
            fi
        done
    fi

    # SidecarSwitch accepts the App's built-in CLI, so discover it after the
    # App path too. A standalone betterdisplaycli is optional.
    if [ -z "$BETTERDISPLAY_CLI_RESOLVED" ] && [ -n "$BETTERDISPLAY_APP_RESOLVED" ]; then
        candidate="$BETTERDISPLAY_APP_RESOLVED/Contents/MacOS/BetterDisplay"
        if [ -x "$candidate" ]; then
            BETTERDISPLAY_CLI_RESOLVED="$candidate"
        fi
    fi
    [ -n "$BETTERDISPLAY_CLI_RESOLVED" ]
}
virtual_backend_valid() {
    case "${VIRTUAL_DISPLAY_BACKEND:-auto}" in auto|builtin|betterdisplay) return 0;; esac
    log "invalid VIRTUAL_DISPLAY_BACKEND=${VIRTUAL_DISPLAY_BACKEND}"; return 64
}
resolve_builtin_virtual_helper() {
    [ -x "${VIRTUAL_DISPLAY_HELPER:-}" ]
}
use_builtin_virtual() {
    case "$VIRTUAL_DISPLAY_BACKEND" in
        builtin) resolve_builtin_virtual_helper;;
        auto) resolve_builtin_virtual_helper;;
        *) return 1;;
    esac
}
select_virtual_backend() {
    virtual_backend_valid || return $?
    case "$VIRTUAL_DISPLAY_BACKEND" in
        builtin)
            resolve_builtin_virtual_helper || {
                log "built-in virtual-display helper not found: $VIRTUAL_DISPLAY_HELPER"
                return 127
            }
            printf '%s\n' builtin
            ;;
        betterdisplay)
            printf '%s\n' betterdisplay
            ;;
        auto)
            if resolve_builtin_virtual_helper; then
                printf '%s\n' builtin
            else
                printf '%s\n' betterdisplay
            fi
            ;;
    esac
}
run_builtin_virtual() {
    run_with_timeout "$BETTERDISPLAY_TIMEOUT_SECONDS" "$VIRTUAL_DISPLAY_HELPER" "$@"
}
builtin_virtual_status() {
    run_builtin_virtual status 2>&1
}
builtin_virtual_online() {
    local state code
    state="$(builtin_virtual_status)"; code=$?
    [ "$code" -eq 0 ] && printf '%s\n' "$state" | /usr/bin/grep -Eq '(^|[[:space:]])online=1([[:space:]]|$)'
}
builtin_virtual_display_id() {
    local state
    state="$(builtin_virtual_status)" || return 1
    printf '%s\n' "$state" | /usr/bin/sed -n 's/.*display_id=\([0-9][0-9]*\).*/\1/p' | /usr/bin/tail -n 1
}
prepare_builtin_virtual() {
    local output code deadline was_online=0
    if builtin_virtual_online; then was_online=1; fi
    output="$(run_builtin_virtual ensure --background 2>&1)"; code=$?
    if [ "$code" -ne 0 ]; then
        log "built-in virtual display failed to start (exit=$code): $output"
        feedback "$SOUND_FAILURE" "项目内置虚拟屏启动失败"
        notify_detail "$NOTIFY_TITLE" "项目内置虚拟屏启动失败，未连接随航。详情：$output"
        return 20
    fi
    # Capture ownership from the preflight state. If it was already online
    # before this operation, leave it alone on cancellation or failure.
    if [ "$was_online" -eq 0 ]; then
        BUILTIN_FALLBACK_STARTED_BY_OPERATION=1
    fi
    deadline=$((SECONDS + HEADLESS_DISPLAY_WAIT_SECONDS))
    while (( SECONDS <= deadline )); do
        if builtin_virtual_online; then
            log "built-in virtual display is online: $(builtin_virtual_status)"
            # Origin placement is best effort.  macOS has no public main-screen
            # setter; the caller verifies the actual topology before claiming
            # success.  BetterDisplay remains available for authoritative
            # layout/main-screen control.
            output="$(run_builtin_virtual set-main 2>&1)"; code=$?
            if [ "$code" -ne 0 ]; then
                log "built-in virtual display main placement was not confirmed (exit=$code): $output"
                # CoreGraphics does not expose a stable set-main operation;
                # the fallback only needs to be online for Sidecar creation.
                # Continue and verify the actual Sidecar display after connect.
            fi
            return 0
        fi
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    output="$(builtin_virtual_status)"
    log "built-in virtual display did not become online: $output"
    feedback "$SOUND_FAILURE" "项目内置虚拟屏未能上线"
    notify_detail "$NOTIFY_TITLE" "项目内置虚拟屏未能上线，未连接随航。详情：$output"
    return 21
}
builtin_virtual_set_main() {
    local display_id="$1" output code
    [ -n "$display_id" ] || return 1
    output="$(run_builtin_virtual set-main "$display_id" 2>&1)"; code=$?
    [ "$code" -eq 0 ] || log "built-in set-main failed (display=$display_id, exit=$code): $output"
    return "$code"
}
builtin_sidecar_display_id() {
    local output code
    output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"; code=$?
    [ "$code" -eq 0 ] || return 1
    printf '%s\n' "$output" | /usr/bin/awk '
        /^display id=[0-9]+ kind=sidecar / { n++; id=$2; sub(/^id=/,"",id) }
        END { if (n == 1) print id; else exit 1 }'
}
builtin_virtual_set_sidecar_main() {
    local display_id output code
    display_id="$(builtin_sidecar_display_id 2>/dev/null)" || return 1
    [ -n "$display_id" ] || return 1
    output="$(builtin_virtual_set_main "$display_id" 2>&1)"; code=$?
    if [ "$code" -eq 0 ]; then
        log "built-in provider requested Sidecar display $display_id as main: $output"
        return 0
    fi
    log "built-in provider could not verify Sidecar display $display_id as main (exit=$code): $output"
    return "$code"
}
run_betterdisplay() {
    run_with_timeout "$BETTERDISPLAY_TIMEOUT_SECONDS" "$BETTERDISPLAY_CLI_RESOLVED" "$@"
}
betterdisplay_pro_is_available() {
    local output code
    output="$(run_betterdisplay get -proAvailable 2>&1)"
    code=$?
    [ "$code" -eq 0 ] && [ "$(printf '%s' "$output" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')" = "on" ]
}
betterdisplay_normalize_identifiers() {
    # BetterDisplay versions differ: some emit one JSON array, while others
    # emit comma-separated JSON objects. Wrapping the latter in an array avoids
    # byte/character offset bugs when an identifier contains a UTF-8 iPad name.
    /usr/bin/perl -0777 -MJSON::PP -ne '
        my $text = $_;
        $text =~ s/^\s+|\s+$//g;
        $text = "[$text]" if $text =~ /^\{/;
        my $decoded = eval { decode_json($text) };
        if ($@ || ref($decoded) ne "ARRAY") { print STDERR "invalid identifiers JSON sequence\n"; exit 2; }
        print encode_json($decoded), "\n";
    '
}
ensure_betterdisplay_running() {
    local executable
    [ -n "${BETTERDISPLAY_APP_RESOLVED:-}" ] || return 0
    # The app may be running from an App Translocation path after the user
    # opened it from a downloaded copy. Reusing that process avoids launching
    # a second BetterDisplay instance for every headless shortcut press.
    if betterdisplay_app_is_running; then
        return 0
    fi
    executable="$BETTERDISPLAY_APP_RESOLVED/Contents/MacOS/BetterDisplay"
    [ -x "$executable" ] || return 1
    run_with_timeout 12 /usr/bin/open -g -a "$BETTERDISPLAY_APP_RESOLVED" >/dev/null 2>&1 || return 1
    sleep 2
    return 0
}
betterdisplay_app_is_running() {
    # App Translocation changes the executable path, so the installed bundle
    # path will not match a process launched from the translocated copy.
    /usr/bin/pgrep -x BetterDisplay >/dev/null 2>&1
}
betterdisplay_virtual_state() {
    # BetterDisplay returns JSON identifiers; JSON::PP ships with macOS Perl.
    # Match the exact display name and require a unique result, as SidecarSwitch
    # does, then use displayID > 0 to tell connected from merely configured.
    VIRTUAL_TARGET_NAME="$VIRTUAL_DISPLAY_NAME" /usr/bin/perl -0777 -MJSON::PP -ne '
        my $target = $ENV{"VIRTUAL_TARGET_NAME"} // "";
        my $decoded = eval { decode_json($_) };
        if ($@) { print STDERR "invalid BetterDisplay identifiers JSON\n"; exit 2; }
        my @items = ref($decoded) eq "ARRAY" ? @$decoded : (ref($decoded) eq "HASH" ? ($decoded) : ());
        my @matches = grep {
            ref($_) eq "HASH" && lc($_->{name} // "") eq lc($target) &&
            (($_->{deviceType} // "") eq "VirtualScreen" || (($_->{vendor} // "") eq "2198"))
        } @items;
        if (@matches > 1) { print STDERR "virtual display name is ambiguous\n"; exit 2; }
        if (!@matches) { print "exists=0 connected=0\n"; exit 0; }
        my $id = $matches[0]->{displayID};
        my $connected = defined($id) && "$id" =~ /^\d+$/ && $id > 0 ? 1 : 0;
        print "exists=1 connected=$connected\n";
    '
}
virtual_display_online_in_coregraphics() {
    local output code expected_name
    output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
    code=$?
    [ "$code" -eq 0 ] || return 1
    expected_name="$(printf '%s' "$VIRTUAL_DISPLAY_NAME" | /usr/bin/sed 's/ /_/g')"
    printf '%s\n' "$output" | /usr/bin/awk -v name="$expected_name" '
        /^display id=[0-9]+ kind=virtual / {
            rowname=""
            for (i=1;i<=NF;i++) if ($i ~ /^name=/) { rowname=$i; sub(/^name=/,"",rowname); break }
            if (rowname == name) { found++ }
        }
        END { exit(found == 1 ? 0 : 1) }'
}
wait_for_virtual_display_online() {
    local deadline
    deadline=$((SECONDS + HEADLESS_DISPLAY_WAIT_SECONDS))
    while (( SECONDS <= deadline )); do
        if virtual_display_online_in_coregraphics; then
            log "CoreGraphics confirms virtual fallback '$VIRTUAL_DISPLAY_NAME' is online"
            return 0
        fi
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "CoreGraphics did not report exactly one online virtual fallback named '$VIRTUAL_DISPLAY_NAME'"
    return 1
}
create_virtual_fallback() {
    local output code
    if [ "${AUTO_CREATE_VIRTUAL_DISPLAY:-1}" != "1" ]; then
        log "automatic virtual-display creation disabled by configuration"
        return 14
    fi

    # BetterDisplay's documented create syntax is intentionally used here
    # instead of relying on a GUI click.  The screen is independent: no iPad
    # association or mirroring target is supplied, so it can be brought online
    # before Sidecar creates its own display.
    output="$(run_betterdisplay create \
        "-type=VirtualScreen" \
        "-virtualScreenName=$VIRTUAL_DISPLAY_NAME" \
        -aspectWidth=16 -aspectHeight=9 2>&1)"
    code=$?
    if [ "$code" -eq 0 ]; then
        log "created missing BetterDisplay virtual fallback '$VIRTUAL_DISPLAY_NAME': $output"
        return 0
    fi

    # Older BetterDisplay builds used lower-case aliases.  Try that spelling
    # only after the documented form fails; the state check below still
    # decides whether a screen was actually created.
    log "documented virtual-display create failed (exit=$code): $output"
    output="$(run_betterdisplay create \
        "-devicetype=virtualscreen" \
        "-virtualscreenname=$VIRTUAL_DISPLAY_NAME" \
        -aspectWidth=16 -aspectHeight=9 2>&1)"
    code=$?
    if [ "$code" -eq 0 ]; then
        log "created missing BetterDisplay virtual fallback with compatibility syntax '$VIRTUAL_DISPLAY_NAME': $output"
        return 0
    fi
    log "virtual-display create failed (exit=$code): $output"
    return "$code"
}
ensure_virtual_main() {
    local output code expected_name
    expected_name="$(printf '%s' "$VIRTUAL_DISPLAY_NAME" | /usr/bin/sed 's/ /_/g')"
    output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -main=on 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not set the headless fallback as main: $output"
        return 1
    fi
    local deadline
    deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
    while (( SECONDS <= deadline )); do
        output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
        if printf '%s\n' "$output" | /usr/bin/awk -v name="$expected_name" '
            /^display id=[0-9]+ kind=virtual / {
                rowname=""; main=""
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^name=/) { rowname=$i; sub(/^name=/,"",rowname) }
                    if ($i ~ /^main=/) { main=$i; sub(/^main=/,"",main) }
                }
                if (rowname == name && main == "1") { found++ }
            }
            END { exit(found == 1 ? 0 : 1) }'; then
            log "CoreGraphics confirms virtual fallback '$VIRTUAL_DISPLAY_NAME' is main"
            return 0
        fi
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "CoreGraphics did not confirm virtual fallback '$VIRTUAL_DISPLAY_NAME' as main"
    return 1
}
probe_display_counts() {
    local output code physical sidecar virtual
    output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        printf 'probe_error=%s output=%s\n' "$code" "$output"
        return 2
    fi
    physical="$(printf '%s\n' "$output" | /usr/bin/awk -F= '$1 == "physical" { print $2; found=1; exit } END { if (!found) exit 1 }')"
    sidecar="$(printf '%s\n' "$output" | /usr/bin/awk -F= '$1 == "sidecar" { print $2; found=1; exit } END { if (!found) exit 1 }')"
    virtual="$(printf '%s\n' "$output" | /usr/bin/awk -F= '$1 == "virtual" { print $2; found=1; exit } END { if (!found) exit 1 }')"
    if ! [[ "$physical" =~ ^[0-9]+$ ]] || ! [[ "$sidecar" =~ ^[0-9]+$ ]] || ! [[ "$virtual" =~ ^[0-9]+$ ]]; then
        printf 'probe_output=%s\n' "$output"
        return 2
    fi
    printf 'physical=%s sidecar=%s virtual=%s\n' "$physical" "$sidecar" "$virtual"
}
wait_for_stable_display_topology() {
    local minimum="${1:-${DISPLAY_SETTLE_MIN_SECONDS:-5}}"
    local start=$SECONDS deadline sample previous="" stable=0 physical
    local samples="${DISPLAY_SETTLE_SAMPLES:-2}"
    local interval="${DISPLAY_SETTLE_INTERVAL:-1}"
    local window="${DISPLAY_SETTLE_SECONDS:-8}"

    if ! [[ "$samples" =~ ^[0-9]+$ ]] || [ "$samples" -lt 2 ]; then
        samples=2
    fi
    if ! [[ "$window" =~ ^[0-9]+$ ]] || [ "$window" -lt 1 ]; then
        window=8
    fi
    if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$interval" = "0" ]; then
        interval=1
    fi
    if ! [[ "$minimum" =~ ^[0-9]+$ ]]; then
        minimum=5
    fi
    if [ "$minimum" -gt "$window" ]; then
        minimum="$window"
    fi
    deadline=$((SECONDS + window))
    while (( SECONDS <= deadline )); do
        sample="$(probe_display_counts 2>&1)"
        if [ "$?" -ne 0 ]; then
            printf '%s\n' "$sample"
            return 1
        fi
        if [ "$sample" = "$previous" ]; then
            stable=$((stable + 1))
        else
            previous="$sample"
            stable=1
        fi
        physical="${sample#physical=}"
        physical="${physical%% *}"
        # When a physical monitor is still reported, wait through the
        # display-removal debounce before accepting that snapshot.  WindowServer
        # can keep the old display online for several seconds after unplugging
        # the cable; accepting two early samples recreates the stale-headless
        # race this guard is meant to prevent.
        if (( stable >= samples )) &&
           { [ "$physical" = "0" ] || (( SECONDS - start >= minimum )); }; then
            log "display topology settled after ${stable} samples: $sample"
            printf '%s\n' "$sample"
            return 0
        fi
        sleep "$interval"
    done
    log "display topology did not settle within ${window}s (last=$previous)"
    printf 'topology_unsettled=%s\n' "$previous"
    return 1
}
recheck_display_topology() {
    # Most preflight work (USB/radio checks and a read-only Sidecar snapshot)
    # cannot alter WindowServer's display list. If a cheap single sample still
    # equals the already-settled topology, reuse it and avoid another full
    # debounce window. When it changed, fall back to the stable two-sample
    # gate before any operation that can create or move a display.
    local expected="${1:-}" sample code
    sample="$(probe_display_counts 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        printf '%s\n' "$sample"
        return "$code"
    fi
    if [ -n "$expected" ] && [ "$sample" = "$expected" ]; then
        log "display topology unchanged since settled probe: $sample"
        printf '%s\n' "$sample"
        return 0
    fi
    log "display topology changed since settled probe: ${expected:-none} -> $sample"
    wait_for_stable_display_topology 0
}
prepare_headless_fallback() {
    local identifiers identifier_code output code virtual_state virtual_code deadline
    local selected_backend
    selected_backend="$(select_virtual_backend 2>/dev/null)"
    if [ "$selected_backend" = "builtin" ]; then
        if prepare_builtin_virtual; then
            ACTIVE_VIRTUAL_DISPLAY_BACKEND=builtin
            return 0
        fi
        if [ "$VIRTUAL_DISPLAY_BACKEND" != "auto" ]; then
            return 20
        fi
        log "built-in virtual display failed; auto backend is trying BetterDisplay"
        run_builtin_virtual destroy >/dev/null 2>&1 || true
        selected_backend=betterdisplay
    elif [ "$VIRTUAL_DISPLAY_BACKEND" = "builtin" ]; then
        feedback "$SOUND_FAILURE" "项目内置虚拟屏工具未安装"
        notify "$NOTIFY_TITLE" "项目内置虚拟屏工具未安装，请先点击安装或修复"
        return 127
    elif [ "$selected_backend" != "betterdisplay" ]; then
        feedback "$SOUND_FAILURE" "虚拟屏后端配置无效"
        notify "$NOTIFY_TITLE" "VIRTUAL_DISPLAY_BACKEND 配置无效"
        return 64
    fi
    ACTIVE_VIRTUAL_DISPLAY_BACKEND=betterdisplay
    if ! resolve_betterdisplay_cli; then
        log "headless preparation refused: BetterDisplay CLI/App not found"
        feedback "$SOUND_FAILURE" "没有显示器，找不到 BetterDisplay，未连接随航"
        notify "$NOTIFY_TITLE" "当前选择 BetterDisplay，但没有找到可用的 BetterDisplay 虚拟屏后端"
        return 10
    fi
    log "headless mode: BetterDisplay CLI=$BETTERDISPLAY_CLI_RESOLVED app=${BETTERDISPLAY_APP_RESOLVED:-none}"
    if ! ensure_betterdisplay_running; then
        log "headless preparation refused: could not start BetterDisplay"
        feedback "$SOUND_FAILURE" "BetterDisplay 无法启动，未连接随航"
        notify "$NOTIFY_TITLE" "BetterDisplay 无法启动，未连接"
        return 11
    fi
    identifiers="$(run_betterdisplay get -identifiers 2>&1)"
    identifier_code=$?
    if [ "$identifier_code" -ne 0 ]; then
        log "headless preparation refused: BetterDisplay identifiers failed (exit=$identifier_code): $identifiers"
        feedback "$SOUND_FAILURE" "无法读取 BetterDisplay 显示器列表，未连接随航"
        notify_detail "$NOTIFY_TITLE" "无法读取 BetterDisplay 显示器列表，未连接。详情：$identifiers"
        return 12
    fi
    identifiers="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers 2>&1)"
    identifier_code=$?
    if [ "$identifier_code" -ne 0 ]; then
        log "headless preparation refused: invalid BetterDisplay identifiers: $identifiers"
        feedback "$SOUND_FAILURE" "BetterDisplay 显示器列表格式无法识别，未连接随航"
        notify_detail "$NOTIFY_TITLE" "BetterDisplay 显示器列表格式无法识别，未连接。详情：$identifiers"
        return 13
    fi
    virtual_state="$(printf '%s\n' "$identifiers" | betterdisplay_virtual_state 2>&1)"
    virtual_code=$?
    if [ "$virtual_code" -ne 0 ]; then
        log "headless preparation refused: could not parse virtual display state: $virtual_state"
        feedback "$SOUND_FAILURE" "无法确认 BetterDisplay 虚拟屏幕状态，未连接随航"
        notify_detail "$NOTIFY_TITLE" "无法确认 BetterDisplay 虚拟屏幕状态，未连接。详情：$virtual_state"
        return 13
    fi
    if ! printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 connected=1$'; then
        if ! betterdisplay_pro_is_available; then
            output="$(run_betterdisplay get -proAvailable 2>&1)"
            code=$?
            log "headless preparation refused: BetterDisplay Pro is unavailable or could not be queried (exit=$code): $output"
            feedback "$SOUND_FAILURE" "无显示器模式需要 BetterDisplay Pro 或有效试用，未连接随航"
            notify_detail "$NOTIFY_TITLE" "自动创建和启用虚拟备用屏需要 BetterDisplay Pro 或有效试用。详情：$output"
            return 18
        fi
    fi
    if ! printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 '; then
        BETTERDISPLAY_FALLBACK_CHANGED_BY_OPERATION=1
        log "virtual display '$VIRTUAL_DISPLAY_NAME' is missing; creating it automatically"
        create_virtual_fallback
        code=$?
        # A create command may return an error after the app has persisted the
        # screen, so always re-read identifiers before declaring failure.
        deadline=$((SECONDS + HEADLESS_DISPLAY_WAIT_SECONDS))
        while (( SECONDS <= deadline )); do
            identifiers="$(run_betterdisplay get -identifiers 2>&1)"
            identifier_code=$?
            if [ "$identifier_code" -eq 0 ]; then
                identifiers="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers 2>&1)"
                identifier_code=$?
            fi
            virtual_state="$(printf '%s\n' "$identifiers" | betterdisplay_virtual_state 2>&1)"
            virtual_code=$?
            if [ "$identifier_code" -eq 0 ] && [ "$virtual_code" -eq 0 ] &&
               printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 '; then
                break
            fi
            sleep 1
        done
        if [ "$identifier_code" -ne 0 ] || [ "$virtual_code" -ne 0 ] ||
           ! printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 '; then
            log "headless preparation refused: automatic virtual display creation did not produce '$VIRTUAL_DISPLAY_NAME' (create_exit=$code, state=$virtual_state)"
            feedback "$SOUND_FAILURE" "没有找到虚拟备用屏幕，自动创建失败，未连接随航"
            notify_detail "$NOTIFY_TITLE" "无法自动创建 ${VIRTUAL_DISPLAY_NAME}，请检查 BetterDisplay 版本和权限。"
            return 14
        fi
        log "automatic virtual display creation verified: $VIRTUAL_DISPLAY_NAME ($virtual_state)"
    fi
    if ! printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 connected=1$'; then
        BETTERDISPLAY_FALLBACK_CHANGED_BY_OPERATION=1
        output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -connected=on 2>&1)"
        code=$?
        if [ "$code" -ne 0 ]; then
            log "headless preparation failed: could not connect '$VIRTUAL_DISPLAY_NAME' (exit=$code): $output"
            feedback "$SOUND_FAILURE" "无法连接 ${VIRTUAL_DISPLAY_NAME}，未连接随航"
            notify_detail "$NOTIFY_TITLE" "无法连接 BetterDisplay 虚拟屏幕，未连接。详情：$output"
            return 15
        fi
        deadline=$((SECONDS + HEADLESS_DISPLAY_WAIT_SECONDS))
        while (( SECONDS <= deadline )); do
            identifiers="$(run_betterdisplay get -identifiers 2>&1)"
            identifier_code=$?
            if [ "$identifier_code" -eq 0 ]; then
                identifiers="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers 2>&1)"
                identifier_code=$?
            fi
            virtual_state="$(printf '%s\n' "$identifiers" | betterdisplay_virtual_state 2>&1)"
            virtual_code=$?
            if [ "$identifier_code" -eq 0 ] && [ "$virtual_code" -eq 0 ] &&
               printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 connected=1$' &&
               virtual_display_online_in_coregraphics; then
                break
            fi
            sleep 1
        done
        if [ "$identifier_code" -ne 0 ] || [ "$virtual_code" -ne 0 ] ||
        ! printf '%s\n' "$virtual_state" | /usr/bin/grep -q '^exists=1 connected=1$' ||
        ! virtual_display_online_in_coregraphics; then
            log "headless preparation failed: virtual display did not become online: $virtual_state; command=$output"
            feedback "$SOUND_FAILURE" "${VIRTUAL_DISPLAY_NAME} 虚拟屏幕未能上线，未连接随航"
            notify_detail "$NOTIFY_TITLE" "BetterDisplay 未能上线 ${VIRTUAL_DISPLAY_NAME}，未连接随航"
            return 16
        fi
        log "headless fallback connected: $VIRTUAL_DISPLAY_NAME ($output)"
    fi
    if ! wait_for_virtual_display_online; then
        feedback "$SOUND_FAILURE" "BetterDisplay 虚拟屏幕未出现在系统显示列表，未连接随航"
        notify "$NOTIFY_TITLE" "虚拟备用屏未上线，未连接随航"
        return 16
    fi
    if ! ensure_virtual_main; then
        feedback "$SOUND_FAILURE" "无法将虚拟备用屏设为主屏，未连接随航"
        notify "$NOTIFY_TITLE" "无法确认虚拟备用屏为主屏，未连接随航"
        return 17
    fi
    return 0
}
sidecar_display_info() {
    local identifiers code output
    identifiers="$(run_betterdisplay get -identifiers 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not read BetterDisplay identifiers while locating Sidecar display: $identifiers"
        return 1
    fi
    output="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers | IPAD_TARGET_NAME="$IPAD_NAME" /usr/bin/perl -0777 -MJSON::PP -MEncode=decode,FB_CROAK -ne '
        my $ipad;
        eval { $ipad = lc(decode("UTF-8", ($ENV{"IPAD_TARGET_NAME"} // ""), FB_CROAK)); };
        if ($@) { print STDERR "invalid UTF-8 iPad target name\n"; exit 2; }
        my $decoded = eval { decode_json($_) };
        if ($@) { print STDERR "invalid BetterDisplay identifiers JSON\n"; exit 2; }
        my @items = ref($decoded) eq "ARRAY" ? @$decoded : (ref($decoded) eq "HASH" ? ($decoded) : ());
        my @matches = grep {
            ref($_) eq "HASH" &&
            (lc($_->{name} // "") eq $ipad || lc($_->{originalName} // "") eq $ipad) &&
            ((($_->{vendor} // "") eq "1633775724") || (($_->{model} // "") eq "1766875492") ||
             (($_->{deviceType} // "") =~ /sidecar/i)) &&
            defined($_->{displayID}) && "$_->{displayID}" =~ /^\d+$/ && $_->{displayID} > 0
        } @items;
        if (@matches != 1) { print STDERR "expected one online Sidecar display named for target iPad, found " . scalar(@matches) . "\n"; exit 3; }
        my $item = $matches[0];
        my $uuid = $item->{UUID} // $item->{uuid} // "";
        my $specifier = $uuid =~ /^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/
            ? "uuid=$uuid" : "name=" . ($item->{name} // "");
        print "display_id=$item->{displayID} specifier=$specifier\n";
    ' 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not uniquely identify the target Sidecar display: $output"
        return "$code"
    fi
    printf '%s\n' "$output"
}
resolve_sidecar_display_specifier() {
    local info code specifier
    info="$(sidecar_display_info 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not identify the target Sidecar display: $info"
        return "$code"
    fi
    specifier="${info##*specifier=}"
    [ -n "$specifier" ] || return 1
    printf '%s\n' "$specifier"
}
set_headless_sidecar_main() {
    local specifier="$BETTERDISPLAY_SIDECAR_SPECIFIER" selector output code
    if [ -z "$specifier" ]; then
        specifier="$(resolve_sidecar_display_specifier)"
        code=$?
        if [ "$code" -ne 0 ]; then return 1; fi
    fi
    case "$specifier" in
        uuid=*) selector="-$specifier" ;;
        name=*) selector="-$specifier" ;;
        *)
            if [[ "$specifier" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
                selector="-uuid=$specifier"
            else
                selector="-name=$specifier"
            fi
            ;;
    esac
    output="$(run_betterdisplay set "$selector" -main=on 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "headless Sidecar main-display handoff failed (exit=$code, selector=$selector): $output"
        return 1
    fi
    log "headless Sidecar set as main display (selector=$selector): $output"
    return 0
}
verify_sidecar_main() {
    local timeout="$1" deadline output info code display_id probe_code
    deadline=$((SECONDS + timeout))
    while (( SECONDS <= deadline )); do
        info="$(sidecar_display_info 2>&1)"
        code=$?
        display_id="${info#display_id=}"
        display_id="${display_id%% *}"
        output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
        probe_code=$?
        if [ "$code" -eq 0 ] && [ "$probe_code" -eq 0 ] && [[ "$display_id" =~ ^[0-9]+$ ]] &&
           printf '%s\n' "$output" | /usr/bin/awk -v id="$display_id" '
               index($0, "display id=" id " ") == 1 && $0 ~ /kind=sidecar / && $0 ~ /main=1/ { found++ }
               END { exit(found == 1 ? 0 : 1) }'; then
            return 0
        fi
        [ "$timeout" -eq 0 ] && break
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "target iPad main-display verification failed (target=$info): $output"
    return 1
}
physical_main_state() {
    local output code
    output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not inspect physical display main state: $output"
        return 1
    fi
    printf '%s\n' "$output" | /usr/bin/awk '
        $1 == "display" {
            id=""; kind=""; main=""
            for (i=2; i<=NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "id") id=pair[2]
                if (pair[1] == "kind") kind=pair[2]
                if (pair[1] == "main") main=pair[2]
            }
            if (kind == "physical" && main == "1") { print "id=" id " main=1"; found=1; exit }
            if (kind == "physical" && first == "") first=id
        }
        END { if (!found && first != "") print "id=" first " main=0"; else if (!found) exit 1 }
    '
}
resolve_physical_display_specifier() {
    local display_id="$1" identifiers code output
    identifiers="$(run_betterdisplay get -identifiers 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not read BetterDisplay identifiers while locating physical display $display_id: $identifiers"
        return 1
    fi
    output="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers | DISPLAY_TARGET_ID="$display_id" /usr/bin/perl -0777 -MJSON::PP -ne '
        my $target = $ENV{"DISPLAY_TARGET_ID"} // "";
        my $decoded = eval { decode_json($_) };
        if ($@) { print STDERR "invalid BetterDisplay identifiers JSON\n"; exit 2; }
        my @items = ref($decoded) eq "ARRAY" ? @$decoded : (ref($decoded) eq "HASH" ? ($decoded) : ());
        my @matches = grep {
            ref($_) eq "HASH" && defined($_->{displayID}) && "$_->{displayID}" eq $target &&
            (($_->{deviceType} // "") ne "VirtualScreen") && (($_->{vendor} // "") ne "2198") &&
            (($_->{vendor} // "") ne "1633775724") && (($_->{model} // "") ne "1766875492") &&
            (($_->{deviceType} // "") !~ /sidecar/i)
        } @items;
        if (@matches != 1) { print STDERR "expected one physical display record, found " . scalar(@matches) . "\n"; exit 3; }
        my $item = $matches[0];
        my $uuid = $item->{UUID} // $item->{uuid} // "";
        if ($uuid =~ /^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/) {
            print "uuid=$uuid\n";
        } elsif (defined($item->{name}) && length($item->{name})) {
            print "name=$item->{name}\n";
        } else { exit 4; }
    ' 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not uniquely identify physical display $display_id: $output"
        return "$code"
    fi
    printf '%s\n' "$output"
}
verify_physical_main() {
    local display_id="$1" timeout="$2" deadline output
    deadline=$((SECONDS + timeout))
    while (( SECONDS <= deadline )); do
        output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
        if printf '%s\n' "$output" | /usr/bin/grep -Eq "display id=${display_id} kind=physical .*main=1"; then
            return 0
        fi
        [ "$timeout" -eq 0 ] && break
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "physical main-display verification failed (id=$display_id): $output"
    return 1
}
retire_headless_fallback() {
    local identifiers code state state_code output
    if ! resolve_betterdisplay_cli; then
        log "BetterDisplay not available; physical main is preserved but fallback cleanup was skipped"
        return 0
    fi
    if ! betterdisplay_app_is_running; then
        log "BetterDisplay is not already running; physical main is preserved and virtual fallback cleanup is skipped"
        return 0
    fi
    identifiers="$(run_betterdisplay get -identifiers 2>&1)"
    code=$?
    [ "$code" -eq 0 ] || {
        log "could not inspect BetterDisplay fallback state; cleanup skipped: $identifiers"
        return 0
    }
    identifiers="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers 2>&1)"
    code=$?
    [ "$code" -eq 0 ] || {
        log "could not parse BetterDisplay fallback state; cleanup skipped: $identifiers"
        return 0
    }
    state="$(printf '%s\n' "$identifiers" | betterdisplay_virtual_state 2>&1)"
    state_code=$?
    if [ "$state_code" -ne 0 ] || ! printf '%s\n' "$state" | /usr/bin/grep -q '^exists=1 connected=1$'; then
        log "no connected $VIRTUAL_DISPLAY_NAME fallback to retire (state=$state)"
        return 0
    fi
    output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -connected=off 2>&1)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "could not disconnect headless fallback after physical main was verified: $output"
        return 1
    fi
    identifiers="$(run_betterdisplay get -identifiers 2>&1)"
    code=$?
    if [ "$code" -eq 0 ]; then
        identifiers="$(printf '%s\n' "$identifiers" | betterdisplay_normalize_identifiers 2>&1)"
        code=$?
    fi
    state="$(printf '%s\n' "$identifiers" | betterdisplay_virtual_state 2>&1)"
    state_code=$?
    if [ "$code" -ne 0 ] || [ "$state_code" -ne 0 ] ||
       printf '%s\n' "$state" | /usr/bin/grep -q '^exists=1 connected=1$'; then
        log "headless fallback disconnect could not be verified: $state"
        return 1
    fi
    log "disconnected headless fallback after physical display became main"
    return 0
}
ensure_physical_main() {
    local state display_id main selector specifier code output
    state="$(physical_main_state)"
    code=$?
    if [ "$code" -ne 0 ]; then
        log "cannot confirm a physical display to use as main: $state"
        feedback "$SOUND_FAILURE" "随航已连接，但无法确认实体显示器主屏"
        return 1
    fi
    display_id="${state#id=}"
    display_id="${display_id%% *}"
    main="${state##*main=}"
    if [ "$main" != "1" ]; then
        if ! resolve_betterdisplay_cli || ! ensure_betterdisplay_running; then
            log "physical display $display_id is not main and BetterDisplay is unavailable"
            feedback "$SOUND_FAILURE" "随航已连接，但实体屏不是主屏，BetterDisplay 不可用"
            return 1
        fi
        specifier="$(resolve_physical_display_specifier "$display_id")"
        code=$?
        if [ "$code" -ne 0 ]; then
            log "could not resolve the external main display target: $specifier"
            feedback "$SOUND_FAILURE" "随航已连接，但无法识别实体屏，未切换主屏"
            return 1
        fi
        case "$specifier" in
            uuid=*) selector="-$specifier" ;;
            name=*) selector="-$specifier" ;;
            *) log "invalid physical display specifier: $specifier"; return 1 ;;
        esac
        output="$(run_betterdisplay set "$selector" -main=on 2>&1)"
        code=$?
        if [ "$code" -ne 0 ] || ! verify_physical_main "$display_id" 6; then
            log "failed to set/verify physical display $display_id as main (exit=$code): $output"
            feedback "$SOUND_FAILURE" "随航已连接，但实体屏无法设为主屏"
            return 1
        fi
    else
        log "physical display $display_id is already main"
    fi
    if ! retire_headless_fallback; then
        feedback "$SOUND_FAILURE" "实体屏已设为主屏，但无法断开备用虚拟屏"
        return 1
    fi
    return 0
}
probe_sidecar_display() {
    local probe_output probe_code count
    probe_output="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1)"
    probe_code=$?
    if [ "$probe_code" -ne 0 ]; then
        printf 'probe_error=%s output=%s\n' "$probe_code" "$probe_output"
        return 2
    fi
    count="$(printf '%s\n' "$probe_output" | /usr/bin/awk -F= '$1 == "sidecar" { print $2; found=1; exit } END { if (!found) exit 1 }')"
    if [ "$?" -ne 0 ] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
        printf 'probe_output=%s\n' "$probe_output"
        return 2
    fi
    printf '%s\n' "$count"
}
verify_connected_display() {
    local timeout="$1" deadline status_output status_code info info_code display_id display_output display_code
    local display_count display_count_code
    if [ "$headless" -eq 1 ] && [ "${ACTIVE_VIRTUAL_DISPLAY_BACKEND:-}" = "builtin" ]; then
        # The built-in provider has no BetterDisplay IPC.  Confirm the two
        # independent postconditions that remain observable through supported
        # interfaces: SidecarCore says the target is connected and WindowServer
        # reports exactly one Sidecar display.  Main-screen arrangement is a
        # separate best-effort operation and is intentionally not reported as
        # a successful connection requirement here.
        deadline=$((SECONDS + timeout))
        while (( SECONDS <= deadline )); do
            status_output="$(run_sidecar_status "$IPAD_NAME" 2>&1)"
            status_code=$?
            display_count="$(probe_sidecar_display 2>&1)"
            display_count_code=$?
            if [ "$status_code" -eq 0 ] && [ "$display_count_code" -eq 0 ] &&
               [ "$display_count" -gt 0 ] 2>/dev/null; then
                return 0
            fi
            [ "$timeout" -eq 0 ] && break
            sleep "$DISPLAY_VERIFY_INTERVAL"
        done
        log "built-in Sidecar display verification failed: status=$status_code output=$status_output sidecar=$display_count"
        return 1
    fi
    if [ "$headless" -eq 1 ] && (! resolve_betterdisplay_cli || ! ensure_betterdisplay_running); then
        log "cannot start or query BetterDisplay to identify the target iPad display"
        return 1
    fi
    deadline=$((SECONDS + timeout))
    while (( SECONDS <= deadline )); do
        verify_dir="$(mktemp -d "$LOCK_DIR/verify.XXXXXX" 2>/dev/null)" || return 1
        ( run_sidecar_status "$IPAD_NAME" 2>&1; printf '%s\n' "$?" > "$verify_dir/status.code" ) > "$verify_dir/status.out" 2>&1 &
        verify_status_pid=$!
        if [ "$headless" -eq 1 ]; then
            ( sidecar_display_info 2>&1; printf '%s\n' "$?" > "$verify_dir/info.code" ) > "$verify_dir/info.out" 2>&1 &
            verify_info_pid=$!
            ( run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1; printf '%s\n' "$?" > "$verify_dir/display.code" ) > "$verify_dir/display.out" 2>&1 &
            verify_display_pid=$!
            wait "$verify_status_pid" || true
            wait "$verify_info_pid" || true
            wait "$verify_display_pid" || true
            status_output="$(cat "$verify_dir/status.out" 2>/dev/null)"
            status_code="$(cat "$verify_dir/status.code" 2>/dev/null || echo 125)"
            info="$(cat "$verify_dir/info.out" 2>/dev/null)"
            info_code="$(cat "$verify_dir/info.code" 2>/dev/null || echo 125)"
            display_id="${info#display_id=}"
            display_id="${display_id%% *}"
            display_output="$(cat "$verify_dir/display.out" 2>/dev/null)"
            display_code="$(cat "$verify_dir/display.code" 2>/dev/null || echo 125)"
            if [ "$status_code" -eq 0 ] && [ "$info_code" -eq 0 ] &&
               [[ "$display_id" =~ ^[0-9]+$ ]] && [ "$display_code" -eq 0 ] &&
               printf '%s\n' "$display_output" | /usr/bin/awk -v id="$display_id" '
                   index($0, "display id=" id " ") == 1 && $0 ~ /kind=sidecar / { found++ }
                   END { exit(found == 1 ? 0 : 1) }'; then
                return 0
            fi
        else
            ( probe_sidecar_display 2>&1; printf '%s\n' "$?" > "$verify_dir/display.code" ) > "$verify_dir/display.out" 2>&1 &
            verify_display_pid=$!
            wait "$verify_status_pid" || true
            wait "$verify_display_pid" || true
            status_output="$(cat "$verify_dir/status.out" 2>/dev/null)"
            status_code="$(cat "$verify_dir/status.code" 2>/dev/null || echo 125)"
            display_count="$(cat "$verify_dir/display.out" 2>/dev/null)"
            display_count_code="$(cat "$verify_dir/display.code" 2>/dev/null || echo 125)"
            if [ "$status_code" -eq 0 ] && [ "$display_count_code" -eq 0 ] &&
               [ "$display_count" -gt 0 ] 2>/dev/null; then
                return 0
            fi
        fi
        rm -rf "$verify_dir" 2>/dev/null || true
        [ "$timeout" -eq 0 ] && break
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "Sidecar display verification failed: status=$status_code status_output=$status_output target=${info:-not-required} display_probe=${display_output:-$display_count}"
    return 1
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner=""
    [ -r "$LOCK_DIR/pid" ] && owner="$(<"$LOCK_DIR/pid")"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || {
            log "explicit connect skipped: could not reclaim stale action lock"
            feedback "$SOUND_FAILURE" "连接操作锁异常，请稍后再试"
            notify "$NOTIFY_TITLE" "连接操作锁异常"
            exit 75
        }
    else
        log "explicit connect skipped: another Sidecar action is running (owner=${owner:-unknown})"
        feedback "$SOUND_FAILURE" "已有一个随航操作正在执行，请等待提示结束后再试"
        notify "$NOTIFY_TITLE" "已有一个 Sidecar 操作正在执行"
        exit 75
    fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'cleanup_on_exit' EXIT
trap 'handle_interrupt' INT TERM HUP
if [ "$CONNECTION_MODE" = "auto" ]; then
    feedback_progress "$SOUND_START" "正在检查 iPad 数据线，准备连接随航"
else
    feedback_progress "$SOUND_START" "正在连接${TRANSPORT_LABEL}随航"
fi

if [ ! -x "$SIDECAR_BIN" ]; then
    log "explicit connect failed: sidecarctl not found at $SIDECAR_BIN"
    feedback "$SOUND_FAILURE" "找不到 sidecarctl"
    notify "$NOTIFY_TITLE" "找不到 sidecarctl"
    exit 127
fi
if [ ! -x "$DISPLAY_STATE_BIN" ]; then
    log "explicit connect failed: display probe not found at $DISPLAY_STATE_BIN"
    feedback "$SOUND_FAILURE" "找不到显示状态检测程序，无法确认 iPad 画面"
    notify "$NOTIFY_TITLE" "缺少显示状态检测程序，未连接"
    exit 127
fi
# Display topology settling and the Sidecar device snapshot are independent
# read-only probes. Run them together so the deliberate display debounce does
# not add to the SidecarCore query time.
preflight_started_ms="$(monotonic_milliseconds)"
initial_display_file="$LOCK_DIR/initial-display-topology"
wait_for_stable_display_topology > "$initial_display_file" 2>&1 &
initial_display_pid=$!

# USB enumeration is also read-only. Start it with the display and Sidecar
# snapshot when automatic transport selection is requested; the result is
# consumed only after the snapshot proves that no session is already active.
initial_usb_pid=""
if [ "$CONNECTION_MODE" = "auto" ] && [ -x "$SIDECAR_USB_DETECT_BIN" ]; then
    INITIAL_USB_FILE="$LOCK_DIR/initial-usb"
    ( run_with_timeout 5 "$SIDECAR_USB_DETECT_BIN" 2>&1; rc=$?; printf '%s\n' "$rc" > "$INITIAL_USB_FILE.code"; exit "$rc" ) > "$INITIAL_USB_FILE.output" 2>&1 &
    initial_usb_pid=$!
fi

# One snapshot replaces the old sequential `status` + `list` calls. It is
# read-only and contains the same cross-check inputs, so an unknown or
# inconsistent state still stops before any transport or connection request.
snapshot_output="$(run_sidecar_snapshot "$IPAD_NAME" 2>&1)"
snapshot_code=$?
wait "$initial_display_pid"
display_probe_code=$?
if [ -n "$initial_usb_pid" ]; then
    wait "$initial_usb_pid" || true
fi
preflight_finished_ms="$(monotonic_milliseconds)"
if [[ "$preflight_started_ms" =~ ^[0-9]+$ ]] && [[ "$preflight_finished_ms" =~ ^[0-9]+$ ]]; then
    log "parallel read-only preflight completed in $((preflight_finished_ms - preflight_started_ms))ms"
fi
display_counts="$(cat "$initial_display_file" 2>/dev/null)"
if [ "$display_probe_code" -ne 0 ]; then
    log "explicit connect refused: display topology could not settle: $display_counts"
    feedback "$SOUND_FAILURE" "无法确认当前有没有显示器，未连接随航"
    notify "$NOTIFY_TITLE" "无法确认显示器状态，未连接"
    exit 3
fi
physical_count="${display_counts#physical=}"
physical_count="${physical_count%% *}"
if [ "$snapshot_code" -ne 0 ]; then
    log "explicit connect refused: could not read Sidecar snapshot (exit=$snapshot_code): $snapshot_output"
    feedback "$SOUND_FAILURE" "无法确认随航状态，未连接"
    notify_detail "$NOTIFY_TITLE" "无法读取随航设备状态，未连接。详情：$snapshot_output"
    exit 2
fi
snapshot_summary="$(printf '%s\n' "$snapshot_output" | /usr/bin/perl -MJSON::PP -0777 -ne '
    my $doc = eval { decode_json($_) };
    if ($@ || ref($doc) ne "HASH") { print STDERR "invalid sidecar snapshot JSON\n"; exit 2; }
    my $target = ref($doc->{target}) eq "HASH" ? $doc->{target} : undef;
    my $counts = ref($doc->{counts}) eq "HASH" ? $doc->{counts} : undef;
    if (!$target || !$counts) { print STDERR "sidecar snapshot missing target/counts\n"; exit 2; }
    my $state = $target->{state} // "";
    my %valid = map { $_ => 1 } qw(connected disconnected unknown not_found);
    if (!$valid{$state}) { print STDERR "invalid sidecar target state\n"; exit 2; }
    my @values = map { $counts->{$_} } qw(devices connected disconnected unknown);
    for my $value (@values) {
        if (!defined($value) || "$value" !~ /^\d+$/) { print STDERR "invalid sidecar snapshot count\n"; exit 2; }
    }
    my ($devices, $connected, $disconnected, $unknown) = @values;
    if ($connected + $disconnected + $unknown != $devices) {
        print STDERR "inconsistent sidecar snapshot counts\n"; exit 2;
    }
    my $matches = $target->{matches};
    $matches = 0 unless defined($matches) && "$matches" =~ /^\d+$/;
    print "$state $matches $devices $connected $disconnected $unknown\n";
')"
snapshot_parse_code=$?
if [ "$snapshot_parse_code" -ne 0 ]; then
    log "explicit connect refused: malformed Sidecar snapshot: $snapshot_summary; raw=$snapshot_output"
    feedback "$SOUND_FAILURE" "无法解析随航状态，未连接"
    notify_detail "$NOTIFY_TITLE" "随航状态结果无法解析，未连接。详情：$snapshot_summary"
    exit 2
fi
read -r target_state target_matches device_rows connected_rows disconnected_rows unknown_rows <<< "$snapshot_summary"
case "$target_state" in
    connected) status_code=0; PRESERVE_FALLBACK_ON_EXIT=1 ;;
    disconnected|not_found) status_code=1 ;;
    unknown)
        log "explicit connect refused: target Sidecar state is unknown: $snapshot_output"
        feedback "$SOUND_FAILURE" "无法确认随航状态，为避免抢占，未连接"
        notify_detail "$NOTIFY_TITLE" "无法确认目标 iPad 的随航状态，未连接。详情：$snapshot_output"
        exit 2
        ;;
    *)
        log "explicit connect refused: unexpected Sidecar snapshot target state: $snapshot_summary"
        feedback "$SOUND_FAILURE" "无法确认随航状态，未连接"
        notify "$NOTIFY_TITLE" "状态无法确认，未连接"
        exit 2
        ;;
esac
if [ "$status_code" -eq 1 ] && [ "${target_matches:-0}" -gt 1 ] 2>/dev/null; then
    log "explicit connect refused: target name '$IPAD_NAME' matches multiple Sidecar devices: $snapshot_output"
    feedback "$SOUND_FAILURE" "检测到多个同名 iPad，请配置准确名称后再连接"
    notify_detail "$NOTIFY_TITLE" "目标名称匹配多个随航设备，为避免误连已停止。请在配置中填写准确的 IPAD_NAME。"
    exit 3
fi
if [ "$unknown_rows" -ne 0 ] || { [ "$device_rows" -eq 0 ] && [ "$status_code" -eq 0 ]; }; then
    log "explicit connect refused: Sidecar snapshot is unknown or inconsistent: $snapshot_output"
    feedback "$SOUND_FAILURE" "无法确认 Mac 上所有随航设备状态，为避免抢占，未连接"
    notify_detail "$NOTIFY_TITLE" "无法确认 Mac 上所有随航会话状态，未连接。详情：$snapshot_output"
    exit 2
fi
if [ "$connected_rows" -gt 0 ] && [ "$status_code" -ne 0 ]; then
    log "explicit connect refused: another Sidecar device is connected; target '$IPAD_NAME' is not the active session: $snapshot_output"
    feedback "$SOUND_FAILURE" "检测到已有其他随航会话，为避免抢占 iPad，未连接"
    notify_detail "$NOTIFY_TITLE" "检测到已有其他随航会话，未抢占当前 iPad。目标 $IPAD_NAME 未连接。"
    exit 4
fi
if [ "$connected_rows" -eq 0 ] && [ "$status_code" -eq 0 ]; then
    log "explicit connect refused: named snapshot says connected but full device counts say disconnected: $snapshot_output"
    feedback "$SOUND_FAILURE" "随航状态不一致，为避免误操作，未连接"
    notify_detail "$NOTIFY_TITLE" "随航状态查询结果不一致，未连接。详情：$snapshot_output"
    exit 2
fi
# Do not inspect or change transport when an existing Sidecar session is
# already present. This preserves an iPad that is being used elsewhere and
# makes repeated presses a safe no-op after display verification below.
if [ "$status_code" -eq 1 ] && [ "$CONNECTION_MODE" = "auto" ]; then
    resolve_auto_transport
    auto_transport_code=$?
    if [ "$auto_transport_code" -ne 0 ]; then
        exit "$auto_transport_code"
    fi
fi
if [ "$status_code" -eq 1 ] && [ "$CONNECTION_MODE" = "wireless" ]; then
    prepare_wireless_radios
    radio_code=$?
    if [ "$radio_code" -ne 0 ]; then
        exit "$radio_code"
    fi
fi
# A status query can take long enough for WindowServer to finish removing a
# monitor. Re-sample immediately before choosing the fallback path. A matching
# cheap sample reuses the settled result; a changed sample enters the full
# debounce gate so the decision is still based on stable topology.
latest_display_counts="$(recheck_display_topology "$display_counts")"
latest_display_probe_code=$?
if [ "$latest_display_probe_code" -ne 0 ]; then
    log "explicit connect refused: display topology changed or could not settle before connection: $latest_display_counts"
    feedback "$SOUND_FAILURE" "显示器状态仍在变化，未连接随航，请稍后再试"
    notify "$NOTIFY_TITLE" "显示器状态仍在变化，未连接随航"
    exit 3
fi
latest_physical_count="${latest_display_counts#physical=}"
latest_physical_count="${latest_physical_count%% *}"
if [[ "$latest_physical_count" =~ ^[0-9]+$ ]] && [ "$latest_physical_count" != "$physical_count" ]; then
    log "display topology changed while checking Sidecar status: $display_counts -> $latest_display_counts"
    display_counts="$latest_display_counts"
    physical_count="$latest_physical_count"
fi
headless=0
if [ "$physical_count" -eq 0 ]; then headless=1; fi
headless_prepared=0
if [ "$status_code" -eq 1 ] && [ "$headless" -eq 1 ]; then
    feedback "$SOUND_START" "没有实体显示器，正在准备虚拟备用屏幕"
    prepare_headless_fallback
    headless_code=$?
    if [ "$headless_code" -ne 0 ]; then
        exit "$headless_code"
    fi
    headless_prepared=1
fi
if [ "$status_code" -eq 0 ] && [ "$headless" -eq 1 ]; then
    # A Sidecar session can be connected while its headless display is absent
    # or disconnected. Re-establish the virtual output before treating the
    # session as ready; status alone does not mean iPad has an active picture.
    feedback "$SOUND_START" "没有实体显示器，正在确认虚拟备用屏幕"
    prepare_headless_fallback
    headless_code=$?
    if [ "$headless_code" -ne 0 ]; then
        exit "$headless_code"
    fi
    headless_prepared=1
fi
if [ "$status_code" -eq 0 ]; then
    if verify_connected_display 2; then
        if [ "$headless" -eq 1 ]; then
            if [ "${ACTIVE_VIRTUAL_DISPLAY_BACKEND:-}" = "builtin" ]; then
                builtin_virtual_set_sidecar_main || log "built-in provider could not verify Sidecar main status; connection remains valid because the Sidecar display is online"
            elif ! resolve_betterdisplay_cli || ! ensure_betterdisplay_running; then
                log "headless main-display handoff refused: BetterDisplay unavailable or could not start"
                feedback "$SOUND_FAILURE" "随航已连接，但 BetterDisplay 不可用，无法切换主屏"
                notify "$NOTIFY_TITLE" "BetterDisplay 不可用，无法设置 iPad 主屏"
                exit 4
            elif ! set_headless_sidecar_main; then
                feedback "$SOUND_FAILURE" "随航已连接，但无法切换为主屏，请检查 BetterDisplay"
                notify "$NOTIFY_TITLE" "随航会话存在，但无法设为主屏"
                exit 4
            elif ! verify_sidecar_main "$DISPLAY_VERIFY_SECONDS"; then
                feedback "$SOUND_FAILURE" "随航会话已连接，但 iPad 尚未成为主屏"
                notify "$NOTIFY_TITLE" "未验证 iPad 主屏状态；没有重复连接"
                exit 4
            fi
        else
            if ! ensure_physical_main; then
                notify "$NOTIFY_TITLE" "随航已连接，但未能确认实体显示器主屏状态"
                exit 4
            fi
        fi
        log "explicit connect skipped: Sidecar display is already ready ($IPAD_NAME)"
        if [ "$CONNECTION_MODE" = "wireless" ]; then
            feedback "$SOUND_SUCCESS" "随航画面已经就绪。为避免中断当前 iPad，没有切换连接方式；需要无线时请先断开再连接"
            notify "$NOTIFY_TITLE" "已有随航会话；未切换传输方式。要确保无线，请先断开再连接"
        elif [ "$headless" -eq 1 ]; then
            if [ "${ACTIVE_VIRTUAL_DISPLAY_BACKEND:-}" = "builtin" ]; then
                feedback "$SOUND_SUCCESS" "无显示器模式，随航已就绪；项目内置虚拟屏在线"
                notify "$NOTIFY_TITLE" "无显示器模式：随航已就绪；项目内置虚拟屏在线"
            else
                feedback "$SOUND_SUCCESS" "无显示器模式，随航已就绪并设为主屏"
                notify "$NOTIFY_TITLE" "无显示器模式：随航已就绪并设为主屏"
            fi
        else
            feedback "$SOUND_SUCCESS" "随航画面已经就绪，没有重复连接"
            notify "$NOTIFY_TITLE" "随航显示已经就绪，未重复连接"
        fi
        exit 0
    fi
    log "explicit connect refused: session reported connected but no Sidecar display is online"
    feedback "$SOUND_FAILURE" "系统报告已连接，但没有检测到随航画面，请检查显示器配置后再重试"
    notify "$NOTIFY_TITLE" "系统报告已连接，但没有检测到随航画面；未重复抢占 iPad"
    exit 4
fi
# A physical-display path made no topology changes after the preceding fresh
# gate. Rechecking here would add another debounce with no new information.
# Headless preparation changes topology, so it still gets a final stable gate.
if [ "$headless" -eq 1 ]; then
    latest_display_counts="$(recheck_display_topology "$display_counts")"
    latest_display_probe_code=$?
    if [ "$latest_display_probe_code" -ne 0 ]; then
        log "explicit connect refused: display topology changed before $CONNECTION_MODE request: $latest_display_counts"
        feedback "$SOUND_FAILURE" "显示器状态仍在变化，未连接随航，请稍后再试"
        notify "$NOTIFY_TITLE" "显示器状态仍在变化，未连接随航"
        exit 3
    fi
    latest_physical_count="${latest_display_counts#physical=}"
    latest_physical_count="${latest_physical_count%% *}"
    if [[ "$latest_physical_count" =~ ^[0-9]+$ ]] && [ "$latest_physical_count" != "$physical_count" ]; then
        log "display topology changed before $CONNECTION_MODE request: $display_counts -> $latest_display_counts"
        physical_count="$latest_physical_count"
        headless=0
        [ "$physical_count" -eq 0 ] && headless=1
    fi
fi
 if [ "$headless" -eq 1 ] && [ "$headless_prepared" -eq 0 ]; then
     feedback "$SOUND_START" "没有实体显示器，正在准备虚拟备用屏幕"
     prepare_headless_fallback
     headless_code=$?
     if [ "$headless_code" -ne 0 ]; then
         exit "$headless_code"
     fi
     headless_prepared=1
 fi
connect_started_ms="$(monotonic_milliseconds)"
output="$(run_with_timeout "$SIDECAR_CONNECT_TIMEOUT_SECONDS" "$SIDECAR_BIN" connect "$IPAD_NAME" "$CONNECT_OPTION" 2>&1)"
code=$?
connect_finished_ms="$(monotonic_milliseconds)"
if [[ "$connect_started_ms" =~ ^[0-9]+$ ]] && [[ "$connect_finished_ms" =~ ^[0-9]+$ ]]; then
    log "$TRANSPORT_LABEL Sidecar API request returned in $((connect_finished_ms - connect_started_ms))ms (exit=$code)"
fi
if [ "$code" -eq 0 ]; then
    if verify_connected_display "$DISPLAY_VERIFY_SECONDS"; then
        if [ "$headless" -eq 1 ]; then
            if [ "${ACTIVE_VIRTUAL_DISPLAY_BACKEND:-}" = "builtin" ]; then
                builtin_virtual_set_sidecar_main || log "built-in provider could not verify Sidecar main status; connection remains valid because the Sidecar display is online"
            elif ! set_headless_sidecar_main; then
                log "$TRANSPORT_LABEL Sidecar display online, but BetterDisplay could not make the iPad main"
                feedback "$SOUND_FAILURE" "随航画面已出现，但无法将 iPad 设为主屏"
                notify "$NOTIFY_TITLE" "无显示器模式：设置 iPad 主屏失败"
                exit 4
            elif ! verify_sidecar_main "$DISPLAY_VERIFY_SECONDS"; then
                log "$TRANSPORT_LABEL Sidecar display online, but CoreGraphics did not report Sidecar as main"
                feedback "$SOUND_FAILURE" "连接请求成功，但 iPad 还没有成为主屏"
                notify "$NOTIFY_TITLE" "连接已建立，但未验证 iPad 主屏状态"
                exit 4
            fi
        else
            if ! ensure_physical_main; then
                notify "$NOTIFY_TITLE" "随航已连接，但未能确认实体显示器主屏状态"
                exit 4
            fi
        fi
        log "explicit $TRANSPORT_LABEL Sidecar connect succeeded and display is online: $output"
        if [ "$headless" -eq 1 ]; then
            if [ "${ACTIVE_VIRTUAL_DISPLAY_BACKEND:-}" = "builtin" ]; then
                feedback "$SOUND_SUCCESS" "无显示器模式，${TRANSPORT_LABEL}随航已就绪；项目内置虚拟屏在线"
                notify "$NOTIFY_TITLE" "无显示器模式：随航已就绪；项目内置虚拟屏在线"
            else
                feedback "$SOUND_SUCCESS" "无显示器模式，${TRANSPORT_LABEL}随航已就绪，iPad 已设为主屏"
                notify "$NOTIFY_TITLE" "无显示器模式：随航已就绪并设为主屏"
            fi
        else
            feedback "$SOUND_SUCCESS" "${TRANSPORT_LABEL}随航画面已就绪，iPad 连接成功"
            notify "$NOTIFY_TITLE" "${TRANSPORT_LABEL}随航显示已就绪"
        fi
        exit 0
    fi

    log "$TRANSPORT_LABEL Sidecar connect request returned success, but display did not become ready: $output"
    feedback "$SOUND_FAILURE" "连接请求已接受，但没有检测到随航画面。请检查 iPad 是否解锁，以及无显示器时的虚拟显示配置"
    notify "$NOTIFY_TITLE" "连接请求已接受，但未检测到随航显示。请检查 iPad 状态和显示器配置"
    exit 4
fi

log "explicit $TRANSPORT_LABEL Sidecar connect failed (no retry): $output"
if printf '%s' "$output" | /usr/bin/grep -Eqi 'device was not found|device not found|-200'; then
    if [ "$CONNECTION_MODE" = "wireless" ]; then
        feedback "$SOUND_FAILURE" "没有发现 iPad。请确认两台设备在十米内，使用同一 Apple 账户，并打开 Wi-Fi、蓝牙和接力"
        notify_detail "$NOTIFY_TITLE 连接失败" "没有发现 iPad。检查距离、相同 Apple 账户、双重认证、Wi-Fi、蓝牙和接力。详情：$output"
    else
        feedback "$SOUND_FAILURE" "没有发现 iPad。请确认数据线已连接、iPad 已解锁并信任这台 Mac"
        notify_detail "$NOTIFY_TITLE 连接失败" "没有发现 iPad。检查数据线、iPad 解锁状态和信任设置。详情：$output"
    fi
else
    feedback "$SOUND_FAILURE" "${TRANSPORT_LABEL}随航连接失败，没有自动重试"
    notify_detail "$NOTIFY_TITLE 连接失败" "没有自动重试。详情：$output"
fi
exit "$code"
