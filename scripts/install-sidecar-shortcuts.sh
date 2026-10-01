#!/usr/bin/env bash
# Create and open the two macOS Shortcuts used by Sidecar Auto.
#
# Shortcuts intentionally has no public `import` command.  We therefore build
# the standard .shortcut property list, sign it locally with the user's own
# identity, and ask Shortcuts.app to show its normal review/add sheet.  The
# sheet is a security boundary: a third-party app cannot silently add a
# shortcut to a user's library.

set -euo pipefail
umask 077

BIN_DIR="${SIDECAR_AUTO_BIN_DIR:-$HOME/.local/bin}"
STATE_DIR="${SIDECAR_AUTO_STATE_DIR:-$HOME/Library/Application Support/Sidecar Auto/Shortcuts}"
SHORTCUTS_BIN="/usr/bin/shortcuts"
SHORTCUTS_APP="/System/Applications/Shortcuts.app"
UUIDGEN_BIN="/usr/bin/uuidgen"
SHORTCUTS_DB="$HOME/Library/Shortcuts/Shortcuts.sqlite"

fail() {
    printf '快捷指令安装失败：%s\n' "$*" >&2
    exit 1
}
note() {
    printf '%s\n' "$*"
}

[ "$(uname -s)" = "Darwin" ] || fail "此工具只能在 macOS 上运行"
[ -x "$SHORTCUTS_BIN" ] || fail "系统没有找到 /usr/bin/shortcuts；请确认已安装 macOS 快捷指令"
[ -d "$SHORTCUTS_APP" ] || fail "系统没有找到快捷指令 App"
[ -x "$UUIDGEN_BIN" ] || fail "系统没有找到 uuidgen；无法生成快捷指令动作标识"

CONNECT="$BIN_DIR/sidecar-connect-once.sh"
DISCONNECT="$BIN_DIR/sidecar-disconnect-once.sh"
[ -x "$CONNECT" ] || fail "找不到连接脚本：${CONNECT}，请先在设置助手中点击“安装 / 修复”"
[ -x "$DISCONNECT" ] || fail "找不到断开脚本：${DISCONNECT}，请先在设置助手中点击“安装 / 修复”"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# XML escaping for the small subset used in a shell-script action.
xml_escape() {
    local value="$1"
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    value=${value//\"/&quot;}
    value=${value//\'/&apos;}
    printf '%s' "$value"
}

write_unsigned() {
    local output="$1" name="$2" script="$3"
    local escaped_name escaped_script action_uuid
    escaped_name="$(xml_escape "$name")"
    escaped_script="$(xml_escape "$script")"
    action_uuid="$($UUIDGEN_BIN | tr '[:lower:]' '[:upper:]')"
    cat >"$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WFWorkflowActions</key>
  <array>
    <dict>
      <key>WFWorkflowActionIdentifier</key>
      <string>is.workflow.actions.runshellscript</string>
      <key>WFWorkflowActionParameters</key>
      <dict>
        <key>Script</key>
        <string>${escaped_script}</string>
        <key>UUID</key>
        <string>${action_uuid}</string>
      </dict>
    </dict>
  </array>
  <key>WFWorkflowClientRelease</key>
  <string>2.0</string>
  <key>WFWorkflowClientVersion</key>
  <string>1200</string>
  <key>WFWorkflowIcon</key>
  <dict>
    <key>WFWorkflowIconGlyphNumber</key>
    <integer>59512</integer>
    <key>WFWorkflowIconStartColor</key>
    <integer>4282601983</integer>
  </dict>
  <key>WFWorkflowMinimumClientVersion</key>
  <integer>900</integer>
  <key>WFWorkflowMinimumClientRelease</key>
  <string>2.0</string>
  <key>WFWorkflowName</key>
  <string>${escaped_name}</string>
  <key>WFWorkflowTypes</key>
  <array>
    <string>NCWidget</string>
  </array>
</dict>
</plist>
EOF
}

shortcut_names() {
    LC_ALL=C "$SHORTCUTS_BIN" list 2>/dev/null \
        | sed '/^[[:space:]]*$/d; s/[[:space:]]*$//' \
        || true
}

has_shortcut() {
    local name="$1" slug="$2"
    # `shortcuts list` prints one shortcut name per line.  Match complete
    # lines.  Older versions of this installer wrote the slug as the import
    # filename, so macOS saved the shortcut as `connect-sidecar` instead of
    # the user-facing Chinese name.  Treat that alias as installed too; this
    # lets an upgrade continue with the missing disconnect shortcut instead of
    # waiting forever for a rename that cannot happen automatically.
    shortcut_names | grep -F -x -e "$name" -e "$slug" >/dev/null
}

set_keyboard_shortcut() {
    local name="$1" slug="$2" equivalent="$3" workflow_id service_key plist
    # Shortcuts stores the optional service keyboard equivalent in the
    # per-user `pbs` preferences domain.  There is no public Shortcuts CLI for
    # this setting, but updating this preference is the same operation the
    # Shortcuts detail panel performs.  Keep it best-effort: if a future
    # macOS release changes the private SQLite schema, importing the shortcuts
    # still succeeds and the user can enter the key in the detail panel.
    [ -r "$SHORTCUTS_DB" ] || return 1
    workflow_id="$(/usr/bin/sqlite3 -readonly "$SHORTCUTS_DB" \
        "SELECT ZWORKFLOWID FROM ZSHORTCUT WHERE ZTOMBSTONED=0 AND ZNAME IN ('$name','$slug') ORDER BY ZMODIFICATIONDATE DESC LIMIT 1;" \
        2>/dev/null | tr -d '[:space:]')"
    [[ "$workflow_id" =~ ^[A-Fa-f0-9-]{36}$ ]] || return 1

    plist="$STATE_DIR/pbs.$$.plist"
    if ! /usr/bin/defaults export pbs "$plist" >/dev/null 2>&1; then
        return 1
    fi
    service_key="(null) - ${workflow_id} - runShortcutAsService"
    # plutil's key-path syntax accepts the literal service key (including
    # spaces and parentheses).  Insert a new dictionary for first-time
    # imports, or replace only the equivalent when the entry already exists.
    if ! /usr/bin/plutil -insert "NSServicesStatus.${service_key}" \
        -xml "<dict><key>key_equivalent</key><string>${equivalent}</string></dict>" \
        "$plist" >/dev/null 2>&1; then
        /usr/bin/plutil -replace "NSServicesStatus.${service_key}.key_equivalent" \
            -string "$equivalent" "$plist" >/dev/null 2>&1 || {
            rm -f "$plist"
            return 1
        }
    fi
    if ! /usr/bin/defaults import pbs "$plist" >/dev/null 2>&1; then
        rm -f "$plist"
        return 1
    fi
    rm -f "$plist"
    return 0
}

install_one() {
    local name="$1" script="$2" slug="$3"
    local unsigned="$STATE_DIR/$slug.unsigned.shortcut"
    # Shortcuts.app derives the imported title from the filename.  Keep the
    # signed file's basename equal to the visible shortcut name so a fresh
    # import is shown as “连接 Sidecar” / “断开 Sidecar”, rather than the
    # implementation slug.  The slug remains only for the private staging
    # file and for backwards-compatible detection above.
    local signed="$STATE_DIR/${name}.shortcut"

    if has_shortcut "$name" "$slug"; then
        note "已存在“${name}”，跳过导入。"
        local hotkey
        if [ "$name" = "连接 Sidecar" ]; then
            hotkey='@~^s'
        else
            hotkey='@~^d'
        fi
        if set_keyboard_shortcut "$name" "$slug" "$hotkey"; then
            note "已尝试设置“${name}”键盘快捷键。"
        else
            note "无法自动设置“${name}”键盘快捷键；请在快捷指令详情中录入建议组合键。"
        fi
        return 0
    fi

    write_unsigned "$unsigned" "$name" "$script"
    # Local signing does not upload the script.  It lets the current user
    # import it under Shortcuts' normal review sheet.
    if ! "$SHORTCUTS_BIN" sign --mode people-who-know-me --input "$unsigned" --output "$signed" >/dev/null 2>&1; then
        fail "无法为“${name}”生成本机签名快捷指令"
    fi
    chmod 600 "$unsigned" "$signed"
    open "$signed"
    note "已打开“${name}”的导入确认窗口，请在快捷指令中点击“添加快捷指令”。"
    # Do not open the second import sheet until this one has been accepted;
    # Shortcuts.app only displays one review sheet at a time and otherwise the
    # second `open` would replace the first.  Polling the read-only list keeps
    # the flow hands-off while preserving Apple's explicit confirmation.
    local waited=0
    while [ "$waited" -lt 600 ]; do
        if has_shortcut "$name" "$slug"; then
            note "“${name}”已添加。"
            local hotkey
            if [ "$name" = "连接 Sidecar" ]; then
                hotkey='@~^s'
            else
                hotkey='@~^d'
            fi
            if set_keyboard_shortcut "$name" "$slug" "$hotkey"; then
                note "已尝试设置“${name}”键盘快捷键。"
            else
                note "无法自动设置“${name}”键盘快捷键；请在快捷指令详情中录入建议组合键。"
            fi
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    note "等待“${name}”确认超时；请稍后重新点击一键创建。"
    return 1
}

connect_command='exec "$HOME/.local/bin/sidecar-connect-once.sh" auto'
disconnect_command='exec "$HOME/.local/bin/sidecar-disconnect-once.sh"'

if ! install_one "连接 Sidecar" "$connect_command" connect-sidecar; then
    exit 1
fi
if ! install_one "断开 Sidecar" "$disconnect_command" disconnect-sidecar; then
    exit 1
fi

note "完成后可在快捷指令详情中分别设置键盘快捷键。"
note "文件保存在：$STATE_DIR"
