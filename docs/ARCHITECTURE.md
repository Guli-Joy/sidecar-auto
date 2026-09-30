# 架构说明

Sidecar Auto 把一次连接动作拆成“只读预检 → 一次状态改变 → 结果验证”三段。这样快捷键重复按下时不会并行发起多个 Sidecar 请求，也不会把用户正在使用的 iPad 当成空闲设备。

## 组件

| 组件 | 作用 |
| --- | --- |
| `scripts/sidecar-connect-once.sh` | 快捷指令入口；串行锁、音效、语音、显示拓扑和 USB/无线决策 |
| `scripts/sidecar-connect-wireless-once.sh` | 明确请求 `ForceAWDL` 的排障入口 |
| `scripts/sidecar-disconnect-once.sh` | 一次断开，不自动重连 |
| `scripts/sidecar-doctor.sh` | 只读诊断，不改变设备和设置 |
| `scripts/sidecar-ipad-usb-detect.sh` | 从 IORegistry 判断是否存在唯一 iPad USB 数据设备 |
| `Sources/DisplayState/DisplayState.swift` | 使用 CoreGraphics/AppKit 统计实体、虚拟和 Sidecar 显示器 |
| `Sources/BluetoothRadio/sidecar-bluetooth-radio.c` | 读取或准备 Mac 侧蓝牙控制器状态 |
| `vendor/sidecarctl` | 上游衍生的 Swift CLI；设备快照和私有 SidecarCore 调用 |
| `installer/install-sidecar-auto.sh` | 预检、并行构建、产物验证和逐文件安装 |

## 连接流程

```text
快捷指令
   │
   ├─ 串行锁 + 开始提示
   ├─ 显示拓扑稳定采样 ─────┐
   ├─ sidecarctl snapshot ──┼─ 并行只读预检
   ├─ USB 检测 ─────────────┘
   │
   ├─ 有线：ForceUSB
   └─ 无线：ForceAWDL
          │
          ├─ Wi-Fi / 蓝牙 / Handoff 按需准备
          ├─ 无显示器：BetterDisplay 独立虚拟屏
          └─ sidecarctl connect（只发起一次）
                    │
                    └─ Sidecar 状态 + CoreGraphics 画面验证
```

显示拓扑准备、BetterDisplay 创建、设置主屏和 Sidecar 连接必须保持串行。可以并行的只有不会改变系统状态的查询；这是速度和避免竞态之间的边界。

## 为什么保留 Shell 和 Swift

Swift 直接调用 macOS 框架并承担私有 API 和状态快照。Shell 适合被 macOS“快捷指令”直接调用，也方便调用 `afplay`、`say`、`networksetup` 和 BetterDisplay CLI。将入口整体改成 Rust 或 Go 会增加框架绑定和发布步骤，不能减少实际无线协商或显示器建立时间。

## 配置和数据

- 配置：`~/.config/sidecar-auto/config`
- 日志：`~/Library/Logs/sidecar-auto.log`
- 并发锁：`~/Library/Caches/sidecar-auto/explicit-action.lock`
- Swift CLI 的 UserDefaults 域：`io.github.sidecarreconnect`

日志和配置只留在本机。提交诊断时请删除设备名称、USB 序列号、用户名和绝对路径。
