# 排障手册

先运行只读诊断，再决定是否再次按连接键：

```sh
"$HOME/.local/bin/sidecar-doctor.sh"
"$HOME/.local/bin/sidecarctl" snapshot
tail -n 100 "$HOME/Library/Logs/sidecar-auto.log"
```

### App 意外退出

如果 macOS 显示“Sidecar Auto 设置助手意外退出”，先从最新 Release 重新下载 DMG，
把新的 App 拖到“应用程序”并替换旧副本。较早的构建在读取辅助程序输出结束时可能被
macOS 的 `FileHandle` 异常终止；当前构建会把该情况当作一次操作失败并保留诊断，
不会退出整个设置助手。若仍有问题，可把最新的
`~/Library/Logs/DiagnosticReports/SidecarAutoSetup-*.ips` 提供给维护者。

### 连接时提示“找不到 sidecarctl”

从“应用程序”打开设置助手，点击“安装 / 修复”，再点击“重新检查”。连接或断开时如果
发现运行时版本过旧，当前 App 也会先自动执行一次“安装 / 修复”，然后继续操作。安装器会把
`sidecarctl` 和显示检测程序复制到 `~/.local/bin/`。如果配置文件来自旧版本，其中
`SIDECAR_BIN="$HOME/.local/bin/sidecarctl"` 这样的字面路径也会被当前版本兼容处理；
无需把 `$HOME` 手动改成用户名。可以用只读诊断确认：

```sh
ls -l "$HOME/.local/bin/sidecarctl"
"$HOME/.local/bin/sidecar-doctor.sh"
```

## 常见结果

### `USB_IPAD_NOT_FOUND`

没有发现已枚举的 iPad USB 数据设备。确认使用的是数据线、iPad 已解锁并信任此 Mac。自动入口会选择无线；如果你想强制有线，请使用 `wired`，它会在条件不足时失败而不会改走无线。

### `USB_IPAD_AMBIGUOUS`

同时检测到多台 iPad。把目标 iPad 的 USB Serial Number 写入配置：

```sh
printf '%s\n' 'IPAD_USB_SERIAL_NUMBER="在此填写序列号"' >> "$HOME/.config/sidecar-auto/config"
```

同时设置精确的 `IPAD_NAME`，避免 Sidecar 设备名匹配多个结果。

### `SidecarErrorDomain -200`

本次请求没有发现设备。重新确认 USB 信任、iPad 解锁状态和无线前置条件；等待几秒让 USB 或 AWDL 恢复后再按一次。

### `SidecarErrorDomain -201`

通常表示 iPad 仍在锁屏。解锁 iPad 后再按一次。脚本不会通过重启 iPad 来掩盖这个原因。

### “请求成功但没有随航画面”

`sidecarctl` 接受请求不代表 WindowServer 已创建在线画面。无显示器时确认所选虚拟屏后端在线：内置后端可运行 `~/.local/bin/sidecar-virtual-display status`，BetterDisplay 后端则确认 `SidecarHeadlessFallback` 已连接并有 Pro/试用资格；有显示器时检查显示器是否仍在稳定拓扑中。不要连续按键，脚本已禁止重复请求。

### 无线入口没有反应

两台设备都要唤醒、解锁、登录同一 Apple Account，并开启 Wi-Fi、蓝牙和 Handoff。Mac 路径是“系统设置 → 通用 → 隔空投送与连续互通”（旧版 macOS 叫“隔空投送与接力”），并开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”，iPad 路径是“设置 → 通用 → 隔空播放与接力 → 接力”。`ForceAWDL` 不要求加入同一个路由器，但 Mac 的 Wi-Fi 必须保持开启。第一次使用时把显示器接回，允许 macOS 的 Bluetooth/TCC 提示；iPad 侧的开关不能由 Mac 远程修改。

### 无显示器时虚拟屏失败

若使用内置方案，运行 `sidecar-virtual-display status`；如果 helper 无法创建或系统更新后不再支持 SPI，把配置改为 `VIRTUAL_DISPLAY_BACKEND="betterdisplay"` 并按 BetterDisplay 的 CLI、虚拟屏和 Pro/试用提示处理。脚本会验证屏幕确实在线，失败时播报失败并停止。

### 登录后没有自动准备虚拟屏

打开 Sidecar Auto 的“连接设置 → 无显示器虚拟屏”，确认“登录后静默启动 Sidecar Auto”
已开启并点击“保存设置”。没有实体显示器时，这一项是必需的；关闭它，登录后不会有
可用主屏，iPad 也无法作为主屏使用。然后检查运行时是否完整安装；也可以在终端确认登录项和日志：

```sh
launchctl print "gui/$(id -u)/com.sidecarauto.setup"
tail -n 80 "$HOME/Library/Logs/sidecar-auto-login.out.log"
tail -n 80 "$HOME/Library/Logs/sidecar-auto.log"
```

登录项只负责启动 App；虚拟屏准备由 App 启动后的内置脚本完成。如果选择了 BetterDisplay，
请在 BetterDisplay 中开启它自己的登录启动和虚拟屏设置。

## 安全恢复

如果一次操作被中断，先断开已存在的 Sidecar 会话；如果你曾手动配置过后台重连服务，也请先停止它：

```sh
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

需要收集报告时，只发送脱敏后的 `sidecar-doctor.sh` 输出；不要发送 Apple Account、密码、配对令牌、完整日志或 USB 序列号。
