import AppKit
@preconcurrency import CoreBluetooth
import SwiftUI

@main
struct SidecarAutoSetupApp: App {
    var body: some Scene {
        WindowGroup {
            SetupView()
                .frame(minWidth: 820, minHeight: 680)
        }
        .windowResizability(.contentSize)
    }
}

enum CheckState: Sendable {
    case good, warning, action, unknown

    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .action: return .blue
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .action: return "arrow.right.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum CheckAction: Sendable {
    case install, refresh, bluetooth, handoff
    case betterDisplay, shortcuts, installShortcuts, fileVault, loginOptions
}

/// Keeps a CoreBluetooth manager alive long enough for macOS to show the
/// first-run Bluetooth privacy prompt. Reading `CBManager.authorization` is
/// only a status check; it does not ask the user for access by itself.
private final class BluetoothPermissionRequester: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onState: @Sendable (CBManagerState) -> Void

    init(onState: @escaping @Sendable (CBManagerState) -> Void) {
        self.onState = onState
        super.init()
        manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let callback = onState
        DispatchQueue.main.async {
            callback(state)
        }
    }
}

enum VirtualDisplayBackend: String, CaseIterable, Identifiable, Sendable {
    case auto
    case builtin
    case betterdisplay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动选择（推荐）"
        case .builtin: return "项目内置虚拟屏（固定参数）"
        case .betterdisplay: return "BetterDisplay（高级参数）"
        }
    }
}

struct CheckItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: CheckState
    let action: CheckAction?
    let actionTitle: String?
}

struct SetupConfig: Sendable {
    var iPadName = "iPad"
    var usbSerial = ""
    var autoEnableHandoff = true
    var virtualDisplayName = "SidecarHeadlessFallback"
    var virtualDisplayBackend: VirtualDisplayBackend = .auto
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var checks: [CheckItem] = []
    @Published var config = SetupConfig()
    @Published var isRefreshing = false
    @Published var isInstalling = false
    @Published var message = "正在读取本机状态……"
    @Published var installerLog = ""
    @Published var isOperating = false
    @Published var operationLog = ""
    @Published var isRequestingPermission = false

    private let fileManager = FileManager.default
    private var bluetoothPermissionRequester: BluetoothPermissionRequester?
    private var activeObserver: NSObjectProtocol?

    init() {
        config = readConfig()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Returning from System Settings is the user's confirmation point.
            // Re-read TCC and radio state as soon as this window is active.
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    var goodCount: Int { checks.filter { $0.state == .good }.count }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        message = "正在读取本机状态……"
        let currentConfig = config
        let worker = Task.detached(priority: .userInitiated) {
            Self.makeChecks(config: currentConfig)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            self?.checks = result
            self?.isRefreshing = false
            self?.message = "状态已更新。需要用户确认的项目会显示操作按钮。"
        }
    }

    func saveConfig() {
        if let validationError = validateConfig(config) {
            message = validationError
            return
        }
        do {
            try writeConfig(config)
            message = "配置已保存到 ~/.config/sidecar-auto/config。"
            refresh()
        } catch {
            message = "配置保存失败：\(error.localizedDescription)"
        }
    }

    func perform(_ action: CheckAction) {
        switch action {
        case .install:
            installRuntime()
        case .refresh:
            refresh()
        case .bluetooth:
            requestBluetoothAccess()
        case .handoff:
            openHandoffSettings()
        case .betterDisplay:
            if let app = betterDisplayURL() {
                NSWorkspace.shared.open(app)
            } else {
                NSWorkspace.shared.open(URL(string: "https://github.com/waydabber/BetterDisplay")!)
            }
        case .shortcuts:
            let appURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
            if fileManager.fileExists(atPath: appURL.path) {
                NSWorkspace.shared.open(appURL)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Shortcuts.app"))
            }
        case .installShortcuts:
            installShortcuts()
        case .fileVault:
            openSettings("x-apple.systempreferences:com.apple.preference.security?FileVault")
            message = "文件保险箱设置用于查看启动保护；使用 Sidecar 不要求关闭它。"
        case .loginOptions:
            openSettings("x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
            message = "已打开“用户与群组”。请查看“自动登录为”；文件保险箱开启时 macOS 会禁用此选项。"
        }
    }

    /// Requests Bluetooth privacy access from the app itself. If access was
    /// already decided, the same button prepares the radio when possible and
    /// only opens System Settings for the cases macOS cannot change silently.
    func requestBluetoothAccess() {
        guard !isRequestingPermission else { return }
        if #available(macOS 10.15, *) {
            switch CBManager.authorization {
            case .notDetermined:
                isRequestingPermission = true
                message = "正在申请蓝牙权限，请在系统提示中点击“允许”……"
                bluetoothPermissionRequester = BluetoothPermissionRequester { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.bluetoothRequestFinished(state)
                    }
                }
                return
            case .denied, .restricted:
                openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                message = "蓝牙权限已被系统拒绝，请在系统设置中打开 Sidecar Auto；返回后会自动重新检查。"
                return
            case .allowedAlways:
                break
            @unknown default:
                break
            }
        }

        prepareBluetoothRadio()
    }

    private func bluetoothRequestFinished(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            message = "蓝牙权限已确认，正在检查无线电状态……"
            isRequestingPermission = false
            bluetoothPermissionRequester = nil
            prepareBluetoothRadio()
        case .unauthorized:
            isRequestingPermission = false
            bluetoothPermissionRequester = nil
            message = "蓝牙权限未允许。请在系统提示中选择允许，或到系统设置中开启。"
            refresh()
        case .poweredOff:
            isRequestingPermission = false
            bluetoothPermissionRequester = nil
            message = "蓝牙权限已确认，但蓝牙无线电处于关闭状态，正在尝试开启……"
            prepareBluetoothRadio()
        case .resetting:
            message = "正在初始化蓝牙权限，请稍候……"
        case .unsupported, .unknown:
            isRequestingPermission = false
            bluetoothPermissionRequester = nil
            message = "无法确认蓝牙状态，请打开系统设置检查。"
            refresh()
        @unknown default:
            isRequestingPermission = false
            bluetoothPermissionRequester = nil
            message = "无法确认蓝牙状态，请打开系统设置检查。"
            refresh()
        }
    }

    private func prepareBluetoothRadio() {
        let helper = "\(NSHomeDirectory())/.local/bin/sidecar-bluetooth-radio"
        guard fileManager.isExecutableFile(atPath: helper) else {
            openSettings("x-apple.systempreferences:com.apple.Bluetooth-Settings.extension")
            message = "蓝牙权限已确认，但尚未安装无线电辅助程序。请先点击“安装 / 修复”，或在系统设置中打开蓝牙。"
            refresh()
            return
        }

        isRequestingPermission = true
        message = "蓝牙权限已确认，正在自动开启蓝牙……"
        let worker = Task.detached(priority: .userInitiated) {
            Self.execute(executable: helper, arguments: ["prepare"])
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.isRequestingPermission = false
            if result.status == 0 {
                self.message = "蓝牙已开启，正在重新检查环境……"
            } else {
                self.message = "蓝牙权限已确认，但自动开启失败；请在系统设置中打开蓝牙。"
            }
            self.refresh()
        }
    }

    /// Connects once through the existing serialized controller. This action
    /// is never started by a status refresh or at application launch.
    func connect() {
        runOperation(
            executable: "\(NSHomeDirectory())/.local/bin/sidecar-connect-once.sh",
            arguments: ["auto"],
            startMessage: "正在执行一次 Sidecar 连接……"
        )
    }

    /// Disconnects once through the existing controller. The user must click
    /// this button; the setup app never disconnects an existing session while
    /// checking status.
    func disconnect() {
        runOperation(
            executable: "\(NSHomeDirectory())/.local/bin/sidecar-disconnect-once.sh",
            arguments: [],
            startMessage: "正在执行一次 Sidecar 断开……"
        )
    }

    private func runOperation(executable: String, arguments: [String], startMessage: String) {
        guard !isOperating else { return }
        guard fileManager.isExecutableFile(atPath: executable) else {
            operationLog = "找不到可执行文件：\(executable)\n请先点击“安装 / 修复”。"
            message = "运行时工具尚未安装。"
            return
        }

        isOperating = true
        operationLog = "\(startMessage)\n"
        message = startMessage
        let worker = Task.detached(priority: .userInitiated) {
            Self.execute(executable: executable, arguments: arguments)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.operationLog += result.output
            self.isOperating = false
            self.message = result.status == 0
                ? "操作完成；请确认 iPad 是否出现随航画面。"
                : "操作失败（退出码 \(result.status)）；请查看输出和诊断。"
            self.refresh()
        }
    }

    /// Generate and import the two user-facing Shortcuts. macOS requires the
    /// user to confirm each imported shortcut; the helper opens the first
    /// review sheet and waits for that confirmation before opening the second.
    private func installShortcuts() {
        guard !isInstalling && !isOperating else { return }
        let installed = "\(NSHomeDirectory())/.local/bin/install-sidecar-shortcuts.sh"
        guard let resources = Bundle.main.resourceURL, Self.hasBundledRuntime(resources: resources) else {
            message = "此 App 缺少安装资源，请重新下载完整版本。"
            return
        }
        isInstalling = true
        installerLog = "正在准备“连接 Sidecar”和“断开 Sidecar”快捷指令……\n"
        message = "正在打开快捷指令导入确认；请按提示点击“添加快捷指令”。"
        let worker = Task.detached(priority: .userInitiated) {
            // A new user should not have to install tools in a separate step.
            // The runtime installer preserves any existing connection config.
            let install = Self.installBundledRuntime(resources: resources)
            guard install.status == 0 else {
                return ProcessResult(status: install.status, output: install.output)
            }
            let imported = Self.execute(executable: installed, arguments: [])
            return ProcessResult(status: imported.status, output: install.output + imported.output)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.installerLog += result.output
            self.isInstalling = false
            self.message = result.status == 0
                ? "快捷指令导入流程已完成；可在快捷指令详情中设置键盘快捷键。"
                : "快捷指令导入失败（退出码 \(result.status)）；请查看日志。"
            self.refresh()
        }
    }

    private func installRuntime() {
        guard !isInstalling else { return }
        guard let resources = Bundle.main.resourceURL else {
            message = "此 App 没有包含安装资源，请重新下载完整版本。"
            return
        }
        let hasPayload = Self.hasBundledRuntime(resources: resources)
        guard hasPayload else {
            message = "此 App 没有包含运行时资源，请重新下载完整版本。"
            return
        }

        isInstalling = true
        installerLog = "开始安装或修复 Sidecar Auto……\n"
        message = "安装器正在运行。期间不会连接 iPad。"
        let worker = Task.detached(priority: .userInitiated) {
            Self.installBundledRuntime(resources: resources)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            self?.installerLog += result.output
            self?.isInstalling = false
            self?.message = result.status == 0
                ? "安装完成。请继续完成下面的权限和快捷指令步骤。"
                : "安装失败，请查看下方日志并按提示处理。"
            if result.status == 0 { self?.refresh() }
        }
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
        message = "已打开系统设置。完成授权后返回此窗口并点击“重新检查”。"
    }

    /// Open the dedicated Handoff pane used by current macOS releases.  The
    /// old `com.apple.preference.general?Handoff` URL opens the General page
    /// but does not select the Continuity toggle on macOS 13 and later, which
    /// made the previous button look as if it had done nothing.  Keep the old
    /// URL as a compatibility fallback for older System Settings builds.
    private func openHandoffSettings() {
        let current = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
        if NSWorkspace.shared.open(current) {
            message = "已打开“隔空投送与连续互通”。请开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”，完成后返回本窗口。"
            return
        }
        if let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.general?Handoff"),
           NSWorkspace.shared.open(legacy) {
            message = "已打开系统设置。请在“通用”中找到“隔空投送与接力/连续互通”，开启“接力”后返回本窗口。"
        } else {
            message = "无法自动打开接力设置。请手动进入：系统设置 → 通用 → 隔空投送与连续互通（旧版叫“隔空投送与接力”）。"
        }
    }

    private func betterDisplayURL() -> URL? {
        let candidates = [
            "/Applications/BetterDisplay.app",
            "\(NSHomeDirectory())/Applications/BetterDisplay.app"
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private func readConfig() -> SetupConfig {
        var value = SetupConfig()
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/sidecar-auto/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return value }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            let parsed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "IPAD_NAME": value.iPadName = parsed
            case "IPAD_USB_SERIAL_NUMBER": value.usbSerial = parsed
            case "AUTO_ENABLE_HANDOFF": value.autoEnableHandoff = parsed != "0"
            case "VIRTUAL_DISPLAY_NAME": value.virtualDisplayName = parsed
            case "VIRTUAL_DISPLAY_BACKEND": value.virtualDisplayBackend = VirtualDisplayBackend(rawValue: parsed) ?? .auto
            default: break
            }
        }
        return value
    }

    private func writeConfig(_ value: SetupConfig) throws {
        let directory = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/sidecar-auto", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config")
        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let replacements = [
            "IPAD_NAME": shellQuote(value.iPadName),
            "IPAD_USB_SERIAL_NUMBER": value.usbSerial.isEmpty ? "" : shellQuote(value.usbSerial),
            "AUTO_ENABLE_HANDOFF": value.autoEnableHandoff ? "1" : "0",
            "VIRTUAL_DISPLAY_NAME": shellQuote(value.virtualDisplayName),
            "VIRTUAL_DISPLAY_BACKEND": shellQuote(value.virtualDisplayBackend.rawValue)
        ]
        for (key, replacement) in replacements {
            var found = false
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("# \(key)=") else { return line }
                found = true
                return "\(key)=\(replacement)"
            }
            if !found { lines.append("\(key)=\(replacement)") }
        }
        if lines.isEmpty {
            lines = [
                "# Managed by Sidecar Auto Setup",
                "IPAD_NAME=\(shellQuote(value.iPadName))",
                "IPAD_USB_SERIAL_NUMBER=\(value.usbSerial.isEmpty ? "" : shellQuote(value.usbSerial))",
                "AUTO_ENABLE_HANDOFF=\(value.autoEnableHandoff ? "1" : "0")",
                "VIRTUAL_DISPLAY_NAME=\(shellQuote(value.virtualDisplayName))",
                "VIRTUAL_DISPLAY_BACKEND=\(shellQuote(value.virtualDisplayBackend.rawValue))"
            ]
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func validateConfig(_ value: SetupConfig) -> String? {
        if value.iPadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写 iPad 名称后再保存。"
        }
        if value.iPadName.count > 200 || value.usbSerial.count > 200 ||
            value.virtualDisplayName.count > 200 {
            return "名称或序列号过长，请控制在 200 个字符以内。"
        }
        let hasControlCharacter: (String) -> Bool = { text in
            text.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || scalar.value == 0x7f
            }
        }
        if hasControlCharacter(value.iPadName) || hasControlCharacter(value.usbSerial) ||
            hasControlCharacter(value.virtualDisplayName) {
            return "名称或序列号不能包含换行或控制字符。"
        }
        return nil
    }

    private nonisolated static func makeChecks(config: SetupConfig) -> [CheckItem] {
        let runtime = runtimeStatus()
        let mac = ProcessInfo.processInfo.operatingSystemVersion
        let macOK = mac.majorVersion >= 13
        let wifi = wifiStatus()
        let bluetooth = bluetoothStatus()
        let handoff = handoffStatus()
        let betterDisplay = betterDisplayStatus(backend: config.virtualDisplayBackend)
        let builtinVirtual = builtinVirtualDisplayStatus()
        let configExists = FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/.config/sidecar-auto/config")
        let shortcuts = shortcutsStatus()
        let fileVault = fileVaultStatus()
        let autoLogin = autoLoginStatus(fileVaultEnabled: fileVault.enabled)

        return [
            CheckItem(id: "mac", title: "macOS 版本", detail: macOK
                      ? "macOS \(mac.majorVersion).\(mac.minorVersion)，满足 macOS 13+"
                      : "当前 macOS 版本过低，需要 macOS 13 或更高版本",
                      state: macOK ? .good : .warning, action: .refresh, actionTitle: "重新检查"),
            CheckItem(id: "runtime", title: "Sidecar Auto 工具", detail: runtime.detail,
                      state: runtime.ok ? .good : .action, action: runtime.ok ? .refresh : .install,
                      actionTitle: runtime.ok ? "重新检查" : "安装 / 修复"),
            CheckItem(id: "config", title: "目标 iPad 配置", detail: configExists
                      ? "已找到配置，目标名称：\(config.iPadName)"
                      : "还没有配置文件，保存下面的配置即可创建",
                      state: configExists ? .good : .action, action: .refresh, actionTitle: "重新检查"),
            CheckItem(id: "wifi", title: "Wi-Fi", detail: wifi.detail,
                      state: wifi.ok ? .good : .warning, action: .refresh, actionTitle: "重新检查"),
            CheckItem(id: "bluetooth", title: "蓝牙", detail: bluetooth.detail,
                      state: bluetooth.ok ? .good : .action, action: .bluetooth, actionTitle: "申请 / 开启"),
            CheckItem(id: "handoff", title: "Mac 接力（Handoff）", detail: handoff.detail,
                      // The Mac preference values are only a hint; macOS does
                      // not expose a supported runtime probe and the iPad side
                      // is never observable from this app. Keep a confirmed
                      // Mac preference in the neutral state rather than
                      // claiming that wireless Sidecar is ready.
                      state: handoff.ok ? .unknown : .warning,
                      action: .handoff, actionTitle: "打开 Mac 接力设置"),
            CheckItem(id: "accessibility", title: "辅助功能权限", detail:
                      "当前连接路径不需要辅助功能权限；只有启用需要 UI 自动化的可选功能时才需要手动授权。",
                      state: .good, action: nil, actionTitle: nil),
            CheckItem(id: "screen", title: "屏幕录制权限", detail:
                      "当前连接和显示状态检查不需要屏幕录制权限；BetterDisplay 如有额外要求会在其应用内提示。",
                      state: .good, action: nil, actionTitle: nil),
            CheckItem(id: "betterdisplay", title: "BetterDisplay", detail: betterDisplay.detail,
                      state: betterDisplay.ok ? .good : .action, action: .betterDisplay, actionTitle: "打开 BetterDisplay"),
            CheckItem(id: "builtin-virtual", title: "项目内置虚拟屏", detail: builtinVirtual.detail,
                      state: builtinVirtual.ok ? .good : .action,
                      action: builtinVirtual.ok ? .refresh : .install,
                      actionTitle: builtinVirtual.ok ? "重新检查" : "安装 / 修复"),
            CheckItem(id: "shortcuts", title: "macOS 快捷指令", detail: shortcuts.detail,
                      state: shortcuts.ok ? .good : .action,
                      action: shortcuts.ok ? .shortcuts : .installShortcuts,
                      actionTitle: shortcuts.ok ? "打开快捷指令" : "一键配置快捷指令"),
            CheckItem(id: "filevault", title: "文件保险箱（FileVault）", detail: fileVault.detail,
                      state: fileVault.state, action: .fileVault, actionTitle: "查看文件保险箱"),
            CheckItem(id: "autologin", title: "macOS 自动登录", detail: autoLogin.detail,
                      state: autoLogin.state, action: .loginOptions, actionTitle: "查看自动登录选项")
        ]
    }

    /// Run a read-only probe with the same bounded timeout used by the shell
    /// diagnostics. A stuck system_profiler/networksetup invocation must not
    /// freeze the SwiftUI status page.
    private nonisolated static func command(_ path: String, _ arguments: [String] = [], timeout: Int = 5) -> String {
        let process = Process()
        let pipe = Pipe()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            return "COMMAND_UNAVAILABLE\t/usr/bin/perl is required for bounded probes\n"
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "alarm shift; exec @ARGV", String(max(1, timeout)), path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            // Read while the bounded Perl wrapper is running so a verbose
            // system_profiler result cannot fill the pipe and deadlock the
            // status refresh before the alarm can fire.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private nonisolated static func commandExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private nonisolated static func runtimeStatus() -> (ok: Bool, detail: String) {
        let bin = "\(NSHomeDirectory())/.local/bin"
        let names = [
            "sidecarctl",
            "display-state",
            "sidecar-bluetooth-radio",
            "sidecar-virtual-display",
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh",
            "install-sidecar-shortcuts.sh"
        ]
        let missing = names.filter { !commandExists("\(bin)/\($0)") }
        if missing.isEmpty { return (true, "核心工具已安装到 ~/.local/bin") }
        return (false, "缺少：\(missing.joined(separator: "、"))")
    }

    private nonisolated static func wifiStatus() -> (ok: Bool, detail: String) {
        let output = command("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = output.split(separator: "\n").map(String.init)
        var device = "en0"
        for index in lines.indices where lines[index].contains("Hardware Port: Wi-Fi") {
            if index + 1 < lines.count, let value = lines[index + 1].split(separator: ":").last {
                device = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let status = command("/usr/sbin/networksetup", ["-getairportpower", device])
        let on = status.localizedCaseInsensitiveContains("On")
        return (on, on ? "Mac Wi-Fi 已开启（接口 \(device)）" : "Mac Wi-Fi 未开启，请先打开 Wi-Fi")
    }

    private nonisolated static func bluetoothStatus() -> (ok: Bool, detail: String) {
        let output = command("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        let lowercased = output.lowercased()
        let radioOn = lowercased.contains("attrib_on") ||
            lowercased.contains("state: on") ||
            lowercased.contains("bluetooth power: on")
        let authorization: String
        let authorized: Bool
        if #available(macOS 10.15, *) {
            switch CBManager.authorization {
            case .allowedAlways:
                authorization = "App 的蓝牙隐私授权已允许"
                authorized = true
            case .denied:
                authorization = "App 的蓝牙隐私授权已拒绝"
                authorized = false
            case .restricted:
                authorization = "App 的蓝牙隐私授权受到系统限制"
                authorized = false
            case .notDetermined:
                authorization = "尚未申请蓝牙隐私授权；点击“申请 / 开启”后由 macOS 显示确认"
                authorized = false
            @unknown default:
                authorization = "无法识别 App 的蓝牙隐私授权状态"
                authorized = false
            }
        } else {
            authorization = "当前 macOS 无法读取蓝牙隐私授权状态"
            authorized = false
        }
        let detail: String
        if radioOn && authorized {
            detail = "Mac 蓝牙无线电已开启；\(authorization)"
        } else if !radioOn {
            detail = "Mac 蓝牙无线电未开启或状态无法读取；\(authorization)"
        } else {
            detail = "Mac 蓝牙无线电已开启；\(authorization)"
        }
        return (radioOn && authorized, detail)
    }

    private nonisolated static func handoffStatus() -> (ok: Bool, detail: String) {
        // These keys are private implementation details and are therefore
        // only a local hint. They do not prove the Continuity daemon is ready
        // and they say nothing about the iPad's setting.
        let advertising = command("/usr/bin/defaults",
                                  ["read", "com.apple.coreservices.useractivityd", "ActivityAdvertisingAllowed"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let receiving = command("/usr/bin/defaults",
                                ["read", "com.apple.coreservices.useractivityd", "ActivityReceivingAllowed"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let macHint = [advertising, receiving].allSatisfy {
            ["1", "true", "yes", "on"].contains($0.lowercased())
        }
        let macText = macHint
            ? "Mac 侧接力偏好已开启（运行时仍需 macOS 自己确认）"
            : "Mac 侧接力偏好未同时开启或无法读取"
        return (macHint, "\(macText)。请确认两端都已开启接力。Mac：系统设置 → 通用 → 隔空投送与连续互通（旧版叫“隔空投送与接力”）→ 开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”；iPad：设置 → 通用 → 隔空播放与接力 → 接力。App 无法远程读取或修改 iPad 端开关")
    }

    private nonisolated static func betterDisplayStatus(backend: VirtualDisplayBackend = .auto) -> (ok: Bool, detail: String) {
        let candidates = [
            "/Applications/BetterDisplay.app",
            "\(NSHomeDirectory())/Applications/BetterDisplay.app"
        ]
        let app = candidates.first { FileManager.default.fileExists(atPath: $0) }
        let cli = command("/usr/bin/which", ["betterdisplaycli"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledCLI = app.map {
            FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/BetterDisplay")
        } ?? false
        if backend == .builtin {
            return (true, "当前使用项目内置虚拟屏；BetterDisplay 仅用于可选高级配置")
        }
        if backend == .auto && app == nil && cli.isEmpty {
            return (true, "当前为自动选择：优先使用项目内置虚拟屏，BetterDisplay 仅作为后备")
        }
        if app != nil && (!cli.isEmpty || bundledCLI) {
            return (true, "已发现 BetterDisplay；虚拟屏创建和 Pro/试用资格仍需在应用内确认")
        }
        if app != nil {
            return (false, "已发现 BetterDisplay.app，但没有发现 CLI；打开应用并完成首次设置后重新检查")
        }
        if !cli.isEmpty {
            return (true, "已发现 BetterDisplay CLI；虚拟屏创建和 Pro/试用资格仍需在应用内确认")
        }
        return (false, "未发现 BetterDisplay；项目内置虚拟屏可独立工作，BetterDisplay 仅用于高级后端")
    }

    private nonisolated static func builtinVirtualDisplayStatus() -> (ok: Bool, detail: String) {
        let path = "\(NSHomeDirectory())/.local/bin/sidecar-virtual-display"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (false, "项目内置虚拟屏 helper 尚未安装；点击“安装 / 修复”即可安装")
        }
        let output = command(path, ["status"])
        if output.contains("online=1") {
            return (true, "项目内置固定虚拟屏在线（1920×1080，60Hz）")
        }
        return (true, "项目内置虚拟屏可用，连接时按需创建；当前未占用显示拓扑")
    }

    private nonisolated static func shortcutsStatus() -> (ok: Bool, detail: String) {
        let path = "/System/Applications/Shortcuts.app"
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "系统没有找到 macOS 快捷指令 App")
        }
        let output = command("/usr/bin/shortcuts", ["list"], timeout: 5)
        let names = Set(output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let connect = names.contains("连接 Sidecar")
        let disconnect = names.contains("断开 Sidecar")
        if connect && disconnect {
            return (true, "已找到“连接 Sidecar”和“断开 Sidecar”；可在快捷指令详情中设置键盘快捷键")
        }
        if connect || disconnect {
            let missing = connect ? "断开 Sidecar" : "连接 Sidecar"
            return (false, "已找到一个快捷指令，还缺少“\(missing)”；点击“一键创建快捷指令”继续")
        }
        return (false, "尚未创建“连接 Sidecar”和“断开 Sidecar”；点击“一键创建快捷指令”导入")
    }

    private nonisolated static func fileVaultStatus() ->
        (enabled: Bool, state: CheckState, detail: String) {
        let output = command("/usr/bin/fdesetup", ["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return (false, .unknown,
                    "无法读取文件保险箱状态；请打开系统设置确认。")
        }
        if output.localizedCaseInsensitiveContains("on") {
            return (true, .warning,
                    "文件保险箱已开启；冷启动必须先在解密界面输入密码。普通 App 无法代办，也不会保存或盲打密码。")
        }
        if output.localizedCaseInsensitiveContains("off") {
            return (false, .warning,
                    "文件保险箱未开启；自动登录是否可用仍由 macOS 的登录选项和组织策略决定。关闭它会降低启动前保护。")
        }
        return (false, .unknown,
                "\(output)；冷启动登录仍由 macOS 安全策略控制。")
    }

    private nonisolated static func autoLoginStatus(fileVaultEnabled: Bool) ->
        (state: CheckState, detail: String) {
        if fileVaultEnabled {
            return (.warning,
                    "文件保险箱开启时，macOS 会禁用自动登录。请先在“用户与群组”查看系统显示的状态；App 不会建议关闭启动保护。")
        }
        return (.unknown,
                "自动登录由 macOS 的“用户与群组”设置、账户密码和组织策略决定；App 只能打开设置页，不能保存或输入密码。")
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    private nonisolated static func execute(executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return ProcessResult(status: process.terminationStatus, output: output)
        } catch {
            return ProcessResult(status: 127, output: "无法启动 \(executable)：\(error.localizedDescription)\n")
        }
    }

    private struct InstallerResult: Sendable {
        let status: Int32
        let output: String
    }

    /// The signed app release carries already-built helpers in
    /// `Contents/Resources/bin` and the shell entry points in
    /// `Contents/Resources/scripts`. Copying those files avoids requiring
    /// Xcode Command Line Tools on a non-developer user's Mac. The source
    /// installer remains available separately for developers.
    private nonisolated static func hasBundledRuntime(resources: URL) -> Bool {
        let binaries = [
            "sidecarctl",
            "display-state",
            "sidecar-bluetooth-radio",
            "sidecar-virtual-display"
        ]
        let scripts = [
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh",
            "install-sidecar-shortcuts.sh"
        ]
        let fileManager = FileManager.default
        return binaries.allSatisfy {
            fileManager.isExecutableFile(
                atPath: resources.appendingPathComponent("bin/\($0)").path)
        } && scripts.allSatisfy {
            fileManager.isExecutableFile(
                atPath: resources.appendingPathComponent("scripts/\($0)").path)
        }
    }

    private nonisolated static func installBundledRuntime(resources: URL) -> InstallerResult {
        let fileManager = FileManager.default
        let binaries = [
            "sidecarctl",
            "display-state",
            "sidecar-bluetooth-radio",
            "sidecar-virtual-display"
        ]
        let scripts = [
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh",
            "install-sidecar-shortcuts.sh"
        ]
        let binDirectory = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin", isDirectory: true)
        let configDirectory = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/sidecar-auto", isDirectory: true)
        let stage = binDirectory.appendingPathComponent(".sidecar-auto-install-\(UUID().uuidString)", isDirectory: true)
        var output = ""
        do {
            let sources = binaries.map {
                (resources.appendingPathComponent("bin/\($0)"), $0)
            } + scripts.map {
                (resources.appendingPathComponent("scripts/\($0)"), $0)
            }
            let missing = sources.filter {
                !fileManager.isExecutableFile(atPath: $0.0.path)
            }.map { $0.1 }
            guard missing.isEmpty else {
                return InstallerResult(
                    status: 2,
                    output: "运行时资源不完整，缺少：\(missing.joined(separator: ", "))\n")
            }

            try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stage) }

            for (source, name) in sources {
                let destination = stage.appendingPathComponent(name)
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }

            for (_, name) in sources {
                let staged = stage.appendingPathComponent(name)
                let destination = binDirectory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: destination)
                }
            }

            let config = configDirectory.appendingPathComponent("config")
            if !fileManager.fileExists(atPath: config.path) {
                let bundledConfig = resources.appendingPathComponent("config/config.example")
                if fileManager.fileExists(atPath: bundledConfig.path) {
                    try fileManager.copyItem(at: bundledConfig, to: config)
                } else {
                    let defaults = """
                    # Managed by Sidecar Auto Setup.
                    IPAD_NAME=\"iPad\"
                    AUTO_ENABLE_HANDOFF=1
                    VIRTUAL_DISPLAY_BACKEND=\"auto\"
                    VIRTUAL_DISPLAY_NAME=\"SidecarHeadlessFallback\"
                    """
                    try defaults.write(to: config, atomically: true, encoding: .utf8)
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
                output += "已创建配置：\(config.path)\n"
            } else {
                output += "已保留现有配置：\(config.path)\n"
            }
            output += "已安装运行时到 \(binDirectory.path)\n"
            return InstallerResult(status: 0, output: output)
        } catch {
            return InstallerResult(
                status: 1,
                output: output + "安装运行时失败：\(error.localizedDescription)\n")
        }
    }

}


private enum SetupSection: String, CaseIterable, Identifiable {
    case overview, config, checks, test
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .config: return "连接设置"
        case .checks: return "环境检查"
        case .test: return "手动测试"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "rectangle.3.group.fill"
        case .config: return "slider.horizontal.3"
        case .checks: return "checkmark.shield.fill"
        case .test: return "play.circle.fill"
        }
    }
}

private struct SetupView: View {
    @StateObject private var model = SetupModel()
    @State private var section: SetupSection = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                topBar
                Divider()
                ScrollView {
                    page.frame(maxWidth: 900, alignment: .leading)
                        .padding(.horizontal, 36).padding(.vertical, 30)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 300)
        .tint(Color.sidecarBlue)
        .frame(minWidth: 900, minHeight: 700)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AppMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidecar Auto").font(.headline)
                    Text("设置助手").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 22)
            Text("设置向导").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 8)
            List(SetupSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }.listStyle(.sidebar)
            Spacer(minLength: 12)
            sidebarStatus
        }
        .frame(minWidth: 250, idealWidth: 270, maxWidth: 300)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var sidebarStatus: some View {
        let total = model.checks.count
        let passed = model.goodCount
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("准备状态").font(.caption.weight(.semibold))
                Spacer()
                Text(total == 0 ? "读取中" : "\(passed)/\(total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.sidecarBlue)
            }
            ProgressView(value: total == 0 ? 0 : Double(passed) / Double(total)).tint(Color.sidecarBlue)
            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .padding(14)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.bold())
                Text(section == .overview ? "让 Mac 在没有显示器时也能可靠连接 iPad。" : model.message)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).disabled(model.isRefreshing || model.isInstalling)
        }
        .padding(.horizontal, 36).padding(.vertical, 17)
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .overview: overviewPage
        case .config: configPage
        case .checks: checksPage
        case .test: testPage
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heroCard
            HStack(alignment: .top, spacing: 16) { overviewStatusCard; nextStepCard }
            quickActions
        }
    }

    private var heroCard: some View {
        HStack(spacing: 18) {
            AppMark(size: 68)
            VStack(alignment: .leading, spacing: 7) {
                Text("把 iPad 变成你的第二块屏幕").font(.title.bold())
                Text("先完成一次配置。之后只需按快捷键，Sidecar Auto 会根据数据线和网络状态选择合适的连接方式。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(24)
        .background(LinearGradient(colors: [Color.sidecarBlue.opacity(0.18), Color.sidecarBlue.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.sidecarBlue.opacity(0.18), lineWidth: 1))
    }

    private var overviewStatusCard: some View {
        let total = model.checks.count
        let passed = model.goodCount
        return Panel {
            PanelTitle(title: "当前状态", subtitle: "只读检查，不会自动连接 iPad。", symbol: "checkmark.shield")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(total == 0 ? "—" : "\(passed)")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Color.sidecarBlue)
                Text(total == 0 ? "正在检查" : "项已通过").foregroundStyle(.secondary)
            }
            ProgressView(value: total == 0 ? 0 : Double(passed) / Double(total)).tint(Color.sidecarBlue)
            Text("未通过的项目会在“环境检查”中显示处理按钮。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nextStepCard: some View {
        Panel {
            PanelTitle(title: "建议步骤", subtitle: "按顺序完成即可。", symbol: "list.number")
            VStack(alignment: .leading, spacing: 11) {
                StepLine(number: 1, title: "填写 iPad 名称", done: !model.config.iPadName.isEmpty)
                StepLine(number: 2, title: "保存连接设置", done: model.checks.contains(where: { $0.id == "config" && $0.state == .good }))
                StepLine(number: 3, title: "完成环境检查", done: model.goodCount > 3)
                StepLine(number: 4, title: "按需手动测试", done: !model.operationLog.isEmpty)
            }
        }
    }

    private var quickActions: some View {
        Panel {
            PanelTitle(title: "常用操作", subtitle: "连接、断开和配置操作都只在你点击后执行。", symbol: "bolt.fill")
            HStack(spacing: 12) {
                Button { section = .config } label: { Label("编辑连接设置", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderedProminent)
                if model.checks.first(where: { $0.id == "runtime" && $0.state != .good }) != nil {
                    Button { model.perform(.install) } label: { Label("安装 / 修复工具", systemImage: "arrow.down.app") }
                        .buttonStyle(.bordered)
                        .disabled(model.isInstalling)
                }
                Button { section = .checks } label: { Label("查看环境检查", systemImage: "checkmark.shield") }
                    .buttonStyle(.bordered)
                if model.checks.first(where: { $0.id == "shortcuts" && $0.state != .good }) != nil {
                    Button { model.perform(.installShortcuts) } label: {
                        Label("一键配置快捷指令", systemImage: "keyboard.badge.ellipsis")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstalling || model.isOperating)
                }
                Button { section = .test } label: { Label("打开手动测试", systemImage: "play.circle") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var configPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageIntro(text: "这些设置只保存在本机。连接时会优先识别 USB 数据线，未连接数据线时再使用无线 Sidecar。")
            Panel {
                PanelTitle(title: "目标设备", subtitle: "名称需要与 macOS 显示的 iPad 名称一致。", symbol: "ipad")
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("iPad 名称") {
                        TextField("例如：我的 iPad", text: $model.config.iPadName)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    }
                    LabeledContent("USB 序列号") {
                        TextField("可选，用于多台 iPad 时精确匹配", text: $model.config.usbSerial)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    }
                }
            }
            Panel {
                PanelTitle(title: "无显示器虚拟屏", subtitle: "拔掉显示器后，连接时按需创建，不会一直占用屏幕。", symbol: "rectangle.on.rectangle")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("使用方案", selection: $model.config.virtualDisplayBackend) {
                        ForEach(VirtualDisplayBackend.allCases) { backend in Text(backend.title).tag(backend) }
                    }.pickerStyle(.radioGroup)
                    if model.config.virtualDisplayBackend != .builtin {
                        LabeledContent("BetterDisplay 屏幕名称") {
                            TextField("可选", text: $model.config.virtualDisplayName)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        }
                    }
                    Text("项目内置方案固定为 1920×1080、60Hz；BetterDisplay 支持更多分辨率和布局参数。内置方案依赖 macOS 的系统接口，系统升级后如遇兼容问题可切换方案。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                PanelTitle(title: "无线连接", subtitle: "不会在 App 启动或刷新时抢占 iPad。", symbol: "wifi")
                Toggle("连接无线 Sidecar 前尝试开启 Mac 侧接力", isOn: $model.config.autoEnableHandoff)
                Text("请在两端手动确认接力已开启。Mac：系统设置 → 通用 → 隔空投送与连续互通（旧版叫“隔空投送与接力”）→ 开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”；iPad：设置 → 通用 → 隔空播放与接力 → 接力。此 App 不能远程读取或修改 iPad 设置。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button { model.saveConfig() } label: { Label("保存设置", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Text("保存到 ~/.config/sidecar-auto/config").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var checksPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageIntro(text: "这里的检查都是只读的。能由 App 发起的蓝牙授权会显示系统确认；返回本页后状态会自动刷新。")
            Panel {
                PanelTitle(title: "权限助手", subtitle: "只申请连接真正需要的权限。", symbol: "hand.raised.fill")
                HStack(spacing: 12) {
                    Text("当前连接路径只需要蓝牙隐私授权。辅助功能和屏幕录制对本项目不是必需项，BetterDisplay 如有额外要求会由它自己申请。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        model.requestBluetoothAccess()
                    } label: {
                        Label(model.isRequestingPermission ? "申请中…" : "申请 / 开启蓝牙", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRequestingPermission || model.isInstalling || model.isOperating)
                }
            }
            if model.checks.isEmpty {
                Panel { HStack { ProgressView(); Text("正在读取本机状态……").foregroundStyle(.secondary) } }
            } else {
                VStack(spacing: 9) {
                    ForEach(model.checks) { item in CheckRow(item: item) { action in model.perform(action) } }
                }
            }
            if !model.installerLog.isEmpty { installerPanel }
        }
    }

    private var testPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageIntro(text: "连接和断开只会在你点击按钮后执行一次。测试时请确保 iPad 已解锁，并准备好接受 Sidecar。")
            Panel {
                PanelTitle(title: "连接控制", subtitle: model.isOperating ? "正在执行，请稍候……" : "不会设置后台自动抢占。", symbol: "rectangle.connected.to.line.below")
                HStack(spacing: 12) {
                    Button { model.connect() } label: { Label("连接一次", systemImage: "rectangle.connected.to.line.below") }
                        .buttonStyle(.borderedProminent).disabled(model.isOperating || model.isInstalling)
                    Button { model.disconnect() } label: { Label("断开一次", systemImage: "rectangle.portrait.and.arrow.right") }
                        .buttonStyle(.bordered).disabled(model.isOperating || model.isInstalling)
                    if model.isOperating { ProgressView().controlSize(.small) }
                }
            }
            if !model.operationLog.isEmpty { logPanel(title: "最近一次连接输出", text: model.operationLog) }
            if !model.installerLog.isEmpty { logPanel(title: "安装日志", text: model.installerLog) }
        }
    }

    private var installerPanel: some View { logPanel(title: "安装日志", text: model.installerLog) }

    private func logPanel(title: String, text: String) -> some View {
        Panel {
            PanelTitle(title: title, subtitle: "可复制给维护人员排查问题。", symbol: "doc.text.magnifyingglass")
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
            }
            .frame(minHeight: 90, maxHeight: 230)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct PageIntro: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08), lineWidth: 1))
    }
}

private struct PanelTitle: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.sidecarBlue).frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StepLine: View {
    let number: Int
    let title: String
    let done: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary)
            Text("\(number). \(title)").font(.callout).foregroundStyle(done ? .primary : .secondary)
        }
    }
}

private struct AppMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(LinearGradient(colors: [Color.sidecarBlue, Color.sidecarBlue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.14).stroke(.white.opacity(0.85), lineWidth: max(1.5, size * 0.045))
                .frame(width: size * 0.62, height: size * 0.48)
            Circle().fill(.white).frame(width: size * 0.14, height: size * 0.14).offset(x: size * 0.18, y: size * 0.14)
            Circle().fill(.white.opacity(0.9)).frame(width: size * 0.09, height: size * 0.09).offset(x: -size * 0.2, y: -size * 0.16)
        }
        .frame(width: size, height: size).shadow(color: Color.sidecarBlue.opacity(0.22), radius: 8, y: 4)
    }
}

private extension Color {
    static let sidecarBlue = Color(red: 0.18, green: 0.42, blue: 0.88)
}

private struct CheckRow: View {
    let item: CheckItem
    let action: (CheckAction) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: item.state.symbol).font(.title3).foregroundStyle(item.state.color)
                .frame(width: 30, height: 30).background(item.state.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.title).font(.body.weight(.semibold))
                    StatusPill(state: item.state)
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let itemAction = item.action, let title = item.actionTitle {
                Button(title) { action(itemAction) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.black.opacity(0.07), lineWidth: 1))
    }
}

private struct StatusPill: View {
    let state: CheckState
    var body: some View {
        Text(state == .good ? "正常" : state == .action ? "需要处理" : state == .warning ? "注意" : "需确认")
            .font(.caption2.weight(.semibold)).foregroundStyle(state.color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(state.color.opacity(0.12), in: Capsule())
    }
}
