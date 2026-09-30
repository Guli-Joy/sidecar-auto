#!/bin/bash
# Finder double-click entry point for people who received the project folder.

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/install-sidecar-auto.sh"
status=$?

printf '\n'
if [ "$status" -eq 0 ]; then
    printf 'Sidecar 工具已安装。按回车关闭此窗口。\n'
else
    printf '安装未完成（退出码 %s）。按回车关闭此窗口；修复上面的提示后可重新双击。\n' "$status"
fi
read -r _
exit "$status"
