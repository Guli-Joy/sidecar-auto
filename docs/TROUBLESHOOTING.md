# 排障手册

先运行只读诊断，再决定是否再次按连接键：

```sh
"$HOME/.local/bin/sidecar-doctor.sh"
"$HOME/.local/bin/sidecarctl" snapshot
tail -n 100 "$HOME/Library/Logs/sidecar-auto.log"
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

`sidecarctl` 接受请求不代表 WindowServer 已创建在线画面。无显示器时确认 BetterDisplay 正在运行、`SidecarHeadlessFallback` 已连接并有 Pro/试用资格；有显示器时检查显示器是否仍在稳定拓扑中。不要连续按键，脚本已禁止重复请求。

### 无线入口没有反应

两台设备都要唤醒、解锁、登录同一 Apple Account，并开启 Wi-Fi、蓝牙和 Handoff。`ForceAWDL` 不要求加入同一个路由器，但 Mac 的 Wi-Fi 必须保持开启。第一次使用时把显示器接回，允许 macOS 的 Bluetooth/TCC 提示；iPad 侧的开关不能由 Mac 远程修改。

### 无显示器时 BetterDisplay 失败

打开 BetterDisplay，确认 CLI 集成和虚拟屏功能可用。创建虚拟屏可能免费，但通过 CLI 连接/启用显示器可能需要 Pro 或试用。脚本会验证屏幕确实存在，失败时播报失败并停止。

## 安全恢复

如果一次操作被中断，先断开已存在的 Sidecar 会话；如果你曾手动配置过后台重连服务，也请先停止它：

```sh
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

需要收集报告时，只发送脱敏后的 `sidecar-doctor.sh` 输出；不要发送 Apple Account、密码、配对令牌、完整日志或 USB 序列号。
