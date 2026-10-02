# 安全与权限模型

本文说明 Sidecar Auto 能够检查和操作的范围，以及 macOS 明确禁止第三方
应用代办的步骤。它既适用于当前的脚本入口，也适用于正在开发的设置助手。

## 设计目标

- 连接动作必须由用户明确触发。项目不会因为 iPad 出现、Mac 唤醒或网络变化
  就抢占 iPad。
- 先做只读检查，再执行一次有界的状态改变，最后验证 Sidecar 会话和显示画面。
- 不保存 Apple Account、密码、FileVault 密码、配对令牌或 iPad 的内容。
- TCC、FileVault、iPad 信任和第三方许可证由系统或用户决定，项目不绕过这些边界。
- 日志和配置只保留在本机。诊断报告必须在导出前脱敏。

Sidecar 使用 Apple 未公开的 `SidecarCore` 接口。Sidecar Auto 与 Apple、
BetterDisplay 没有隶属关系，也不能承诺每个 macOS 版本都保留相同的私有接口。

## 进程和信任边界

一次连接可能涉及这些独立进程：

1. 设置助手（SwiftUI App）读取状态、保存配置并打开系统设置；
2. `sidecarctl` 和显示探针调用 macOS 框架；
3. macOS“快捷指令”或用户快捷键启动脚本；
4. 项目内置的 `sidecar-virtual-display` helper 或 BetterDisplay 管理无显示器时的独立虚拟屏；
5. macOS 的 WindowServer、Sidecar 服务和 iPad 接收端。

TCC 授权针对请求访问的应用或进程身份。设置助手获得的授权不能假设会自动
授予 Terminal、快捷指令或一个单独的未签名 helper。因此发布版应尽量让设置
助手完成权限探针和首次授权，并为每个 helper 使用固定的 bundle 路径和签名。
脚本不能把用户可编辑的值拼进 shell 命令；配置项应按允许的字段解析和校验。

## 权限矩阵

“核心”表示普通有线或无线连接所需的条件；“可选”表示只有启用对应的恢复
或显示功能才需要。

| 能力 | 核心/可选 | 设置助手的检测方式 | 用户必须做的事 | 项目不能做的事 |
| --- | --- | --- | --- | --- |
| Mac 蓝牙 TCC | 无线核心 | `CBManager.authorization`；另外读取蓝牙控制器电源状态 | 首次在有桌面时允许 Sidecar Auto 使用蓝牙 | 不能静默授予、替用户点击隐私弹窗 |
| Mac 蓝牙电源 | 无线核心 | `system_profiler` 或受控 helper 读取并核验 | 在系统策略拒绝写入时手动打开蓝牙 | 不能保证私有 IOBluetooth 开关 API 在每个系统版本可用 |
| 辅助功能 | UI 恢复可选 | `AXIsProcessTrustedWithOptions`（只读检查） | 只有启用 Control Center/UI fallback 时，在隐私与安全性→辅助功能添加指定 App | 不能把自己加入列表；`false` 也不能区分“未决定”和“已拒绝” |
| 屏幕录制 | 当前核心不需要 | 只有需要抓取窗口像素时才调用 `CGPreflightScreenCaptureAccess` | 使用截图、串流等功能时手动允许对应 App | 不能把显示器枚举误报成屏幕录制授权，不能静默开启 |
| Apple Events/自动化 | UI 恢复可选 | 对指定目标调用 `AEDeterminePermissionToAutomateTarget`，或在实际动作前受控检查 | 需要时允许 App 控制 System Events/相关目标 | 不能自动批准；默认不启用会驱动 Control Center 的路径 |
| 局域网 | 当前核心不需要 | 不为 ForceAWDL 申请 Local Network TCC | 若将来启用 Bonjour/NWBrowser，按功能允许 | 不能把“连接同一路由器”当作 Sidecar 必需条件 |
| 接力（Handoff） | 无线核心条件 | 只能读取/尽力写入 Mac 偏好；没有可靠的跨设备有效状态 API | 在 Mac 和 iPad 手动开启，并使用同一 Apple Account 和双重认证 | 不能远程改变 iPad 开关，也不能把 `defaults` 写入成功当成运行时成功 |
| 项目内置虚拟屏 | 无显示器可选后端 | 检查 helper、状态文件和在线显示拓扑 | 允许用户会话中的 helper 运行；遇到系统兼容问题时切换后端 | 不能保证未公开 SPI 在未来 macOS 继续可用，也不能静默授予 TCC |
| BetterDisplay | 高级无显示器后端 | 检查 bundle/进程；仅在已运行时查询 CLI 的 `proAvailable` 和虚拟屏状态 | 安装、首次打开、启用虚拟屏和接受其许可/试用条款 | 不能代替安装、绕过 Pro/试用授权或保证其内部 TCC 状态 |
| 登录项/LaunchAgent | 可选 | 设置助手用当前用户的 `launchctl print` 只读核验，并把 plist 限制在 Aqua 用户会话 | 用户在设置助手中明确开启或停用 | 不能伪报后台已启用，不能在登录前显示 Sidecar |

CoreBluetooth 的授权状态与“蓝牙无线电已开启”是两个状态，设置助手必须分别
显示。`AXIsProcessTrustedWithOptions` 和 `CGPreflightScreenCaptureAccess` 的
否定结果也可能表示尚未询问；界面应写成“需要用户确认”，而不是武断地写成
“已拒绝”。不要读取或修改 TCC 数据库来推断状态。

### 有线、无线和无显示器的最低条件

- **有线**：iPad 使用数据线、已解锁并信任这台 Mac。普通有线连接不需要
  Accessibility、Screen Recording 或加入局域网。
- **无线**：两台设备唤醒、解锁并登录同一 Apple Account；Mac 与 iPad 的
  Wi-Fi、蓝牙、Handoff 由用户确认。`ForceAWDL` 是设备到设备路径，不等于
  必须连接同一个路由器。Mac 端蓝牙 TCC 首次授权必须在可见桌面完成。
- **无显示器**：WindowServer 仍需要一个有效桌面拓扑。项目内置 helper 会在用户
  点击连接时创建固定虚拟屏；BetterDisplay 的 CLI 集成和 Pro/试用能力则应先在有
  显示器的会话里完成一次设置。无显示器不能处理突然出现的 TCC、BetterDisplay
  或 Apple Account 弹窗。

## FileVault、登录和冷启动

FileVault 的解密界面发生在用户桌面和普通 App 之前。设置助手、LaunchAgent、
快捷指令和 Sidecar 都不能在这个界面运行，也不能输入或保存密码。FileVault
开启时，冷启动无显示器仍需要用户通过键盘、远程管理或其他已配置的方式先解锁；
项目只在用户登录后播报“桌面已准备好”。

关闭 FileVault 才可能让 macOS 使用普通自动登录，但这会降低启动前保护，并且
需要用户等待完整解密。项目不会建议为了 Sidecar 关闭 FileVault，不会模拟按键，
也不会把“登录后提示音”描述为自动登录。

## Shortcuts 的边界

快捷指令只是用户触发器，不能从 iPad 端直接调用 Mac 的私有 Sidecar API。脚本
在快捷指令进程的上下文中运行，首次蓝牙或 Apple Events 授权可能属于快捷指令
或其子进程；这就是为什么首次无线设置要在有屏幕时完成。设置助手应把每个
授权的发起进程写清楚，并在动作前再次检查，不应在无屏幕状态下等待不可见弹窗。

设置助手提供“一键创建快捷指令”：它在本机生成并签名模板，依次打开两个导入
确认窗口，并等待用户点击“添加快捷指令”后再打开下一个。Shortcuts 没有公开的
静默导入 API，因此 App 不能替用户确认导入内容或“运行 Shell 脚本”权限。导入
模板声明 `QuickActions` 类型，确保快捷指令使用“快速操作”表面；完成导入后，设置助手会按当前 macOS 的本机用户映射尝试写入连接 `⌃⌥⌘S`、断开
`⌃⌥⌘D`；这是 best-effort 的系统偏好同步，不上传数据，也不绕过权限。安装器会
在应用自己的快捷指令状态目录记录工作流 ID，设置助手据此验证本机映射；它不会读取
受 macOS 隐私保护的 Shortcuts.sqlite。若系统版本拒绝该映射，用户仍需在快捷指令详情中手动录入。快捷指令没有必要获得辅助功能或屏幕录制，除非用户主动启用对应的
UI/采集功能。

首次运行每个“运行 Shell 脚本”动作时，Shortcuts 会分别显示系统确认（连接和断开各一次）。该确认不能静默授予，设置助手不会通过自动连接探测权限。用户应在有显示器时各运行一次并点击“允许”；脚本在真正启动后写入本地状态标记，助手据此继续显示引导或确认状态。

## 虚拟屏后端边界

项目内置 helper 使用 macOS 未公开的 `SLVirtualDisplay`/`CGVirtualDisplay` 运行时
接口。它必须在用户桌面会话中常驻，进程退出后 WindowServer 会释放虚拟屏；helper
只创建一个固定的最小屏，不提供 BetterDisplay 的高级参数。macOS 没有公开的“设为
主屏”接口，内置后端的布局调整只能尽力并必须通过显示拓扑再次验证。系统更新可能
改变接口或使创建失败，失败时应切换到 BetterDisplay。

## 权限申请流程

设置助手只在用户点击“申请 / 开启蓝牙”后创建 CoreBluetooth 管理器，触发 macOS
原生蓝牙隐私确认；返回 App 后会自动重新检查状态。已拒绝的授权会改为打开系统
设置，不会反复弹窗。辅助功能和屏幕录制不是当前连接路径的必需权限，因此 App
不会为了“通过检查”而要求用户开启它们；BetterDisplay 的额外权限由 BetterDisplay
自己申请。Handoff、Wi-Fi 和 iPad 端开关没有受支持的静默申请接口，仍需用户确认。

## 菜单栏和权限状态

关闭设置窗口不会退出 App。菜单栏场景保留一个由 WindowGroup 管理的打开动作，
因此“打开设置”和 Finder 的再次打开都能重新创建设置窗口。菜单栏不会在登录、
启动或状态刷新时自动连接 iPad。

蓝牙授权只在用户点击申请按钮时请求。状态刷新只读取 CoreBluetooth 授权状态和
本机无线电状态，不创建授权请求对象。App 会记录已尝试过申请的本地标记；如果
macOS 仍返回“未决定”，后续点击会打开“隐私与安全性 → 蓝牙”，而不是反复弹出
系统确认。开发副本如果从不同路径运行，或每次使用不同的代码签名身份，可能有不同
的 TCC 代码身份；这是 macOS 行为，不能由 App 绕过。

## BetterDisplay 的边界

BetterDisplay 是独立的第三方产品。Sidecar Auto 可以检测其安装路径、运行状态、
CLI 响应和虚拟屏是否在线，但不能从文件是否存在推断许可证或 Pro 能力。只有在
用户明确选择无显示器模式时才启动或调用它，并为每个 CLI 命令设置超时和结果验证。

BetterDisplay 的屏幕串流可能需要它自己的 Screen Recording；键盘亮度、音量
控制等功能可能需要它自己的 Accessibility。它们不是 Sidecar Auto 有线核心的
权限。设置助手应让 BetterDisplay 自己显示首次运行向导，不要用 Sidecar Auto
的授权状态替代第三方 App 的状态。

## 数据保护和诊断

- 配置写入 `~/.config/sidecar-auto/config` 时使用 `0600`；只允许保存 iPad 名称、
  可选 USB 序列号、虚拟屏名称和行为开关。
- 日志写入 `~/Library/Logs/sidecar-auto.log`，可能含设备名和系统错误；不上传，
  导出前删除用户名、设备名、USB 序列号、路径和账号信息。
- 不读取 Apple Account、钥匙串密码、FileVault 密码、TCC 数据库或 iPad 内容。
- 不使用 `curl | sh`，不从网络下载未验证的可执行文件；发布 App 应签名并公证，
  helper 也应使用固定 bundle 路径和签名。
- 不安装 root LaunchDaemon，不要求 sudo。登录后后台能力只使用当前用户的
  LaunchAgent/`SMAppService`，并提供状态、停用和卸载入口。

连接、断开、USB 检测和诊断脚本通过共享运行时解析器读取配置：只接受固定白名单
字段的整行 `KEY=value` 记录，不执行配置中的 shell 语句；配置必须是当前用户所有，
且不能带组或其他用户的写权限。未知字段、格式错误的记录和不安全权限会被忽略。
设置助手仍需在写入前严格校验字段，并保持 `0600` 权限，避免把路径或行为开关
交给不受信任的配置内容。

## 设置助手的安全流程

首次运行应按以下顺序工作：

1. 只读检查 macOS、当前登录会话、FileVault、工具版本、USB/显示器拓扑和
   BetterDisplay；不在后台偷偷连接 iPad。
2. 按“有线核心、无线核心、无显示器、可选 UI 恢复”分组显示状态。每项标记
   `已满足`、`需要用户操作`、`不可验证` 或 `可选`，提供“打开系统设置”和
   “重新检查”，而不是显示一个含义不明的总绿色勾。
3. 在有显示器的用户会话中完成首次 Bluetooth/TCC、BetterDisplay 和快捷指令
   设置。用户返回后再次读取授权状态；连接脚本也会在动作前复核硬前置并拒绝
   不安全或无法确认的请求。
4. 连接动作仍然保持单次并有超时边界；成功必须同时有 Sidecar 状态和在线
   显示画面证据。API 接受请求不等于已连接。
5. 设置完成后只保存本地非秘密配置，并提供脱敏诊断导出。

## 发布审核清单

- App 和所有 helper 使用固定 bundle ID、签名、公证和可验证的发布来源。
- `Info.plist` 只声明实际使用的用途说明（无线 CoreBluetooth 需要蓝牙说明）；
  不为当前核心预先申请 Screen Recording、Camera、Microphone、Local Network
  或 Full Disk Access。
- 默认关闭 Accessibility/Apple Events UI fallback 和任何自动重启 iPad 的选项。
- CI 检查不包含用户路径、设备名、日志、令牌或密码；脚本对外部命令设置超时。
- 在有显示器、无显示器、有线和无线场景分别记录“已验证”与“未验证”，不把
  某台 Mac 的结果宣传成所有硬件都能工作。
