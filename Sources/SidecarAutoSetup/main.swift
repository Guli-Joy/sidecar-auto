import AppKit
import CoreBluetooth
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
    case betterDisplay, shortcuts
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

    private let fileManager = FileManager.default

    init() {
        config = readConfig()
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
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .handoff:
            openSettings("x-apple.systempreferences:com.apple.preference.general?Handoff")
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
            "VIRTUAL_DISPLAY_NAME": shellQuote(value.virtualDisplayName)
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
                "VIRTUAL_DISPLAY_NAME=\(shellQuote(value.virtualDisplayName))"
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
        let betterDisplay = betterDisplayStatus()
        let configExists = FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/.config/sidecar-auto/config")
        let shortcuts = shortcutsStatus()
        let fileVault = fileVaultStatus()

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
                      state: bluetooth.ok ? .good : .action, action: .bluetooth, actionTitle: "打开蓝牙设置"),
            CheckItem(id: "handoff", title: "接力（Handoff）", detail: handoff.detail,
                      state: .unknown, action: .handoff, actionTitle: "打开接力设置"),
            CheckItem(id: "accessibility", title: "辅助功能权限", detail:
                      "当前连接路径不需要辅助功能权限；只有启用需要 UI 自动化的可选功能时才需要手动授权。",
                      state: .unknown, action: nil, actionTitle: nil),
            CheckItem(id: "screen", title: "屏幕录制权限", detail:
                      "当前连接和显示状态检查不需要屏幕录制权限；BetterDisplay 如有额外要求会在其应用内提示。",
                      state: .unknown, action: nil, actionTitle: nil),
            CheckItem(id: "betterdisplay", title: "BetterDisplay", detail: betterDisplay.detail,
                      state: betterDisplay.ok ? .good : .action, action: .betterDisplay, actionTitle: "打开 BetterDisplay"),
            CheckItem(id: "shortcuts", title: "macOS 快捷指令", detail: shortcuts.detail,
                      state: .action, action: .shortcuts, actionTitle: "打开快捷指令"),
            CheckItem(id: "filevault", title: "FileVault / 登录状态", detail: fileVault,
                      state: .unknown, action: nil, actionTitle: nil)
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
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh"
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
                authorization = "App 尚未请求蓝牙隐私授权"
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
            detail = "Mac 蓝牙无线电已开启；\(authorization)。点击按钮在系统设置中允许此 App"
        }
        return (radioOn && authorized, detail)
    }

    private nonisolated static func handoffStatus() -> (ok: Bool, detail: String) {
        _ = command("/usr/bin/defaults", ["read", "NSGlobalDomain", "NSUserActivity", "-g"])
        return (false, "macOS 没有公开 API 能证明接力当前可用；请在 Mac 和 iPad 两端手动确认已开启")
    }

    private nonisolated static func betterDisplayStatus() -> (ok: Bool, detail: String) {
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
        if app != nil && (!cli.isEmpty || bundledCLI) {
            return (true, "已发现 BetterDisplay；虚拟屏创建和 Pro/试用资格仍需在应用内确认")
        }
        if app != nil {
            return (false, "已发现 BetterDisplay.app，但没有发现 CLI；打开应用并完成首次设置后重新检查")
        }
        if !cli.isEmpty {
            return (true, "已发现 BetterDisplay CLI；虚拟屏创建和 Pro/试用资格仍需在应用内确认")
        }
        return (false, "未发现 BetterDisplay；有实体显示器时可跳过，无显示器模式需要它")
    }

    private nonisolated static func shortcutsStatus() -> (ok: Bool, detail: String) {
        let path = "/System/Applications/Shortcuts.app"
        return (FileManager.default.fileExists(atPath: path),
                "需要用户在快捷指令中创建“连接 Sidecar”和“断开 Sidecar”两个动作")
    }

    private nonisolated static func fileVaultStatus() -> String {
        let output = command("/usr/bin/fdesetup", ["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return "无法读取 FileVault 状态；冷启动登录仍由 macOS 安全策略控制" }
        if output.localizedCaseInsensitiveContains("on") {
            return "FileVault 已开启；冷启动必须先在解密界面输入密码，普通 App 无法代办"
        }
        return "\(output)；登录后提示脚本只在桌面会话中运行"
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
            "sidecar-bluetooth-radio"
        ]
        let scripts = [
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh"
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
            "sidecar-bluetooth-radio"
        ]
        let scripts = [
            "sidecar-connect-once.sh",
            "sidecar-connect-wireless-once.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-doctor.sh"
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

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configCard
                    checksCard
                    operationCard
                    if !model.installerLog.isEmpty { installerCard }
                }
                .padding(24)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sidecar Auto 设置助手")
                    .font(.largeTitle.bold())
                Text("逐项检查 Mac、权限和 iPad 配置，完成后再使用快捷指令连接。")
                    .foregroundStyle(.secondary)
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text("\(model.goodCount)/\(model.checks.count) 项通过")
                    .font(.headline)
                Button {
                    model.refresh()
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.isInstalling)
                HStack(spacing: 8) {
                    Button {
                        model.connect()
                    } label: {
                        Label("连接一次", systemImage: "rectangle.connected.to.line.below")
                    }
                    .disabled(model.isOperating || model.isInstalling)
                    Button {
                        model.disconnect()
                    } label: {
                        Label("断开一次", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(model.isOperating || model.isInstalling)
                }
            }
        }
        .padding(24)
    }

    private var configCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. 目标 iPad")
                    .font(.headline)
                Text("这些设置只保存在本机，不会上传。名称必须与 Mac 系统设置中显示的 Sidecar 设备名一致。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Form {
                    TextField("iPad 名称", text: $model.config.iPadName)
                    TextField("USB 序列号（可选）", text: $model.config.usbSerial)
                    TextField("无显示器虚拟屏名称", text: $model.config.virtualDisplayName)
                    Toggle("连接无线 Sidecar 前尝试开启 Mac 侧接力", isOn: $model.config.autoEnableHandoff)
                }
                HStack {
                    Button("保存配置") { model.saveConfig() }
                        .keyboardShortcut(.defaultAction)
                    Text("配置路径：~/.config/sidecar-auto/config")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var checksCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("2. 环境与权限")
                    .font(.headline)
                Text("系统权限不能被第三方 App 静默授予。点击按钮打开对应设置页，完成后返回这里重新检查。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(model.checks) { item in
                    CheckRow(item: item) { action in
                        model.perform(action)
                    }
                }
            }
            .padding(8)
        }
    }

    private var operationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("3. 手动测试")
                        .font(.headline)
                    Spacer()
                    if model.isOperating { ProgressView().controlSize(.small) }
                }
                Text("连接和断开只会在点击上面的按钮后执行一次，不会因为刷新状态或启动 App 而自动抢占 iPad。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !model.operationLog.isEmpty {
                    ScrollView {
                        Text(model.operationLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                }
            }
            .padding(8)
        }
    }

    private var installerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("安装日志")
                        .font(.headline)
                    Spacer()
                    if model.isInstalling { ProgressView().controlSize(.small) }
                }
                ScrollView {
                    Text(model.installerLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
            .padding(8)
        }
    }
}

struct CheckRow: View {
    let item: CheckItem
    let action: (CheckAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.state.symbol)
                .foregroundStyle(item.state.color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.semibold))
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let itemAction = item.action, let title = item.actionTitle {
                Button(title) { action(itemAction) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
