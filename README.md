# Sidecar Auto

Sidecar Auto 是一个面向 Mac 和 iPad 的一次性连接控制器。它在用户明确按下快捷键后检查当前状态，判断 USB 数据线或无线直连路径，并只发起一次 Sidecar 连接请求。

项目的核心定位是：让没有随身显示器的 Mac mini 使用 iPad 作为主屏工作；连接数据线时优先走有线 Sidecar，未连接数据线时才准备无线路径。家中接有实体显示器时，它仍可作为普通扩展屏使用。

它适合两种场景：

- **有显示器**：Sidecar 作为扩展屏连接，保持 macOS 的普通显示布局。
- **没有显示器**：第一次连接前自动准备项目内置或 BetterDisplay 独立虚拟屏，给 macOS 一个可用的桌面拓扑；Sidecar 画面出现后再尝试把 iPad 设为主屏。

连接过程有中文语音、提示音和通知。连接请求不会在后台无限重试，也不会因为一次断开就重新抢占正在使用的 iPad。

> Sidecar 使用 Apple 的私有 `SidecarCore` API。它不是 Apple 官方工具，macOS 更新可能改变接口。请先阅读[限制与隐私](#限制与隐私)。

## 文档

- [安装与使用](#安装)
- [普通用户 App 指南](docs/APP_GUIDE.md)
- [App 发布与签名](docs/RELEASE.md)
- [架构说明](docs/ARCHITECTURE.md)
- [安全与权限模型](docs/SECURITY_MODEL.md)
- [排障手册](docs/TROUBLESHOOTING.md)
- [测试与发布边界](docs/TESTING.md)
- [English overview](docs/README.en.md)
- [贡献指南](.github/CONTRIBUTING.md)
- [安全政策](.github/SECURITY.md)
- [变更记录](docs/CHANGELOG.md)
- [第三方声明](docs/NOTICE.md)

## 目录结构

```text
.
├── installer/                    # 一键安装脚本和 Finder 入口
├── packaging/                    # App bundle 构建脚本和签名模板
├── scripts/                       # 连接、断开、诊断和快捷键脚本
├── Sources/                       # 本项目的显示探针和蓝牙助手源码
├── vendor/sidecarctl/             # 上游衍生的 Swift CLI（保留独立许可证）
├── launchd/                       # 登录后提示音 LaunchAgent 模板
├── config/                        # 配置示例
├── tests/                          # 不连接真实设备的解析和回归测试
└── docs/                          # 架构、排障和测试文档
```

根目录只保留 GitHub 首页和许可所需的基础文件；安装后的命令统一放在 `~/.local/bin/`，所以已有快捷指令不需要随着仓库目录调整。

## 普通用户 App

不懂代码的用户应优先从 GitHub **Releases** 下载签名并完成公证的
`Sidecar-Auto-Setup.dmg`，把 `Sidecar Auto Setup.app` 拖进“应用程序”，然后按
[普通用户 App 指南](docs/APP_GUIDE.md)操作。App 自带预编译的 `sidecarctl`、显示
状态探针、蓝牙助手和连接脚本；普通用户不需要安装 Swift、clang 或 Xcode
Command Line Tools。

设置助手会逐项显示 macOS、无线状态、目标 iPad、项目内置虚拟屏、BetterDisplay 和配置文件状态，
提供“安装 / 修复”“重新检查”“连接一次”和“断开一次”按钮。它不会在启动或刷新
时自动抢占 iPad，不会保存密码，也不能替用户授予 macOS 或 iPad 的隐私权限。
首次打开会显示配置向导，可扫描已连接 iPad、自动填写 USB 序列号、配置快捷指令并进入一次测试；
概览页还会把 Mac 本机准备度和需要在 iPad 上手动确认的项目分开显示。
关闭主窗口后 App 会保留在菜单栏；从菜单栏可以重新打开设置，或主动执行连接、断开和退出。
它不会因为窗口关闭或用户登录而自动连接 iPad。
环境检查中的“申请 / 开启蓝牙”会在用户点击后触发 macOS 原生确认，并在返回 App
时自动刷新；辅助功能和屏幕录制对当前连接路径不是必需权限。

维护者可以在 macOS 上构建未签名的本地 App：

```sh
./packaging/build-sidecar-auto-app.sh --host-only
./packaging/make-dmg.sh --app "dist/Sidecar Auto Setup.app"
```

有 Developer ID 和已保存的 notarytool profile 时，可以使用
`./packaging/release-sidecar-auto.sh` 一次完成签名、公证、DMG 和 SHA256；普通
开发构建不需要这些凭据。

默认构建 universal `arm64 + x86_64` App，输出到 `dist/Sidecar Auto Setup.app`。
正式发布前还必须使用 Developer ID 签名、创建 DMG、提交 Apple 公证并 stapler；
未签名构建适合开发测试，不适合直接发给普通用户。

## 工作方式

智能入口 `sidecar-connect-once.sh auto` 在发起请求前完成以下检查：

1. 读取一次 Sidecar 设备快照，拒绝未知状态、重复名称和另一台 iPad 已占用的情况。
2. 检查 USB 注册表。唯一匹配的 iPad 数据设备选择 `ForceUSB`；没有匹配设备选择 `ForceAWDL`。多台 iPad 没有配置序列号时停止，避免误连。
3. 并行读取显示拓扑、Sidecar 状态和 USB 检测；无线开关在传输路径确定后按需准备。
4. 没有实体显示器时按配置准备 `SidecarHeadlessFallback`：`auto` 优先项目内置固定虚拟屏，`builtin` 完全不调用 BetterDisplay，`betterdisplay` 使用 BetterDisplay 的高级参数。
5. 只发起一次连接请求，然后同时确认 Sidecar 会话和在线显示画面。API 返回成功但 iPad 没有画面时会报告失败，不会重复抢占设备。

如果连接在创建无显示器备用屏的过程中被取消或失败，控制器只会回收本次操作创建
的项目内置屏或启用的 BetterDisplay 备用屏；用户之前已有的虚拟屏不会被删除。

显式入口仍然可用于排障：

```sh
"$HOME/.local/bin/sidecar-connect-once.sh" wired
"$HOME/.local/bin/sidecar-connect-once.sh" wireless
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

## 前置条件

- Mac 使用 macOS 13 或更高版本；需要 Xcode Command Line Tools（`swiftc`、`clang`、macOS SDK）。
- iPad 支持 Sidecar，与 Mac 登录同一个 Apple Account，并开启双重认证。
- 无线模式要求两台设备都打开 Wi‑Fi、蓝牙和接力（Handoff），保持唤醒并在约 10 米内。Mac 在“系统设置 → 通用 → 隔空投送与连续互通”（旧版 macOS 叫“隔空投送与接力”）中开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”；iPad 在“设置 → 通用 → 隔空播放与接力 → 接力”开启接力。`ForceAWDL` 是设备到设备的无线路径，不要求连接同一个路由器；Wi-Fi 无路由器、无显示器场景仍取决于具体 macOS、硬件和权限，应按[排障](#排障)实际验证。
- 有线模式要求使用可传输数据的 USB 线，并在 iPad 上信任这台 Mac。仅供电的线不会被 USB 检测器识别，会按无线模式处理。
- 无显示器模式默认不需要 BetterDisplay：项目内置 helper 提供固定的 1920×1080、60Hz 虚拟屏。它调用 macOS 未公开的虚拟显示接口，系统更新可能失效；需要 HiDPI、更多分辨率、排列或其他参数时可选择 BetterDisplay。
- iPad 必须唤醒并解锁。Sidecar 不能在锁定的 iPad 上创建屏幕会话。

## 安装

将整个项目文件夹放在本地后，在 Mac 上运行：

```sh
cd /path/to/sidecar-auto
./installer/install-sidecar-auto.sh
```

也可以在 Finder 中双击 `installer/install-sidecar-auto.command`。安装器会：

- 检查 macOS、编译工具和 SDK；
- 并行构建 `sidecarctl`、显示拓扑探针、蓝牙助手和项目内置虚拟屏 helper；
- 检查 Mach-O 输出后逐个原子替换 `~/.local/bin` 中的文件；
- 创建 `~/.config/sidecar-auto/config` 示例（已有配置不会覆盖）；
- 安装只读诊断脚本 `sidecar-doctor.sh`。
- 安装快捷指令导入工具 `install-sidecar-shortcuts.sh`。

安装器不会安装 BetterDisplay，不会自动启动 Sidecar，不会授予 Bluetooth、辅助功能或屏幕录制权限，也不会加载后台重连服务。设置助手安装运行时后可一键生成快捷指令导入文件；macOS 仍会对每个快捷指令显示“添加快捷指令”确认，这是系统安全要求。缺少编译工具时先运行：

```sh
xcode-select --install
```

首次无线连接请在有显示器、Mac 已解锁时完成一次 Bluetooth 权限授权。无显示器时无法回答 macOS 的隐私弹窗。

### 配置目标 iPad

安装器生成的配置默认使用名称 `iPad`。只有在存在多个 Sidecar 设备或 USB 设备时才需要修改：

```sh
$EDITOR "$HOME/.config/sidecar-auto/config"
```

也可以参考 [`config/config.example`](config/config.example) 中的可选参数。

```sh
IPAD_NAME="iPad Pro"
# 多台 iPad 同时插线时填 USB Serial Number；不需要时保持注释。
# IPAD_USB_SERIAL_NUMBER=""
AUTO_ENABLE_HANDOFF=1
# auto / builtin / betterdisplay
VIRTUAL_DISPLAY_BACKEND="auto"
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

名称必须与 macOS 看到的 Sidecar 设备名匹配。USB 序列号只用于选择物理连接的设备，不会上传。

## 创建 macOS 快捷指令和快捷键

在设置助手“环境检查”中点击“一键配置快捷指令”，即可生成并打开连接、断开两个快捷指令的导入确认窗口。请先在第一个窗口点击“添加快捷指令”，设置助手会在确认完成后再打开第二个窗口。模板会同时声明 `QuickActions` 类型，导入后会出现在“快速操作”并支持键盘快捷键；安装器随后写入建议快捷键 `⌃⌥⌘S`（连接）和 `⌃⌥⌘D`（断开）。如果当前 macOS 版本拒绝这项设置，日志会提示你在快捷指令详情中手动录入。旧版本已经导入、但不在“快速操作”中的快捷指令需要重新导入一次，或在详情中开启“作为快速操作使用”。命令行用户也可以执行 `~/.local/bin/install-sidecar-shortcuts.sh`。手动创建时，在 macOS“快捷指令”中创建下表中的动作；“连接无线 Sidecar（排障）”是可选的手动诊断快捷指令，一键配置不会导入它：

| 快捷指令 | 脚本 | 建议快捷键 |
| --- | --- | --- |
| 连接 Sidecar | `exec "$HOME/.local/bin/sidecar-connect-once.sh" auto` | `⌃⌥⌘S` |
| 连接无线 Sidecar（排障） | `exec "$HOME/.local/bin/sidecar-connect-wireless-once.sh"` | `⌃⌥⌘W` |
| 断开 Sidecar | `exec "$HOME/.local/bin/sidecar-disconnect-once.sh"` | `⌃⌥⌘D` |

“连接 Sidecar”是日常入口，会根据 USB 数据设备自动选择有线或无线。“连接无线”始终请求 `ForceAWDL`，用于验证无线路径。快捷指令运行在 Mac 上；iPad 上的快捷指令不能直接调用 Mac 的私有 Sidecar API。

首次运行每个“运行 Shell 脚本”动作时，macOS 会分别询问是否允许“连接 Sidecar”或“断开 Sidecar”运行 Shell 脚本。该确认不能静默授予；请在有显示器时各运行一次并点击“允许”，再回到设置助手重新检查。设置助手不会为了探测权限自动执行真实连接。

每次操作都会先播放开始提示音，再用 `say` 播报进度。成功使用 `Glass.aiff`，失败或拒绝使用 `Basso.aiff`。音效来自 Mac 当前音频输出；无显示器使用前请先测试音量。可在配置中设置 `SPEAK=0` 关闭语音，音效仍会保留。

脚本在 `~/Library/Caches/sidecar-auto/explicit-action.lock` 中串行化同时按键，并把结果写入 `~/Library/Logs/sidecar-auto.log`。日志只保存在本机，可能包含 iPad 名称和系统错误。

## 无显示器和虚拟屏方案

拔掉显示器后，WindowServer 可能在几秒内仍报告旧拓扑。连接脚本会等待拓扑稳定；不要在这段时间重复按快捷键。脚本会按 provider：

1. 根据 `VIRTUAL_DISPLAY_BACKEND` 选择项目内置 helper 或 BetterDisplay；
2. 缺少时创建并验证唯一虚拟屏；
3. 将虚拟屏上线后再请求 Sidecar；
4. Sidecar 画面上线后将 iPad 设为主屏并再次验证。

项目内置虚拟屏由当前登录用户会话中的 helper 在连接期间持有；helper 退出后屏幕会从 WindowServer 消失。它不是登录项，也不会在打开 App 或刷新状态时启动。BetterDisplay 虚拟屏不能代替 Sidecar，也不能修复锁定的 iPad。选用 BetterDisplay 时，CLI 被禁用或 Pro/试用资格不足会明确失败，不会播报虚假的“连接成功”。

## 诊断与排障

只读诊断不会连接、断开或修改设置：

```sh
"$HOME/.local/bin/sidecar-doctor.sh"
```

重点检查：

- `sidecarctl snapshot` 返回的目标状态和当前会话；
- USB 检测结果（`USB_IPAD_MATCHED`、`USB_IPAD_NOT_FOUND` 或 `USB_IPAD_AMBIGUOUS`）；
- 显示拓扑和 `display-state`；
- Mac 的 Wi-Fi、蓝牙状态；
- BetterDisplay 和 Pro 能力查询（不会为查询启动 GUI）。

常见提示：

- **没有发现 iPad / `SidecarErrorDomain -200`**：检查数据线、iPad 是否解锁并信任 Mac；无线模式检查两台设备距离、Apple Account、Wi-Fi、蓝牙和接力。
- **`-201` 超时**：通常是 iPad 锁定。解锁 iPad 后再按一次；不要用重启代替解锁。
- **连接请求成功但没有随航画面**：先检查所选虚拟屏后端和显示器拓扑；脚本不会连续发送连接请求。
- **检测到多个 iPad**：在配置中设置准确的 `IPAD_NAME` 和 `IPAD_USB_SERIAL_NUMBER`。
- **首次无线时没有反应**：接上显示器，在“系统设置 → 隐私与安全性 → 蓝牙”允许 Shortcuts 或相关工具，再重试。

更完整的本机状态可使用：

```sh
"$HOME/.local/bin/sidecarctl" snapshot
"$HOME/.local/bin/sidecarctl" status
```

## 可选：登录后提示音

`sidecar-login-ready.sh` 只能在用户登录、桌面已经建立后运行。它播放提示音并播报“桌面已准备好”，不会输入密码、解锁 FileVault 或自动启动 Sidecar。

设置助手“环境检查”中的“开启提示”会自动安装当前用户的 LaunchAgent；“停用提示”会
卸载它。这个登录项只播报桌面就绪，不会自动连接、断开或抢占 iPad。重启后是否需要
在 FileVault 解密界面输入密码，仍由 macOS 安全设置决定。

如需安装对应的 LaunchAgent，先把模板中的两个占位符替换为当前用户路径：

```sh
ROOT="/path/to/sidecar-auto"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed \
  -e "s|__LOGIN_READY_PATH__|$HOME/.local/bin/sidecar-login-ready.sh|g" \
  -e "s|__LOG_PATH__|$HOME/Library/Logs/sidecar-login-ready|g" \
  "$ROOT/launchd/com.sidecarauto.login-ready.plist.template" \
  > "$HOME/Library/LaunchAgents/com.sidecarauto.login-ready.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.sidecarauto.login-ready.plist"
```

卸载提示服务：

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.sidecarauto.login-ready.plist"
```

启用 FileVault 时，冷启动会停在解密密码界面，macOS 不允许普通自动登录。设置助手会分别提供“文件保险箱”和“自动登录”设置入口，但不会替用户关闭 FileVault、保存密码或盲打密码。关闭 FileVault 并等待解密会降低启动前保护；登录提示脚本不运行在 FileVault 解锁界面。

## 开发和验证

项目按用途组织：连接、断开、诊断和安装后的运行脚本位于 `scripts/`；显示探针和蓝牙助手源码位于 `Sources/`；从上游保留并修改的 Swift CLI 位于 `vendor/sidecarctl/`；登录提示 LaunchAgent 模板位于 `launchd/`；一键安装入口位于 `installer/`。根目录只保留项目首页、许可证和 GitHub 配置。构建 Swift CLI 不会安装或启动菜单栏应用。

提交前运行：

```sh
bash -n ./installer/install-sidecar-auto.sh ./scripts/*.sh
./vendor/sidecarctl/build.sh --cli-only --build-only
bash ./tests/test_usb_detector.sh
```

测试脚本只使用伪造的 IORegistry 输出，不会连接、断开或修改真实 iPad。

不要在 CI 中执行真实 Sidecar 连接；它会占用用户的显示器，需要解锁且可能弹出系统提示。请在报告中记录 macOS 版本、Mac 架构、USB/无线方式、是否有实体显示器和 iPad 是否解锁。

## 限制与隐私

- 连接功能依赖 Apple 未公开的 `SidecarCore`；内置虚拟屏还依赖 macOS 未公开的虚拟显示接口；macOS 更新可能需要重新编译或调整选择器。
- Sidecar 只能在用户桌面会话中启动，不能显示 FileVault 解锁画面或登录前画面。
- Wi-Fi、蓝牙、接力开关无法从 Mac 远程修改 iPad；Mac 侧的 Handoff 设置只是尽力写入，不能证明 iPad 侧已开启。
- 脚本不会绕过 BetterDisplay 许可、TCC 权限、FileVault 或 macOS 安全策略。
- 项目不收集遥测。配置、日志和 Sidecar 配对状态保留在本机；发布前请删去日志、设备序列号和绝对路径。
- 当前发布包不包含编译二进制、日志、个人配置、`.DS_Store` 或编辑器交换文件；这些规则见 [`.gitignore`](.gitignore)。

## 许可证和第三方代码

自动化代码使用 MIT License，详见 [`LICENSE`](LICENSE)。`vendor/sidecarctl` 中保留的上游 MIT 版权必须保留，来源和范围见 [`docs/NOTICE.md`](docs/NOTICE.md)。项目与 Apple 或 BetterDisplay 均无隶属或背书关系。
