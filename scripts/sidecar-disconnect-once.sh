#!/bin/bash
# Safely disconnect Sidecar once, only when explicitly invoked by the user.
# This script intentionally has no background retry or wireless fallback.

set -u

CONFIG="${SIDECAR_AUTO_CONFIG:-$HOME/.config/sidecar-auto/config}"
[ -r "$CONFIG" ] && . "$CONFIG"

: "${IPAD_NAME:=iPad}"
: "${SIDECAR_BIN:=$HOME/.local/bin/sidecarctl}"
: "${DISPLAY_STATE_BIN:=$HOME/.local/bin/display-state}"
: "${BETTERDISPLAY_CLI:=}"
: "${BETTERDISPLAY_APP:=}"
: "${BETTERDISPLAY_TIMEOUT_SECONDS:=8}"
: "${SIDECAR_STATUS_TIMEOUT_SECONDS:=8}"
: "${SIDECAR_DISCONNECT_TIMEOUT_SECONDS:=25}"
: "${DISPLAY_VERIFY_SECONDS:=12}"
: "${DISPLAY_VERIFY_INTERVAL:=1}"
# Keep this separate from any virtual screen associated with the iPad.  The
# fallback must be manually connectable before Sidecar is established.
: "${VIRTUAL_DISPLAY_NAME:=SidecarHeadlessFallback}"
: "${DISABLE_FALLBACK_WITH_PHYSICAL:=1}"
: "${LOG_FILE:=$HOME/Library/Logs/sidecar-auto.log}"
: "${SOUND_START:=/System/Library/Sounds/Tink.aiff}"
: "${SOUND_SUCCESS:=/System/Library/Sounds/Glass.aiff}"
: "${SOUND_FAILURE:=/System/Library/Sounds/Basso.aiff}"
: "${VOICE:=Tingting}"
: "${SPEAK:=1}"
: "${SIDECAR_AUTO_TEST_MODE:=0}"

LOCK_DIR="$HOME/Library/Caches/sidecar-auto/explicit-action.lock"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_DIR")" 2>/dev/null || true
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"; }
notify() {
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
    play_sound "$1"
    speak "$2"
}
run_with_timeout() {
    # macOS does not include GNU timeout. Perl's alarm gives every external
    # probe/CLI call a hard limit; no unbounded fallback is allowed here.
    local seconds="$1"
    shift
    if [ ! -x /usr/bin/perl ]; then
        log "cannot run bounded command: /usr/bin/perl unavailable"
        return 125
    fi
    /usr/bin/perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}
run_sidecar_status() {
    run_with_timeout "$SIDECAR_STATUS_TIMEOUT_SECONDS" "$SIDECAR_BIN" status "$IPAD_NAME"
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
            if [ -d "$app" ]; then BETTERDISPLAY_APP_RESOLVED="$app"; break; fi
        done
    fi
    if [ -z "$BETTERDISPLAY_CLI_RESOLVED" ] && [ -n "$BETTERDISPLAY_APP_RESOLVED" ]; then
        candidate="$BETTERDISPLAY_APP_RESOLVED/Contents/MacOS/BetterDisplay"
        [ ! -x "$candidate" ] || BETTERDISPLAY_CLI_RESOLVED="$candidate"
    fi
    [ -n "$BETTERDISPLAY_CLI_RESOLVED" ]
}
run_betterdisplay() {
    run_with_timeout "$BETTERDISPLAY_TIMEOUT_SECONDS" "$BETTERDISPLAY_CLI_RESOLVED" "$@"
}
read_topology() {
    TOPOLOGY_OUTPUT="$(run_with_timeout 6 "$DISPLAY_STATE_BIN" 2>&1)"
    TOPOLOGY_CODE=$?
    [ "$TOPOLOGY_CODE" -eq 0 ] || return 1
    TOPOLOGY_PHYSICAL="$(printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -F= '$1 == "physical" { print $2; found=1; exit } END { if (!found) exit 1 }')" || return 1
    TOPOLOGY_SIDECAR="$(printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -F= '$1 == "sidecar" { print $2; found=1; exit } END { if (!found) exit 1 }')" || return 1
    TOPOLOGY_VIRTUAL="$(printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -F= '$1 == "virtual" { print $2; found=1; exit } END { if (!found) exit 1 }')" || return 1
    [[ "$TOPOLOGY_PHYSICAL" =~ ^[0-9]+$ ]] || return 1
    [[ "$TOPOLOGY_SIDECAR" =~ ^[0-9]+$ ]] || return 1
    [[ "$TOPOLOGY_VIRTUAL" =~ ^[0-9]+$ ]] || return 1
    local row_counts row_physical row_sidecar row_virtual main_count
    row_counts="$(printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk '
        /^display id=[0-9]+ kind=physical / { p++ }
        /^display id=[0-9]+ kind=sidecar / { s++ }
        /^display id=[0-9]+ kind=virtual / { v++ }
        /^display id=[0-9]+ / && /main=1/ { m++ }
        END { printf "%d %d %d %d\n", p+0, s+0, v+0, m+0 }')"
    read -r row_physical row_sidecar row_virtual main_count <<< "$row_counts"
    [ "$row_physical" -eq "$TOPOLOGY_PHYSICAL" ] || return 1
    [ "$row_sidecar" -eq "$TOPOLOGY_SIDECAR" ] || return 1
    [ "$row_virtual" -eq "$TOPOLOGY_VIRTUAL" ] || return 1
    [ "$main_count" -eq 1 ] || return 1
    return 0
}
json_normalize_identifiers() {
    /usr/bin/perl -0777 -MJSON::PP -ne '
        my $text = $_; $text =~ s/^\s+|\s+$//g;
        $text = "[$text]" if $text =~ /^\{/;
        my $decoded = eval { decode_json($text) };
        if ($@ || ref($decoded) ne "ARRAY") { print STDERR "invalid identifiers JSON sequence\n"; exit 2; }
        print encode_json($decoded), "\n";
    '
}
read_identifiers() {
    IDENTIFIERS_RAW="$(run_betterdisplay get -identifiers 2>&1)"
    IDENTIFIERS_CODE=$?
    [ "$IDENTIFIERS_CODE" -eq 0 ] || return 1
    IDENTIFIERS_JSON="$(printf '%s\n' "$IDENTIFIERS_RAW" | json_normalize_identifiers 2>&1)"
    IDENTIFIERS_CODE=$?
    [ "$IDENTIFIERS_CODE" -eq 0 ]
}
find_virtual() {
    VIRTUAL_INFO="$(printf '%s\n' "$IDENTIFIERS_JSON" | VIRTUAL_TARGET_NAME="$VIRTUAL_DISPLAY_NAME" /usr/bin/perl -0777 -MJSON::PP -ne '
        my $target = lc($ENV{"VIRTUAL_TARGET_NAME"} // "");
        my $decoded = eval { decode_json($_) }; if ($@) { exit 2; }
        my @items = ref($decoded) eq "ARRAY" ? @$decoded : (ref($decoded) eq "HASH" ? ($decoded) : ());
        my @named = grep { ref($_) eq "HASH" && lc($_->{name} // "") eq $target } @items;
        my @matches = grep { lc($_->{deviceType} // "") eq "virtualscreen" } @named;
        @matches = grep { (($_->{vendor} // "") eq "2198") } @named if !@matches;
        if (@matches > 1) { print STDERR "virtual display name is ambiguous\n"; exit 3; }
        if (!@matches) { print "exists=0 online=0\n"; exit 0; }
        my $item = $matches[0]; my $id = $item->{displayID};
        my $online = defined($id) && "$id" =~ /^\d+$/ && $id > 0 ? 1 : 0;
        my $selector = "virtualName=" . ($item->{name} // "");
        print "exists=1 online=$online displayID=" . (defined($id) ? $id : 0) . " selector=$selector\n";
    ' 2>&1)"
    VIRTUAL_CODE=$?
    [ "$VIRTUAL_CODE" -eq 0 ]
}
find_display_identifier() {
    local wanted_id="$1"
    PHYSICAL_SELECTOR="$(printf '%s\n' "$IDENTIFIERS_JSON" | WANTED_DISPLAY_ID="$wanted_id" /usr/bin/perl -0777 -MJSON::PP -ne '
        my $wanted = $ENV{"WANTED_DISPLAY_ID"} // "";
        my $decoded = eval { decode_json($_) }; if ($@) { exit 2; }
        my @items = ref($decoded) eq "ARRAY" ? @$decoded : (ref($decoded) eq "HASH" ? ($decoded) : ());
        my @matches = grep { ref($_) eq "HASH" && defined($_->{displayID}) && "$_->{displayID}" eq $wanted } @items;
        if (@matches != 1) { print STDERR "expected one BetterDisplay identifier for displayID=$wanted, found " . scalar(@matches) . "\n"; exit 3; }
        my $item = $matches[0]; my $uuid = $item->{UUID} // $item->{uuid} // "";
        if ($uuid =~ /^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/) { print "UUID=$uuid\n"; }
        else { print "displayID=$wanted\n"; }
    ' 2>&1)"
    [ "$?" -eq 0 ]
}
selector_arg() {
    case "$1" in
        UUID=*) printf '%s\n' "-${1}" ;;
        displayID=*) printf '%s\n' "-${1}" ;;
        name=*) printf '%s\n' "-${1}" ;;
        virtualName=*) printf '%s\n' "-name=${1#virtualName=}" ;;
        *) return 2 ;;
    esac
}
get_bool() {
    # BetterDisplay prints a short textual value for boolean get operations.
    # Accept only an unambiguous on/off value; unknown formats fail closed.
    printf '%s\n' "$1" | /usr/bin/perl -ne '
        while (/\b(on|off|true|false|yes|no)\b|(?:^|[=:])\s*([01])\s*$/ig) {
            my $v = defined($1) ? lc($1) : $2;
            $v = $v eq "1" ? "on" : "off" if $v eq "0" || $v eq "1";
            $v = "on" if $v eq "true" || $v eq "yes";
            $v = "off" if $v eq "false" || $v eq "no";
            print "$v\n";
        }
    ' | /usr/bin/tail -n 1
}
get_display_bool() {
    local selector="$1" feature="$2" output code
    local selector_option
    selector_option="$(selector_arg "$selector")" || return 2
    if [[ "$selector" == virtualName=* ]]; then
        output="$(run_betterdisplay get "$selector_option" -type=VirtualScreen "-$feature" 2>&1)"
    else
        output="$(run_betterdisplay get "$selector_option" "-$feature" 2>&1)"
    fi
    code=$?
    [ "$code" -eq 0 ] || { printf 'unknown\n'; return 1; }
    local value
    value="$(get_bool "$output")"
    [ -n "$value" ] || { printf 'unknown\n'; return 1; }
    printf '%s\n' "$value"
}
set_display_main() {
    local selector="$1" selector_option output code
    selector_option="$(selector_arg "$selector")" || return 2
    if [[ "$selector" == virtualName=* ]]; then
        output="$(run_betterdisplay set "$selector_option" -type=VirtualScreen -main=on 2>&1)"
    else
        output="$(run_betterdisplay set "$selector_option" -main=on 2>&1)"
    fi
    code=$?
    [ "$code" -eq 0 ] || { log "BetterDisplay set main failed ($selector): $output"; return "$code"; }
    log "BetterDisplay selected main display ($selector): $output"
    return 0
}
topology_has_main() {
    local id="$1" kind="$2"
    printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -v id="$id" -v kind="$kind" '
        index($0, "display id=" id " ") == 1 && $0 ~ ("kind=" kind " ") && $0 ~ /main=1/ { found++ }
        END { exit(found == 1 ? 0 : 1) }'
}
main_physical_id() {
    local rows count id
    rows="$(printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk '/^display id=[0-9]+ kind=physical / && /main=1/')"
    count="$(printf '%s\n' "$rows" | /usr/bin/awk 'NF { n++ } END { print n+0 }')"
    [ "$count" -eq 1 ] || return 1
    id="$(printf '%s\n' "$rows" | /usr/bin/awk '{ for (i=1;i<=NF;i++) if ($i ~ /^id=/) { sub(/^id=/,"",$i); print $i; exit } }')"
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}
virtual_probe_id() {
    local expected_name
    expected_name="$(printf '%s' "$VIRTUAL_DISPLAY_NAME" | /usr/bin/sed 's/ /_/g')"
    printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -v name="$expected_name" '
        /^display id=[0-9]+ kind=virtual / {
            rowname=""
            for (i=1;i<=NF;i++) if ($i ~ /^name=/) { rowname=$i; sub(/^name=/,"",rowname); break }
            if (rowname == name) { n++; id=$2; sub(/^id=/,"",id) }
        }
        END { if (n==1) print id; else exit 1 }'
}
verify_physical_main() {
    local id="$1"
    read_topology || return 1
    topology_has_main "$id" physical || return 1
    printf '%s\n' "$TOPOLOGY_OUTPUT" | /usr/bin/awk -v id="$id" '
        index($0, "display id=" id " ") == 1 && $0 ~ /kind=physical / {
            for (i=1;i<=NF;i++) if ($i ~ /^mirror=/) { split($i, pair, "="); value=pair[2] }
            if (value == "0") found=1
        }
        END { exit(found == 1 ? 0 : 1) }'
}
verify_virtual_main() {
    local id selector main
    read_topology || return 1
    id="$(virtual_probe_id)" || return 1
    topology_has_main "$id" virtual || return 1
    read_identifiers || return 1
    find_virtual || return 1
    printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 ' || return 1
    selector="$(printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/sed -n 's/.* selector=//p')"
    [ -n "$selector" ] || return 1
    main="$(get_display_bool "$selector" main)" || return 1
    [ "$main" = "on" ]
}
ensure_virtual_ready() {
    local output code deadline
    read_identifiers || { log "BetterDisplay identifiers preflight failed: $IDENTIFIERS_RAW"; return 1; }
    find_virtual || { log "could not identify BetterDisplay virtual fallback: $VIRTUAL_INFO"; return 1; }
    if ! printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 '; then
        output="$(run_betterdisplay create -devicetype=virtualscreen "-virtualscreenname=$VIRTUAL_DISPLAY_NAME" -aspectWidth=16 -aspectHeight=10 2>&1)"
        code=$?
        [ "$code" -eq 0 ] || { log "could not create fallback virtual display: $output"; return 1; }
        log "created fallback virtual display '$VIRTUAL_DISPLAY_NAME': $output"
        deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
        while (( SECONDS <= deadline )); do
            read_identifiers && find_virtual && printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 ' && break
            sleep "$DISPLAY_VERIFY_INTERVAL"
        done
        printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 ' || return 1
    fi
    find_virtual || return 1
    if ! printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 '; then
        output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -connected=on 2>&1)"
        code=$?
        [ "$code" -eq 0 ] || { log "could not enable fallback virtual display: $output"; return 1; }
        log "enabled fallback virtual display: $output"
        deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
        while (( SECONDS <= deadline )); do
            read_identifiers && find_virtual && printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 ' && break
            sleep "$DISPLAY_VERIFY_INTERVAL"
        done
        printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 ' || return 1
    fi
    read_identifiers || return 1
    find_virtual || return 1
    local selector
    selector="$(printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/sed -n 's/.* selector=//p')"
    [ -n "$selector" ] || return 1
    set_display_main "$selector" || return 1
    deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
    while (( SECONDS <= deadline )); do
        verify_virtual_main && return 0
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    return 1
}
wait_for_disconnected() {
    local deadline="$1" status_output status_code
    deadline=$((SECONDS + deadline))
    while (( SECONDS <= deadline )); do
        status_output="$(run_sidecar_status 2>&1)"
        status_code=$?
        if [ "$status_code" -eq 1 ] && read_topology && [ "$TOPOLOGY_SIDECAR" -eq 0 ]; then
            log "Sidecar session and display are both offline"
            return 0
        fi
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "Sidecar did not become fully offline before timeout (last status=$status_code output=$status_output topology=${TOPOLOGY_OUTPUT:-unavailable})"
    return 1
}
disable_virtual_fallback() {
    local output code deadline
    read_identifiers || return 1
    find_virtual || return 1
    if ! printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 '; then
        log "physical-display mode: fallback already offline"
        return 0
    fi
    output="$(run_betterdisplay set "-name=$VIRTUAL_DISPLAY_NAME" -type=VirtualScreen -connected=off 2>&1)"
    code=$?
    [ "$code" -eq 0 ] || { log "could not disable fallback virtual display: $output"; return 1; }
    deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
    while (( SECONDS <= deadline )); do
        read_identifiers && find_virtual && ! printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/grep -q '^exists=1 online=1 ' && {
            log "disabled unused fallback virtual display: $output"
            return 0
        }
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    log "fallback virtual display did not go offline after disabling it: $VIRTUAL_INFO"
    return 1
}
disable_fallback_if_possible() {
    [ "$DISABLE_FALLBACK_WITH_PHYSICAL" = "1" ] || return 0
    if ! resolve_betterdisplay_cli; then
        log "BetterDisplay CLI unavailable; skipping optional fallback cleanup"
        return 0
    fi
    if ! /usr/bin/pgrep -x BetterDisplay >/dev/null 2>&1; then
        log "BetterDisplay app is not running; skipping optional fallback cleanup"
        return 0
    fi
    if ! disable_virtual_fallback; then
        log "optional fallback cleanup failed; Sidecar is disconnected and CoreGraphics confirms the physical main display"
    fi
    return 0
}
finish_failure() {
    local code="$1" phrase="$2" detail="$3"
    log "$detail"
    feedback "$SOUND_FAILURE" "$phrase"
    notify "Sidecar" "$phrase"
    exit "$code"
}
validate_seconds() {
    local name="$1" value="$2" maximum="$3"
    # Reject zero, leading-zero/octal-looking values, non-integers, and huge
    # waits before they can reach alarm or a deadline calculation.
    [[ "$value" =~ ^[1-9][0-9]{0,2}$ ]] || finish_failure 64 "断开配置中的超时值无效" "invalid timeout configuration: $name='$value'"
    (( value <= maximum )) || finish_failure 64 "断开配置中的超时值超出范围" "timeout configuration exceeds limit: $name=$value maximum=$maximum"
}

validate_seconds BETTERDISPLAY_TIMEOUT_SECONDS "$BETTERDISPLAY_TIMEOUT_SECONDS" 30
validate_seconds SIDECAR_STATUS_TIMEOUT_SECONDS "$SIDECAR_STATUS_TIMEOUT_SECONDS" 60
validate_seconds SIDECAR_DISCONNECT_TIMEOUT_SECONDS "$SIDECAR_DISCONNECT_TIMEOUT_SECONDS" 120
validate_seconds DISPLAY_VERIFY_SECONDS "$DISPLAY_VERIFY_SECONDS" 60
validate_seconds DISPLAY_VERIFY_INTERVAL "$DISPLAY_VERIFY_INTERVAL" 5

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner=""
    [ ! -r "$LOCK_DIR/pid" ] || owner="$(<"$LOCK_DIR/pid")"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || finish_failure 75 "随航操作锁异常，请稍后再试" "disconnect refused: stale lock could not be reclaimed"
    else
        finish_failure 75 "已有一个随航操作正在执行，请等待提示结束后再试" "disconnect skipped: action already running (owner=${owner:-unknown})"
    fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT
feedback "$SOUND_START" "正在检查并断开随航"

[ -x "$SIDECAR_BIN" ] || finish_failure 127 "找不到 sidecarctl" "disconnect failed: sidecarctl not found at $SIDECAR_BIN"
[ -x "$DISPLAY_STATE_BIN" ] || finish_failure 127 "找不到显示状态检测程序，未断开" "disconnect failed: display probe not found at $DISPLAY_STATE_BIN"
if ! read_topology; then
    finish_failure 3 "无法读取当前显示器拓扑，未断开" "disconnect refused: display topology unreadable (exit=${TOPOLOGY_CODE:-unknown}): ${TOPOLOGY_OUTPUT:-}"
fi
status_output="$(run_sidecar_status 2>&1)"
status_code=$?
if [ "$status_code" -ne 0 ] && [ "$status_code" -ne 1 ]; then
    finish_failure 2 "无法确认随航状态，未断开" "disconnect refused: status=$status_code output=$status_output"
fi

headless=0
physical_id=""
physical_selector=""
if [ "$TOPOLOGY_PHYSICAL" -eq 0 ]; then
    headless=1
    resolve_betterdisplay_cli || finish_failure 127 "找不到 BetterDisplay 命令行工具，未断开" "disconnect refused: BetterDisplay CLI not found"
    # A headless teardown must preserve the virtual fallback as the next main
    # display, so BetterDisplay state is a required preflight in this branch.
    if ! read_identifiers; then
        finish_failure 3 "BetterDisplay 状态无法读取，未断开" "disconnect refused: BetterDisplay identifiers preflight failed (exit=$IDENTIFIERS_CODE): $IDENTIFIERS_RAW"
    fi
    if ! ensure_virtual_ready; then
        finish_failure 4 "无显示器模式的虚拟备用屏准备失败，未断开" "disconnect refused: fallback virtual display could not be made online and main"
    fi
else
    physical_id="$(main_physical_id)" || finish_failure 4 "没有唯一的实体主屏，未断开" "disconnect refused: expected one physical main display; topology=$TOPOLOGY_OUTPUT"
    # CoreGraphics already gives the authoritative main-display topology. Do
    # not make a physical-display disconnect depend on a BetterDisplay IPC
    # response; the app may be closed or its CLI may be wedged. BetterDisplay
    # is still used later only when a configured virtual fallback needs cleanup.
    verify_physical_main "$physical_id" || finish_failure 4 "实体显示器处于镜像状态或不可作为主屏，未断开" "disconnect refused: CoreGraphics did not confirm physical displayID=$physical_id as main and unmirrored"
fi

if [ "$status_code" -eq 1 ]; then
    if [ "$TOPOLOGY_SIDECAR" -ne 0 ]; then
        finish_failure 4 "系统状态不一致，检测到随航显示但会话已断开" "disconnect refused: sidecarctl reports offline while topology reports $TOPOLOGY_SIDECAR Sidecar display(s)"
    fi
    if [ "$headless" -eq 1 ]; then
        phrase="随航已经断开，虚拟备用屏仍在线并作为主屏"
        log "disconnect noop: already offline; headless fallback verified online/main"
    else
        disable_fallback_if_possible
        verify_physical_main "$physical_id" || finish_failure 6 "随航已经断开，但实体主屏校验失败" "disconnect noop cleanup failed: physical displayID=$physical_id lost main/unmirrored state"
        phrase="随航已经断开，实体主屏状态正常"
        log "disconnect noop: already offline; physical main display and no-mirror state verified"
    fi
    feedback "$SOUND_SUCCESS" "$phrase"
    notify "Sidecar" "$phrase"
    exit 0
fi
if [ "$TOPOLOGY_SIDECAR" -eq 0 ]; then
    finish_failure 4 "系统状态不一致，未检测到随航画面" "disconnect refused: sidecarctl reports connected but topology has no Sidecar display"
fi

disconnect_output="$(run_with_timeout "$SIDECAR_DISCONNECT_TIMEOUT_SECONDS" "$SIDECAR_BIN" disconnect "$IPAD_NAME" 2>&1)"
disconnect_code=$?
if [ "$disconnect_code" -ne 0 ]; then
    # Check topology anyway: some implementations may complete the request but
    # return a late error. Never call that a success without all postconditions.
    log "sidecarctl disconnect returned $disconnect_code: $disconnect_output"
fi
if ! wait_for_disconnected "$DISPLAY_VERIFY_SECONDS"; then
    finish_failure 5 "断开请求后仍未确认随航完全离线" "disconnect postcondition failed (command exit=$disconnect_code): $disconnect_output"
fi

if [ "$headless" -eq 1 ]; then
    if ! verify_virtual_main; then
        # Sidecar can temporarily take main status during teardown. Restore the
        # already prepared fallback once, then verify rather than retrying Sidecar.
        read_identifiers && find_virtual || finish_failure 6 "随航已断开，但虚拟备用屏状态无法读取" "headless postcondition failed: BetterDisplay virtual identifiers unavailable"
        virtual_selector="$(printf '%s\n' "$VIRTUAL_INFO" | /usr/bin/sed -n 's/.* selector=//p')"
        [ -n "$virtual_selector" ] && set_display_main "$virtual_selector" || finish_failure 6 "随航已断开，但无法恢复虚拟屏主屏" "headless postcondition failed: could not select fallback virtual display as main"
    fi
    verify_virtual_main || finish_failure 6 "随航已断开，但虚拟备用屏没有保持在线并作为主屏" "headless postcondition failed: fallback virtual display is not online/main"
else
    # The external screen was already confirmed as the unmirrored main screen
    # before disconnect. Verify CoreGraphics after teardown; do not require
    # BetterDisplay for a normal physical-monitor disconnect.
    deadline=$((SECONDS + DISPLAY_VERIFY_SECONDS))
    physical_ready=0
    while (( SECONDS <= deadline )); do
        if verify_physical_main "$physical_id"; then physical_ready=1; break; fi
        sleep "$DISPLAY_VERIFY_INTERVAL"
    done
    [ "$physical_ready" -eq 1 ] || finish_failure 6 "随航已断开，但实体主屏状态未通过校验" "physical postcondition failed: displayID=$physical_id is not main and unmirrored"
    disable_fallback_if_possible
    verify_physical_main "$physical_id" || finish_failure 6 "随航已断开，但处理虚拟备用屏后实体主屏校验失败" "physical postcondition failed after optional fallback cleanup for displayID=$physical_id"
fi

if [ "$disconnect_code" -ne 0 ]; then
    finish_failure "$disconnect_code" "显示状态已恢复，但断开命令返回错误" "disconnect command failed after topology recovery (exit=$disconnect_code): $disconnect_output"
fi
if [ "$headless" -eq 1 ]; then
    phrase="随航已断开，虚拟备用屏在线并作为主屏"
else
    phrase="随航已断开，原实体主屏已恢复"
fi
log "explicit Sidecar disconnect succeeded; postconditions verified (headless=$headless physical_id=${physical_id:-none})"
feedback "$SOUND_SUCCESS" "$phrase"
notify "Sidecar" "$phrase"
exit 0
