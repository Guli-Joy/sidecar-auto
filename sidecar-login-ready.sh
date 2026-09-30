#!/bin/bash
# Announce that the encrypted disk has been unlocked and the user desktop is ready.
# This runs only after login; it cannot unlock FileVault or type a password.

set -u

LOG_FILE="$HOME/Library/Logs/sidecar-auto.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"; }

if [ -x /usr/bin/afplay ] && [ -r /System/Library/Sounds/Glass.aiff ]; then
    /usr/bin/afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 || true
fi

auto_login_user="$(/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ "$auto_login_user" = "$USER" ]; then
    announcement="开机自动登录成功，Mac 桌面已准备好。随航不会自动启动，需要时请按连接快捷键。"
    log "automatic login detected; desktop ready announced; Sidecar was not started"
else
    announcement="Mac 已进入桌面，当前账户已登录。随航不会自动启动，需要时请按连接快捷键。"
    log "manual or unknown login detected; desktop ready announced; Sidecar was not started"
fi
if [ -x /usr/bin/say ]; then
    /usr/bin/say -v Tingting "$announcement" >/dev/null 2>&1 || \
        /usr/bin/say "$announcement" >/dev/null 2>&1 || true
fi
