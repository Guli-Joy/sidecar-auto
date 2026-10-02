# 测试与发布边界

## 自动化检查

CI 只做不会占用用户设备的检查：

- Bash 语法检查；
- Swift CLI-only 编译；
- `Sources/DisplayState/DisplayState.swift`、`Sources/BluetoothRadio/sidecar-bluetooth-radio.c` 和 `Sources/VirtualDisplay/sidecar-virtual-display.m` 的 macOS 构建；
- SwiftUI 设置助手的 host-only App bundle 构建、资源树、Info.plist 和 Mach-O 检查；
- DMG 镜像校验，以及 App 和“应用程序”快捷方式布局检查；
- plist 和发布目录检查。
- USB iPad 检测器的唯一设备、无设备、多设备和序列号筛选测试；测试使用伪造
  的 IORegistry 输出，不会接触真实 iPad。
- 一次性连接控制器的安全集成测试；使用伪造的 Sidecar、显示拓扑、USB 和无线
  辅助程序，覆盖有线选择、无线前置、多个 iPad 拒绝误连以及锁目录清理，不会
  发起真实连接。

CI 不会调用 `sidecarctl connect`、BetterDisplay 的写操作或真实快捷指令。

本地可运行：

```sh
bash -n ./installer/install-sidecar-auto.sh ./scripts/*.sh
bash ./tests/test_usb_detector.sh
bash ./tests/test_connect_controller.sh
./installer/install-sidecar-auto.sh --build-only
./packaging/build-sidecar-auto-app.sh --host-only --output "$(mktemp -d)"
```

## 手工验收矩阵

真实 Sidecar 测试需要一台 Mac 和一台可解锁的 iPad。每次报告应记录 macOS 版本、Mac 架构、连接方式、是否有实体显示器、是否加入路由器、iPad 是否解锁以及 BetterDisplay 版本。

| 场景 | 目标 |
| --- | --- |
| USB + 实体显示器 | 确认 `ForceUSB`、Sidecar 画面和扩展屏布局 |
| USB + 无实体显示器 | 确认虚拟屏创建、iPad 主屏和画面验证 |
| USB + 无实体显示器 + `VIRTUAL_DISPLAY_BACKEND=builtin` | 确认 helper 常驻、内置虚拟屏上线、Sidecar 主屏切换和断开后备用屏恢复 |
| USB + 无实体显示器 + `VIRTUAL_DISPLAY_BACKEND=betterdisplay` | 确认 BetterDisplay CLI、Pro/试用能力、虚拟屏参数和主屏切换 |
| AWDL + 实体显示器 | 确认 `ForceAWDL` 和无线前置条件 |
| AWDL + 无路由器 + 无实体显示器 | 单独记录；当前不把它当成所有 Mac 都已验收 |
| 已有其他 iPad 会话 | 必须停止并播报拒绝，不能抢占 |
| iPad 锁定 | 必须报告用户动作，不应循环重试 |

当前项目在一台 Apple silicon Mac 上完成过 USB 实机验证，也完成过带实体显示器、连接家庭 Wi-Fi 的无线实机验证。内置 helper 的创建、状态、排列请求和销毁已在 macOS 27 主机验证；公开 CoreGraphics 布局接口不能在本机可靠保证主屏切换，因此 builtin 后端只把主屏调整作为尽力操作，并以 Sidecar 在线画面作为连接成功条件。没有实体显示器的完整 Sidecar 会话、macOS 13–15 兼容后端和无路由器 AWDL 组合仍需真实设备验收，不应写成普遍保证。
