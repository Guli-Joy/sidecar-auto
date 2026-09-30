# Sidecar Auto

Sidecar Auto 是一个面向 Mac 和 iPad 的一次性连接控制器。它在用户明确按下快捷键后检查当前状态，判断 USB 数据线或无线直连路径，并只发起一次 Sidecar 连接请求。

它适合两种场景：

- **有显示器**：Sidecar 作为扩展屏连接，保持 macOS 的普通显示布局。
- **没有显示器**：第一次连接前自动准备 BetterDisplay 独立虚拟屏，给 macOS 一个可用的桌面拓扑；Sidecar 画面出现后再把 iPad 设为主屏。

连接过程有中文语音、提示音和通知。连接请求不会在后台无限重试，也不会因为一次断开就重新抢占正在使用的 iPad。

> Sidecar 使用 Apple 的私有 `SidecarCore` API。它不是 Apple 官方工具，macOS 更新可能改变接口。请先阅读[限制与隐私](#限制与隐私)。

## 文档

- [安装与使用](#安装)
- [架构说明](docs/ARCHITECTURE.md)
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
├── scripts/                       # 连接、断开、诊断和快捷键脚本
├── Sources/                       # 本项目的显示探针和蓝牙助手源码
├── vendor/sidecarctl/             # 上游衍生的 Swift CLI（保留独立许可证）
├── launchd/                       # 登录后提示音 LaunchAgent 模板
├── config/                        # 配置示例
└── docs/                          # 架构、排障和测试文档
```

根目录只保留 GitHub 首页和许可所需的基础文件；安装后的命令统一放在 `~/.local/bin/`，所以已有快捷指令不需要随着仓库目录调整。

## 工作方式

智能入口 `sidecar-connect-once.sh auto` 在发起请求前完成以下检查：

1. 读取一次 Sidecar 设备快照，拒绝未知状态、重复名称和另一台 iPad 已占用的情况。
2. 检查 USB 注册表。唯一匹配的 iPad 数据设备选择 `ForceUSB`；没有匹配设备选择 `ForceAWDL`。多台 iPad 没有配置序列号时停止，避免误连。
3. 并行读取显示拓扑、Sidecar 状态和 USB 检测；无线开关在传输路径确定后按需准备。
4. 没有实体显示器时检查 BetterDisplay 的 `SidecarHeadlessFallback` 虚拟屏；缺少时创建并验证，后续重复使用。
5. 只发起一次连接请求，然后同时确认 Sidecar 会话和在线显示画面。API 返回成功但 iPad 没有画面时会报告失败，不会重复抢占设备。

显式入口仍然可用于排障：

```sh
"$HOME/.local/bin/sidecar-connect-once.sh" wired
"$HOME/.local/bin/sidecar-connect-once.sh" wireless
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

## 前置条件

- Mac 使用 macOS 13 或更高版本；需要 Xcode Command Line Tools（`swiftc`、`clang`、macOS SDK）。
- iPad 支持 Sidecar，与 Mac 登录同一个 Apple Account，并开启双重认证。
- 无线模式要求两台设备都打开 Wi-Fi、蓝牙和接力（Handoff），保持唤醒并在约 10 米内。`ForceAWDL` 是设备到设备的无线路径，不要求连接同一个路由器；Wi-Fi 无路由器、无显示器场景仍取决于具体 macOS、硬件和权限，应按[排障](#排障)实际验证。
- 有线模式要求使用可传输数据的 USB 线，并在 iPad 上信任这台 Mac。仅供电的线不会被 USB 检测器识别，会按无线模式处理。
- 无显示器模式需要 BetterDisplay。创建虚拟屏本身可能免费，但用命令行连接显示器属于 BetterDisplay 的 Pro/试用能力；安装器不会代替用户处理授权和首次启动权限。
- iPad 必须唤醒并解锁。Sidecar 不能在锁定的 iPad 上创建屏幕会话。

## 安装

将整个项目文件夹放在本地后，在 Mac 上运行：

```sh
cd /path/to/sidecar-auto
./installer/install-sidecar-auto.sh
```

也可以在 Finder 中双击 `installer/install-sidecar-auto.command`。安装器会：

- 检查 macOS、编译工具和 SDK；
- 并行构建 `sidecarctl`、显示拓扑探针和蓝牙状态助手；
- 检查 Mach-O 输出后逐个原子替换 `~/.local/bin` 中的文件；
- 创建 `~/.config/sidecar-auto/config` 示例（已有配置不会覆盖）；
- 安装只读诊断脚本 `sidecar-doctor.sh`。

安装器不会安装 BetterDisplay，不会自动启动 Sidecar，不会创建快捷指令，不会授予 Bluetooth、辅助功能或屏幕录制权限，也不会加载后台重连服务。缺少编译工具时先运行：

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
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

名称必须与 macOS 看到的 Sidecar 设备名匹配。USB 序列号只用于选择物理连接的设备，不会上传。

## 创建 macOS 快捷指令和快捷键

在 macOS“快捷指令”中分别创建三个“运行 Shell 脚本”动作：

| 快捷指令 | 脚本 | 建议快捷键 |
| --- | --- | --- |
| 连接 Sidecar | `exec "$HOME/.local/bin/sidecar-connect-once.sh" auto` | `⌃⌥⌘S` |
| 连接无线 Sidecar（排障） | `exec "$HOME/.local/bin/sidecar-connect-wireless-once.sh"` | `⌃⌥⌘W` |
| 断开 Sidecar | `exec "$HOME/.local/bin/sidecar-disconnect-once.sh"` | `⌃⌥⌘D` |

“连接 Sidecar”是日常入口，会根据 USB 数据设备自动选择有线或无线。“连接无线”始终请求 `ForceAWDL`，用于验证无线路径。快捷指令运行在 Mac 上；iPad 上的快捷指令不能直接调用 Mac 的私有 Sidecar API。

每次操作都会先播放开始提示音，再用 `say` 播报进度。成功使用 `Glass.aiff`，失败或拒绝使用 `Basso.aiff`。音效来自 Mac 当前音频输出；无显示器使用前请先测试音量。可在配置中设置 `SPEAK=0` 关闭语音，音效仍会保留。

脚本在 `~/Library/Caches/sidecar-auto/explicit-action.lock` 中串行化同时按键，并把结果写入 `~/Library/Logs/sidecar-auto.log`。日志只保存在本机，可能包含 iPad 名称和系统错误。

## 无显示器和 BetterDisplay

拔掉显示器后，WindowServer 可能在几秒内仍报告旧拓扑。连接脚本会等待拓扑稳定；不要在这段时间重复按快捷键。确认 BetterDisplay 已安装并运行后，脚本会：

1. 查找名为 `SidecarHeadlessFallback` 的独立虚拟屏；
2. 缺少时调用 BetterDisplay CLI 创建并验证唯一屏幕；
3. 将虚拟屏上线后再请求 Sidecar；
4. Sidecar 画面上线后将 iPad 设为主屏并再次验证。

BetterDisplay 虚拟屏不能代替 Sidecar，也不能修复锁定的 iPad。没有 BetterDisplay、CLI 被禁用或 Pro/试用资格不足时，脚本会明确失败，不会播报虚假的“连接成功”。硬件显示适配器是否能改善某台 Mac 的无屏幕拓扑取决于 macOS 的显示识别结果，本项目没有把它作为自动化前置条件。

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
- **连接请求成功但没有随航画面**：先检查 BetterDisplay 虚拟屏和显示器拓扑；脚本不会连续发送连接请求。
- **检测到多个 iPad**：在配置中设置准确的 `IPAD_NAME` 和 `IPAD_USB_SERIAL_NUMBER`。
- **首次无线时没有反应**：接上显示器，在“系统设置 → 隐私与安全性 → 蓝牙”允许 Shortcuts 或相关工具，再重试。

更完整的本机状态可使用：

```sh
"$HOME/.local/bin/sidecarctl" snapshot
"$HOME/.local/bin/sidecarctl" status
```

## 可选：登录后提示音

`sidecar-login-ready.sh` 只能在用户登录、桌面已经建立后运行。它播放提示音并播报“桌面已准备好”，不会输入密码、解锁 FileVault 或自动启动 Sidecar。

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

启用 FileVault 时，冷启动会停在解密密码界面，macOS 不允许普通自动登录。关闭 FileVault 并等待解密会降低启动前保护，项目不会替用户作出这个决定，也不会保存或盲打密码。登录提示脚本不运行在 FileVault 解锁界面。

## 开发和验证

项目按用途组织：连接、断开、诊断和安装后的运行脚本位于 `scripts/`；显示探针和蓝牙助手源码位于 `Sources/`；从上游保留并修改的 Swift CLI 位于 `vendor/sidecarctl/`；登录提示 LaunchAgent 模板位于 `launchd/`；一键安装入口位于 `installer/`。根目录只保留项目首页、许可证和 GitHub 配置。构建 Swift CLI 不会安装或启动菜单栏应用。

提交前运行：

```sh
bash -n ./installer/install-sidecar-auto.sh ./scripts/*.sh
./vendor/sidecarctl/build.sh --cli-only --build-only
```

不要在 CI 中执行真实 Sidecar 连接；它会占用用户的显示器，需要解锁且可能弹出系统提示。请在报告中记录 macOS 版本、Mac 架构、USB/无线方式、是否有实体显示器和 iPad 是否解锁。

## 限制与隐私

- 连接功能依赖 Apple 未公开的 `SidecarCore`；macOS 更新可能需要重新编译或调整选择器。
- Sidecar 只能在用户桌面会话中启动，不能显示 FileVault 解锁画面或登录前画面。
- Wi-Fi、蓝牙、接力开关无法从 Mac 远程修改 iPad；Mac 侧的 Handoff 设置只是尽力写入，不能证明 iPad 侧已开启。
- 脚本不会绕过 BetterDisplay 许可、TCC 权限、FileVault 或 macOS 安全策略。
- 项目不收集遥测。配置、日志和 Sidecar 配对状态保留在本机；发布前请删去日志、设备序列号和绝对路径。
- 当前发布包不包含编译二进制、日志、个人配置、`.DS_Store` 或编辑器交换文件；这些规则见 [`.gitignore`](.gitignore)。

## 许可证和第三方代码

自动化代码使用 MIT License，详见 [`LICENSE`](LICENSE)。`vendor/sidecarctl` 中保留的上游 MIT 版权必须保留，来源和范围见 [`docs/NOTICE.md`](docs/NOTICE.md)。项目与 Apple 或 BetterDisplay 均无隶属或背书关系。
