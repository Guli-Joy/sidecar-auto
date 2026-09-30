# Sidecar Auto 设置助手

Sidecar Auto 设置助手是给普通 Mac 用户使用的图形界面。发布版 App 已经带有
Sidecar Auto 的运行时文件，不需要安装 Swift、clang 或 Xcode Command Line
Tools，也不需要在终端输入命令。

连接 Sidecar 仍然由你主动点击“连接一次”或运行快捷指令触发。打开 App、刷新
状态和检查权限不会自动连接、断开或抢占 iPad。

## 下载与安装

1. 在 GitHub 仓库的 **Releases** 下载 `Sidecar-Auto-Setup.dmg`。
2. 打开 DMG，把 **Sidecar Auto Setup.app** 拖到“应用程序”。
3. 从“应用程序”打开 App。首次启动时 macOS 可能要求确认开发者来源；正式
   Release 应使用 Developer ID 签名并完成 Apple 公证。
4. 点击“安装 / 修复”。App 会把预编译运行时复制到
   `~/.local/bin/`，创建 `~/.config/sidecar-auto/config`，已有配置不会覆盖。
5. 点击“重新检查”，确认状态卡片中的项目已经读取完成。选择“项目内置虚拟屏”时不需要安装 BetterDisplay；选择“BetterDisplay（高级参数）”时，无实体显示器连接才会要求 BetterDisplay CLI。

不要从 GitHub 的 **Code → Download ZIP** 代替正式 Release 给普通用户使用。
ZIP 是源代码，适合开发者；它不能代替签名和公证后的 App。

## 第一次配置

新版设置助手左侧分为“概览”“连接设置”“环境检查”和“手动测试”。概览页只显示
下一步和常用操作；检查项不会因为状态刷新而连接 iPad。需要修改设备或虚拟屏时，
分别进入对应分区，保存后再回到“环境检查”点击重新检查。

### 1. 选择目标 iPad

在“目标 iPad”区域填写 Mac 系统中显示的 Sidecar 设备名称，通常是 `iPad` 或
你给 iPad 设置的名称。只有同时连接多台 iPad 时才需要填写 USB 序列号。

点击“保存配置”。名称、序列号和虚拟屏名称只保存在本机，不会上传。

### 2. 有线模式

1. 使用支持数据传输的 USB 线连接 iPad。
2. 解锁 iPad，并在第一次连接时点“信任这台电脑”。
3. 在设置助手中确认蓝牙、Wi‑Fi 和目标 iPad 状态。
4. 点击“连接一次”。工具会检测到唯一的 iPad USB 数据设备后选择有线
   `ForceUSB` 路径。
5. 若连接失败，先保持 iPad 解锁，拔插一次数据线，再点“重新检查”。

仅供电的线不会被识别为有线设备；为避免误连，工具会停止或选择无线路径。

### 3. 无线模式

无线 Sidecar 需要两台设备都满足 Apple 的 Sidecar 条件：

- Mac 和 iPad 登录同一个 Apple Account，并开启双重认证；
- 两台设备都打开 Wi‑Fi、蓝牙和接力（Handoff）。Mac 的路径是“系统设置 → 通用 → 隔空投送与接力 → 接力”；iPad 的路径是“设置 → 通用 → 隔空播放与接力 → 接力”；
- iPad 已解锁并保持唤醒，设备距离较近；
- 首次使用时在有屏幕的情况下允许 macOS 或快捷指令使用蓝牙。

工具只能读取和准备 Mac 侧的无线状态。iPad 端请在“设置 → 通用 → 隔空播放与接力 → 接力”中手动开启；App 不能远程读取或修改这个开关。它不能远程打开 iPad 上的 Wi‑Fi、
蓝牙或接力，也不能代替 macOS 隐私设置中的人工确认。完成设置后回到 App，
点击“重新检查”，再点击“连接一次”。

`ForceAWDL` 是设备到设备的无线传输路径，不等于接入同一个家用路由器。无
路由器、无实体显示器的组合仍受 macOS 版本、机型、权限和 iPad 状态影响，
应先用自己的设备完成一次实测。

### 4. 没有实体显示器

没有显示器时，macOS 可能没有可用于建立 Sidecar 的桌面拓扑。设置助手提供三种
方案：

- **自动选择（推荐）**：优先使用项目内置的固定 1920×1080、60Hz 虚拟屏；如果当前 macOS 无法创建内置屏，脚本会自动尝试 BetterDisplay，随后才提示处理失败；
- **项目内置虚拟屏**：不安装 BetterDisplay，只创建一个最小备用屏；它使用 macOS 未公开接口，系统更新可能失效；
- **BetterDisplay**：需要安装并运行 [BetterDisplay](https://github.com/waydabber/BetterDisplay)，可以使用更多分辨率、HiDPI、排列和其他显示参数。

虚拟屏是 Sidecar 建立前的桌面占位，不是 iPad 屏幕，也不能解锁 iPad。项目内置
方案的名称和模式固定为 `SidecarHeadlessFallback`、1920×1080、60Hz，
`VIRTUAL_DISPLAY_NAME` 只用于 BetterDisplay 后端的命名。选择 BetterDisplay 时，
首次启动的权限、许可和 Pro/试用提示必须由用户自己确认。完成配置后点击“重新检查”，
再进行一次连接测试。内置虚拟屏只在用户点击连接时启动，不会因为打开 App 或刷新状态
而抢占 iPad。

## 权限和状态卡片

App 把状态分成三类：

- **已确认**：本机 API 能读到满足条件的状态；
- **需要你处理**：按钮会打开相应的系统设置或 BetterDisplay 页面，完成后
  回到 App 点击“重新检查”；
- **无法由 App 证明**：例如 iPad 端接力开关、BetterDisplay 的许可和某些
  macOS TCC 状态，最终要通过一次连接测试确认。

系统权限不能被第三方 App 静默授予。设置助手的“申请 / 开启蓝牙”会由 App
原生触发 macOS 蓝牙确认；你点击允许后，App 会自动重新检查，并在需要时尝试
开启 Mac 蓝牙无线电。若权限此前被拒绝，按钮会直接打开对应的系统设置页。
当前连接路径不需要辅助功能或屏幕录制权限；如果 BetterDisplay 需要额外权限，
请在 BetterDisplay 自己的提示中点击允许。App 不会保存密码、不输入 FileVault
密码，也不会绕过系统安全策略。

启用 FileVault 时，冷启动会先停在解密界面。设置助手只在用户登录后的桌面会话
中运行，不能代办开机解密或登录。

## 连接、断开和快捷指令

设置助手中的“连接一次”和“断开一次”是手动的一次性操作：

- 连接前会使用现有的 USB/无线判断、显示拓扑、提示音和超时逻辑；
- 失败时显示退出码和输出，脚本不会无限重试；
- 刷新状态、打开 App 或保存配置不会自动抢占正在使用的 iPad。

如果你需要键盘快捷键，可以在 macOS“快捷指令”中创建两个“运行 Shell
脚本”动作：

| 快捷指令 | Shell 脚本 | 参数 |
| --- | --- | --- |
| 连接 Sidecar | `~/.local/bin/sidecar-connect-once.sh` | `auto` |
| 断开 Sidecar | `~/.local/bin/sidecar-disconnect-once.sh` | 无 |

快捷指令本身仍需要用户在 macOS 中创建，App 不会偷偷修改快捷指令或注册后台
自动重连服务。快捷指令的蓝牙授权属于快捷指令运行上下文；设置助手的状态不能
替代这一次授权。

## 常见问题

### App 显示“运行时资源不完整”

请从正式 Release 重新下载完整的 DMG，并在 App 内点击“安装 / 修复”。不要
只复制 App 里的某一个文件。开发者可以改用源代码安装器：

```sh
./installer/install-sidecar-auto.sh
```

### 点击连接后提示成功，但 iPad 没有画面

先确认 iPad 已解锁，再检查显示器拓扑和所选虚拟屏是否在线。打开
终端运行只读诊断：

```sh
~/.local/bin/sidecar-doctor.sh
```

诊断不会连接、断开或修改无线开关。不要连续快速点击“连接一次”；脚本用锁和
单次请求防止并行抢占。

### 找不到 iPad

有线模式检查数据线和“信任这台电脑”；无线模式检查同一 Apple Account、Wi‑Fi、
蓝牙、接力和设备距离。多台 iPad 同时出现时，在 App 中填写准确的设备名和
USB 序列号。

### 首次无线操作没有反应

先接回显示器，在 macOS 系统设置中允许运行快捷指令或相关工具访问蓝牙，确认
BetterDisplay 的首次提示已处理，再点“重新检查”。没有显示器时无法盲目回答
macOS 的隐私弹窗。

## 隐私和安全

- App、脚本和诊断不上传遥测；
- 配置、日志、Sidecar 配对状态和设备名称只保留在本机；
- App 不保存 Apple Account、iPad 密码或 FileVault 密码；
- Sidecar 使用 Apple 未公开的 `SidecarCore`，macOS 更新可能使连接失效；
- BetterDisplay 是独立项目，按其许可证和权限提示使用。

更完整的边界说明见[安全与权限模型](SECURITY_MODEL.md)、[排障手册](TROUBLESHOOTING.md)
和[测试边界](TESTING.md)。
