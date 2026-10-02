import AppKit
@preconcurrency import CoreBluetooth
import SwiftUI
import Darwin
import Foundation

@MainActor
final class SidecarAutoAppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI's `openWindow` action is scene-scoped. Keep the action supplied
    /// by the menu-bar scene so reopening still works after the last window was
    /// closed and the WindowGroup has released its NSWindow instance.
    private var openMainWindowAction: (() -> Void)?
    private let launchedForLogin = ProcessInfo.processInfo.environment["SIDECAR_AUTO_LOGIN_START"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchedForLogin {
            // A login agent starts the app only to prepare a usable display
            // session. Keep it out of the Dock and do not steal focus from
            // the user's desktop; the menu-bar item remains available.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.hide(nil)
            }
        }
        // Closing the settings window must not terminate the process: the
        // menu-bar item is the recovery path for headless use.
        NSApp.applicationIconImage = NSImage(named: NSImage.applicationIconName)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func registerMainWindowOpener(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let action = openMainWindowAction {
            action()
            return
        }
        // The status item can appear before MenuBarContent has rendered. Give
        // SwiftUI one turn to install the scene action, then try again.
        DispatchQueue.main.async { [weak self] in
            self?.openMainWindowAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

}

@main
struct SidecarAutoSetupApp: App {
    @NSApplicationDelegateAdaptor(SidecarAutoAppDelegate.self) private var appDelegate
    @StateObject private var model = SetupModel()

    var body: some Scene {
        WindowGroup("Sidecar Auto Setup", id: "main") {
            SetupView(model: model, appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 680)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(model: model, appDelegate: appDelegate)
        } label: {
            Image(systemName: model.isOperating
                  ? "rectangle.connected.to.line.below.fill"
                  : "rectangle.connected.to.line.below")
                .help("Sidecar Auto：打开设置或手动连接")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: SetupModel
    let appDelegate: SidecarAutoAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Button("打开设置") {
                appDelegate.showMainWindow()
            }
            Divider()
            if model.isOperating {
                Label(model.operationStage.isEmpty ? "操作进行中…" : model.operationStage,
                      systemImage: "arrow.triangle.2.circlepath")
                Button("取消当前操作") { model.cancelOperation() }
                    .disabled(model.isCancelRequested)
            } else {
                Button("连接一次") { model.connect() }
                    .disabled(!model.canRunConnection || model.isInstalling)
                Button("断开一次") { model.disconnect() }
                    .disabled(!model.canRunConnection || model.isInstalling)
            }
            Divider()
            Button("退出 Sidecar Auto") { NSApp.terminate(nil) }
        }
        .onAppear {
            appDelegate.registerMainWindowOpener {
                openWindow(id: "main")
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }
}

enum CheckState: Sendable, Equatable {
    case good, partial, permission, warning, action, unknown, optional

    var color: Color {
        switch self {
        case .good: return .green
        // The Mac-side switch is ready. The companion iPad cannot be queried
        // remotely, so this is still labelled separately while using the
        // same green treatment as a ready local prerequisite.
        case .partial: return .green
        // The radio can already be on while this app still needs its own
        // Bluetooth privacy grant. Keep that distinct from "radio off".
        case .permission: return .orange
        case .warning: return .orange
        case .action: return .blue
        case .unknown: return .secondary
        case .optional: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .partial: return "checkmark.circle.fill"
        case .permission: return "lock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .action: return "arrow.right.circle.fill"
        case .unknown: return "questionmark.circle"
        case .optional: return "info.circle.fill"
        }
    }
}

enum CheckAction: Sendable, Equatable {
    case install, refresh, bluetooth, handoff
    case betterDisplay, shortcuts, installShortcuts, fileVault, loginOptions, loginAgent, headlessAgent
    case restartApp, openApplicationsFolder
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

/// Re-checks a decided TCC grant without showing another authorization
/// prompt. This is used after the user enables Sidecar Auto in System
/// Settings while the app is still open; a fresh CoreBluetooth callback is
/// more reliable than a cached class-property value on some macOS releases.
private final class BluetoothStatusProbe: NSObject, CBCentralManagerDelegate {
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
        let callback = onState
        DispatchQueue.main.async {
            callback(central.state)
        }
    }
}

private enum BluetoothAuthorizationStatus: Sendable {
    case allowed
    case notDetermined
    case denied
    case restricted
    case unknown
}

private struct BluetoothStatus: Sendable {
    let radioOn: Bool
    let authorization: BluetoothAuthorizationStatus
    let permissionWasRequested: Bool
    let runningFromApplications: Bool
    let detail: String

    var ok: Bool {
        radioOn && authorization == .allowed
    }

    /// The radio and the app privacy grant are independent prerequisites.
    /// A powered-on radio with no app grant is not a radio failure, so expose
    /// a dedicated state instead of making the row look like Bluetooth is off.
    var checkState: CheckState {
        if ok { return .good }
        if radioOn && authorization != .allowed { return .permission }
        return .warning
    }

    var actionTitle: String {
        if ok { return "重新检查" }
        if permissionWasRequested && !runningFromApplications {
            return "打开应用程序文件夹"
        }
        switch authorization {
        case .denied, .restricted:
            return permissionWasRequested ? "重启 App" : "打开蓝牙设置"
        case .notDetermined:
            return permissionWasRequested ? "打开蓝牙设置" : "申请一次"
        case .allowed:
            return "开启蓝牙"
        case .unknown:
            return "检查蓝牙设置"
        }
    }

    var action: CheckAction {
        if ok { return .refresh }
        if permissionWasRequested && !runningFromApplications {
            return .openApplicationsFolder
        }
        switch authorization {
        case .denied, .restricted:
            return permissionWasRequested ? .restartApp : .bluetooth
        case .notDetermined, .allowed, .unknown:
            return .bluetooth
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
    /// Optional checks are shown for context but do not block Sidecar setup.
    let required: Bool

    init(id: String, title: String, detail: String, state: CheckState,
         action: CheckAction?, actionTitle: String?, required: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.action = action
        self.actionTitle = actionTitle
        self.required = required
    }
}

struct SetupConfig: Sendable {
    var iPadName = "iPad"
    var usbSerial = ""
    var autoEnableHandoff = true
    var autoStartHeadlessDisplay = true
    var virtualDisplayName = "SidecarHeadlessFallback"
    var virtualDisplayBackend: VirtualDisplayBackend = .auto
}

struct AppUpdateRelease: Sendable, Equatable {
    let version: String
    let releaseURL: String
    let dmgURL: String
    let assetName: String
}

struct USBIPadCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let serial: String
    var id: String { "\(name)\u{0000}\(serial)" }
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
    @Published var operationStage = ""
    @Published var isCancelRequested = false
    @Published var isRequestingPermission = false
    @Published var isManagingLoginAgent = false
    @Published var isManagingHeadlessAgent = false
    @Published var isScanningIPad = false
    @Published var scanMessage = ""
    @Published var usbCandidates: [USBIPadCandidate] = []
    @Published var betterDisplayReport = "尚未执行 BetterDisplay 只读检查。"
    @Published var isInspectingBetterDisplay = false
    @Published var isCheckingForUpdates = false
    @Published var isDownloadingUpdate = false
    @Published var updateMessage = "尚未检查更新。"
    @Published var availableUpdate: AppUpdateRelease?

    private let fileManager = FileManager.default
    private var bluetoothPermissionRequester: BluetoothPermissionRequester?
    private var bluetoothStatusProbe: BluetoothStatusProbe?
    private var shouldProbeBluetoothAfterSettings = false
    private var activeObserver: NSObjectProtocol?
    private var operationLogStartOffset: UInt64 = 0
    private var lastObservedLogSize: UInt64 = 0
    private var operationTask: Task<ProcessResult, Never>?
    private var headlessStartTask: Task<Void, Never>?
    private var activeOperationExecutable = ""
    private var pendingRuntimeOperation: PendingRuntimeOperation?

    private enum PendingRuntimeOperation {
        case connect
        case disconnect
    }

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
        startHeadlessDisplayAfterLaunch()
    }

    /// The login agent launches this app once per user session. Preparing the
    /// fallback here keeps launchd responsible only for starting the app,
    /// while the app owns the virtual-display policy and diagnostics.
    private func startHeadlessDisplayAfterLaunch() {
        guard config.autoStartHeadlessDisplay,
              config.virtualDisplayBackend != .betterdisplay else { return }
        let script = Self.headlessDisplayScriptURL()
        guard fileManager.isExecutableFile(atPath: script) else { return }
        headlessStartTask?.cancel()
        headlessStartTask = Task.detached(priority: .userInitiated) {
            // WindowServer may still be bringing up the Aqua session when the
            // login agent fires. Give it a short settling window first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            _ = Self.execute(executable: script, arguments: [])
        }
    }

    deinit {
        headlessStartTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    // Use GitHub's public latest-release redirect instead of the unauthenticated
    // REST API. The API is limited to 60 requests per hour per public IP, which
    // makes a normal app update check fail for everyone sharing that address.
    private nonisolated static let latestReleaseEndpoint =
        "https://github.com/Guli-Joy/sidecar-auto/releases/latest"

    private nonisolated static var currentAppVersionValue: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates, !isDownloadingUpdate else { return }
        isCheckingForUpdates = true
        updateMessage = "正在检查 GitHub Releases……"
        availableUpdate = nil
        let currentVersion = Self.currentAppVersionValue
        Task { @MainActor [weak self] in
            defer { self?.isCheckingForUpdates = false }
            do {
                guard let endpoint = URL(string: Self.latestReleaseEndpoint) else {
                    throw UpdateError.invalidEndpoint
                }
                var request = URLRequest(url: endpoint)
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                request.setValue("Sidecar-Auto/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let finalURL = response.url,
                      let tag = Self.releaseTag(from: finalURL) else {
                    throw UpdateError.invalidRelease
                }
                let version = Self.normalizedVersion(tag)
                guard !version.isEmpty else { throw UpdateError.invalidRelease }
                let assetName = "Sidecar-Auto-Setup-\(version)-arm64.dmg"
                let releaseURL = "https://github.com/Guli-Joy/sidecar-auto/releases/tag/\(tag)"
                guard let dmgURL = URL(string: "https://github.com/Guli-Joy/sidecar-auto/releases/download/\(tag)/\(assetName)") else {
                    throw UpdateError.invalidRelease
                }
                let release = AppUpdateRelease(
                    version: version,
                    releaseURL: releaseURL,
                    dmgURL: dmgURL.absoluteString,
                    assetName: assetName
                )
                guard let self else { return }
                if Self.isVersion(version, newerThan: currentVersion) {
                    self.availableUpdate = release
                    self.updateMessage = "发现新版本 v\(version)，可下载 arm64 DMG。"
                } else {
                    self.updateMessage = "当前已经是最新版本 v\(currentVersion)。"
                }
            } catch is CancellationError {
                self?.updateMessage = "更新检查已取消。"
            } catch {
                self?.updateMessage = "检查更新失败：\(Self.updateErrorMessage(error))"
            }
        }
    }

    func downloadLatestUpdate() {
        guard !isDownloadingUpdate, let update = availableUpdate,
              let url = URL(string: update.dmgURL) else { return }
        isDownloadingUpdate = true
        updateMessage = "正在下载 v\(update.version) DMG……"
        Task { @MainActor [weak self] in
            defer { self?.isDownloadingUpdate = false }
            do {
                var request = URLRequest(url: url)
                request.setValue("Sidecar-Auto/\(Self.currentAppVersionValue)", forHTTPHeaderField: "User-Agent")
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let destination = downloads.appendingPathComponent(update.assetName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                self?.updateMessage = "已下载到“下载”文件夹。请打开 DMG，把新 App 拖到“应用程序”后重新打开。"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                self?.updateMessage = "更新下载已取消。"
            } catch {
                self?.updateMessage = "下载更新失败：\(Self.updateErrorMessage(error))"
            }
        }
    }

    func openLatestReleasePage() {
        guard let update = availableUpdate, let url = URL(string: update.releaseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private enum UpdateError: LocalizedError {
        case invalidEndpoint
        case invalidRelease
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "更新地址无效"
            case .invalidRelease: return "Release 版本号无效"
            case let .server(status): return status > 0 ? "GitHub 返回 HTTP \(status)" : "无法连接 GitHub"
            }
        }
    }

    private nonisolated static func releaseTag(from url: URL) -> String? {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let tagIndex = components.firstIndex(of: "tag"),
              components.index(after: tagIndex) < components.endIndex else {
            return nil
        }
        return String(components[components.index(after: tagIndex)])
    }

    private nonisolated static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private nonisolated static func versionParts(_ raw: String) -> [Int] {
        normalizedVersion(raw).split(separator: ".", omittingEmptySubsequences: false).map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }

    private nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = versionParts(candidate)
        let right = versionParts(current)
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private nonisolated static func updateErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }

    var requiredCount: Int { checks.filter(\.required).count }
    /// Count local prerequisites and locally-ready partial checks as passed.
    /// For example, macOS exposes its Handoff preference but does not expose
    /// the iPad's corresponding switch. That row is therefore marked
    /// “Mac 已开启” while still contributing to the setup progress.
    var goodCount: Int {
        checks.filter { $0.required && ($0.state == .good || $0.state == .partial) }.count
    }

    /// A manual connection test is useful only after the local runtime and a
    /// target have been configured.  Transport-specific checks are still
    /// allowed to be incomplete here because the one-shot controller gives a
    /// more precise wired/wireless diagnostic after the user presses Connect.
    var canRunConnection: Bool {
        let runtimeReady = checks.first(where: { $0.id == "runtime" })?.state == .good
        let targetReady = checks.first(where: { $0.id == "config" })?.state == .good
        return runtimeReady && targetReady && !isInstalling
    }

    var connectionPrerequisiteSummary: String {
        if canRunConnection { return "运行时和目标 iPad 已就绪；连接时会自动选择有线或无线。" }
        let missing = checks.filter { ["runtime", "config"].contains($0.id) && $0.state != .good }
            .map(\.title)
        return missing.isEmpty ? "正在读取连接前置条件……" : "请先完成：\(missing.joined(separator: "、"))。"
    }

    /// `true` only means that the local Mac radio and this app's Bluetooth
    /// privacy grant are ready.  It does not claim anything about the iPad.
    var bluetoothReady: Bool {
        checks.first(where: { $0.id == "bluetooth" })?.state == .good
    }

    var currentAppVersion: String { Self.currentAppVersionValue }

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
            self?.probeBluetoothIfNeeded()
        }
    }

    private func probeBluetoothIfNeeded() {
        guard bluetoothStatusProbe == nil,
              shouldProbeBluetoothAfterSettings
        else { return }
        shouldProbeBluetoothAfterSettings = false
        bluetoothStatusProbe = BluetoothStatusProbe { [weak self] state in
            Task { @MainActor [weak self] in
                self?.applyBluetoothProbe(state)
            }
        }
    }

    private func applyBluetoothProbe(_ state: CBManagerState) {
        guard let index = checks.firstIndex(where: { $0.id == "bluetooth" }) else { return }
        let current = checks[index]
        switch state {
        case .poweredOn:
            bluetoothStatusProbe = nil
            checks[index] = CheckItem(
                id: current.id, title: current.title,
                detail: "Mac 蓝牙无线电已开启；App 的蓝牙隐私授权已允许（系统设置已同步）。",
                state: .good, action: .refresh, actionTitle: "重新检查", required: current.required
            )
            message = "蓝牙权限已同步，环境状态已更新。"
        case .unauthorized:
            bluetoothStatusProbe = nil
            checks[index] = CheckItem(
                id: current.id, title: current.title,
                detail: "Mac 蓝牙无线电状态已打开，但当前运行副本还没有拿到授权结果。若系统设置已开启，请先重启这个 App；如果仍未恢复，再确认开关对应当前运行的副本。",
                state: .permission, action: .restartApp, actionTitle: "重启 App", required: current.required
            )
            message = "蓝牙授权已变更；正在运行的 App 需要重启后才能重新读取。"
        case .poweredOff:
            bluetoothStatusProbe = nil
            checks[index] = CheckItem(
                id: current.id, title: current.title,
                detail: "App 的蓝牙隐私授权已允许，但 Mac 蓝牙无线电处于关闭状态。",
                state: .warning, action: .bluetooth, actionTitle: "开启蓝牙", required: current.required
            )
            message = "蓝牙权限已确认，但 Mac 蓝牙无线电仍处于关闭状态。"
        case .unsupported:
            bluetoothStatusProbe = nil
            checks[index] = CheckItem(
                id: current.id, title: current.title,
                detail: "当前 Mac 不支持蓝牙无线连接。",
                state: .warning, action: nil, actionTitle: nil, required: current.required
            )
            message = "当前 Mac 不支持蓝牙无线连接。"
        default:
            break
        }
    }

    func saveConfig() {
        if let validationError = validateConfig(config) {
            message = validationError
            return
        }
        do {
            try writeConfig(config)
            let shouldEnableHeadless = config.autoStartHeadlessDisplay &&
                config.virtualDisplayBackend != .betterdisplay
            let worker = Task.detached(priority: .userInitiated) {
                Self.setHeadlessAgent(enabled: shouldEnableHeadless)
            }
            Task { @MainActor [weak self] in
                let result = await worker.value
                guard let self else { return }
                if result.status == 0 {
                    if shouldEnableHeadless {
                        self.startHeadlessDisplayAfterLaunch()
                    }
                    self.message = shouldEnableHeadless
                        ? "配置已保存，并已开启 Sidecar Auto 登录后静默启动。"
                        : "配置已保存，并已停用登录后静默启动。"
                } else {
                    self.message = "配置已保存，但登录后静默启动设置失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                self.refresh()
            }
        } catch {
            message = "配置保存失败：\(error.localizedDescription)"
        }
    }

    /// Read the USB detector once and fill the target fields from its unique
    /// match. The scan never starts Sidecar and never changes the config file
    /// until the user presses “保存设置”.
    func scanConnectedIPad() {
        guard !isScanningIPad else { return }
        let detector = "\(NSHomeDirectory())/.local/bin/sidecar-ipad-usb-detect.sh"
        guard fileManager.isExecutableFile(atPath: detector) else {
            scanMessage = "尚未安装检测程序，请先点击“安装 / 修复工具”。"
            return
        }
        isScanningIPad = true
        scanMessage = "正在扫描已连接的 iPad 数据设备……"
        usbCandidates = []
        let worker = Task.detached(priority: .userInitiated) {
            Self.execute(executable: detector, arguments: [])
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.isScanningIPad = false
            let outputLines = result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            self.usbCandidates = outputLines.compactMap { line in
                guard line.hasPrefix("USB_IPAD_CANDIDATE\t") else { return nil }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3 else { return nil }
                return USBIPadCandidate(name: fields[1], serial: fields[2])
            }
            let line = outputLines.first(where: { $0.hasPrefix("USB_IPAD_MATCHED\t") })
            if result.status == 0, let line {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let name = fields.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let serial = fields.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else {
                    self.scanMessage = "检测到了 USB 设备，但没有读取到 iPad 名称。请手动填写名称。"
                    return
                }
                // IORegistry exposes the USB product/registry name, not
                // necessarily the friendly Sidecar name shown by macOS. Keep
                // a custom target untouched; only replace the initial generic
                // value when the USB name itself is the generic iPad label.
                let currentName = self.config.iPadName.trimmingCharacters(in: .whitespacesAndNewlines)
                if (currentName.isEmpty || currentName == "iPad") && name == "iPad" {
                    self.config.iPadName = name
                }
                if !serial.isEmpty { self.config.usbSerial = serial }
                let targetHint = currentName.isEmpty || currentName == "iPad"
                    ? "请确认 iPad 名称与 macOS 显示一致"
                    : "已保留你填写的 Sidecar 名称"
                self.scanMessage = serial.isEmpty
                    ? "已识别 USB 设备“\(name)”；\(targetHint)，然后点击“保存设置”。"
                    : "已识别 USB 设备“\(name)”并填入序列号；\(targetHint)，然后点击“保存设置”。"
            } else if result.output.contains("USB_IPAD_AMBIGUOUS") {
                    self.scanMessage = self.usbCandidates.isEmpty
                    ? "检测到多台 iPad，请填写 USB 序列号后再保存。"
                    : "检测到 \(self.usbCandidates.count) 台 iPad，请在下方选择目标设备。"
            } else if result.output.contains("USB_IPAD_NOT_FOUND") {
                self.scanMessage = "没有检测到 iPad 数据线；可以直接配置名称并使用无线连接。"
            } else {
                self.scanMessage = "扫描失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无法读取 USB 状态" : result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// Inspect BetterDisplay without launching it or changing display state.
    /// This makes the optional provider understandable before a headless test.
    func inspectBetterDisplay() {
        guard !isInspectingBetterDisplay else { return }
        isInspectingBetterDisplay = true
        betterDisplayReport = "正在读取 BetterDisplay 安装、进程和只读能力……"
        let worker = Task.detached(priority: .userInitiated) {
            Self.betterDisplayInspection()
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            self?.betterDisplayReport = report
            self?.isInspectingBetterDisplay = false
        }
    }

    func cancelOperation() {
        guard isOperating else { return }
        isCancelRequested = true
        operationStage = "正在请求取消；正在等待当前命令退出…"
        // Cover the startup race where the detached worker has not written its
        // PID file yet. If cancellation wins before execute() starts, the
        // worker returns without launching a command.
        operationTask?.cancel()
        let pidURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Caches/sidecar-auto/active-operation.pid")
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            appendOperationLog("\n⚠️ 找不到当前操作进程；脚本会在当前阶段结束后停止。\n")
            return
        }
        let command = Self.processCommand(pid: pid) ?? ""
        let expectedName = URL(fileURLWithPath: activeOperationExecutable).lastPathComponent
        guard !expectedName.isEmpty, command.contains(expectedName) else {
            appendOperationLog("\n⚠️ 当前操作 PID 与预期脚本不匹配，已拒绝终止，避免误杀其他进程。\n")
            return
        }
        appendOperationLog("\n正在停止连接脚本和它启动的子进程…\n")
        Task.detached(priority: .userInitiated) {
            Self.terminateProcessTree(rootPID: pid)
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
        case .restartApp:
            restartApplication()
        case .openApplicationsFolder:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            message = "已打开“应用程序”文件夹。请从同一个 Sidecar Auto Setup.app 启动，然后重新检查；不要同时运行 dist 和应用程序中的副本。"
        case .handoff:
            openHandoffSettings()
        case .betterDisplay:
            if let app = betterDisplayURL() {
                NSWorkspace.shared.open(app)
            } else {
                NSWorkspace.shared.open(URL(string: "https://github.com/waydabber/BetterDisplay")!)
            }
        case .shortcuts:
            // Deep-link to the connection shortcut when possible so the user
            // can press Run and answer Shortcuts' one-time Shell Script
            // consent. The app never invokes `shortcuts run` itself because
            // that would start a real Sidecar connection during a probe.
            var openedShortcut = false
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "open-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: "连接 Sidecar")]
            if let shortcutURL = components.url {
                openedShortcut = NSWorkspace.shared.open(shortcutURL)
            }
            if !openedShortcut {
                let appURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                if fileManager.fileExists(atPath: appURL.path) {
                    NSWorkspace.shared.open(appURL)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Shortcuts.app"))
                }
            }
            message = "已打开连接快捷指令。请在有屏幕时点击运行，并在 macOS 弹窗中点击‘允许’；不会自动替你运行连接。"
        case .installShortcuts:
            installShortcuts()
        case .fileVault:
            openSettings("x-apple.systempreferences:com.apple.preference.security?FileVault")
            message = "文件保险箱设置用于查看启动保护；使用 Sidecar 不要求关闭它。"
        case .loginOptions:
            openSettings("x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
            message = "已打开“用户与群组”。请查看“自动登录为”；文件保险箱开启时 macOS 会禁用此选项。"
        case .loginAgent:
            toggleLoginAgent()
        case .headlessAgent:
            toggleHeadlessAgent()
        }
    }

    private func restartApplication() {
        let appURL = Bundle.main.bundleURL
        message = "正在重启 Sidecar Auto，以重新读取系统授权……"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        let currentPID = NSRunningApplication.current.processIdentifier
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                // LSMultipleInstancesProhibited can make LaunchServices return
                // the existing process even when a new instance was requested.
                // In that case schedule a second open after this process exits;
                // otherwise terminating here would leave no App running.
                if error != nil || application?.processIdentifier == currentPID {
                    let relauncher = Process()
                    relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relauncher.arguments = [
                        "-c",
                        "sleep 0.4; exec /usr/bin/open -a \(self.shellQuote(appURL.path))"
                    ]
                    relauncher.standardOutput = FileHandle.nullDevice
                    relauncher.standardError = FileHandle.nullDevice
                    try? relauncher.run()
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Manage only the optional post-login announcement. This LaunchAgent is
    /// deliberately not a Sidecar reconnect service: logging in must never
    /// claim or disconnect an iPad without an explicit user action.
    private func toggleLoginAgent() {
        guard !isManagingLoginAgent else { return }
        isManagingLoginAgent = true
        let enable = !Self.loginAgentIsLoaded()
        let worker = Task.detached(priority: .userInitiated) {
            Self.setLoginAgent(enabled: enable)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.isManagingLoginAgent = false
            self.message = result.status == 0
                ? (enable ? "已开启登录后桌面提示。重启并登录后会播报桌面已准备好，但不会自动连接 Sidecar。"
                          : "已停用登录后桌面提示。不会影响手动连接和快捷键。")
                : "登录后提示设置失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            self.refresh()
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
                if Self.bluetoothPermissionWasRequested() {
                    shouldProbeBluetoothAfterSettings = true
                    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                    message = "此 App 已经向 macOS 申请过蓝牙权限。请在系统设置中确认 Sidecar Auto 的开关；不会重复弹出申请窗口。"
                    return
                }
                Self.markBluetoothPermissionRequested()
                isRequestingPermission = true
                message = "正在申请蓝牙权限，请在系统提示中点击“允许”……"
                bluetoothPermissionRequester = BluetoothPermissionRequester { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.bluetoothRequestFinished(state)
                    }
                }
                return
            case .denied, .restricted:
                shouldProbeBluetoothAfterSettings = true
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
        if !Self.installedRuntimeIsCurrent() {
            guard !isInstalling else { return }
            pendingRuntimeOperation = .connect
            message = "连接前正在自动修复运行时工具……"
            installRuntime()
            return
        }
        runOperation(
            executable: "\(NSHomeDirectory())/.local/bin/sidecar-connect-once.sh",
            arguments: ["auto"],
            operationLabel: "连接",
            startMessage: "正在执行一次 Sidecar 连接……"
        )
    }

    /// Disconnects once through the existing controller. The user must click
    /// this button; the setup app never disconnects an existing session while
    /// checking status.
    func disconnect() {
        if !Self.installedRuntimeIsCurrent() {
            guard !isInstalling else { return }
            pendingRuntimeOperation = .disconnect
            message = "断开前正在自动修复运行时工具……"
            installRuntime()
            return
        }
        runOperation(
            executable: "\(NSHomeDirectory())/.local/bin/sidecar-disconnect-once.sh",
            arguments: [],
            operationLabel: "断开",
            startMessage: "正在执行一次 Sidecar 断开……"
        )
    }

    private func runOperation(executable: String, arguments: [String], operationLabel: String,
                              startMessage: String) {
        guard !isOperating else { return }
        guard fileManager.isExecutableFile(atPath: executable) else {
            operationLog = "❌ \(operationLabel)失败\n找不到可执行文件：\(executable)\n请先点击“安装 / 修复”。"
            message = "运行时工具尚未安装。"
            return
        }

        isOperating = true
        activeOperationExecutable = executable
        isCancelRequested = false
        operationLogStartOffset = Self.sidecarLogFileSize()
        lastObservedLogSize = operationLogStartOffset
        operationStage = startMessage
        operationLog = "\(startMessage)\n"
        message = startMessage
        let worker = Task.detached(priority: .userInitiated) {
            if Task.isCancelled {
                return ProcessResult(status: 125, output: "操作在启动前已取消。\n")
            }
            return Self.execute(executable: executable, arguments: arguments,
                                pidFile: "\(NSHomeDirectory())/Library/Caches/sidecar-auto/active-operation.pid")
        }
        operationTask = worker
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.monitorOperation(operationLabel: operationLabel)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.operationTask = nil
            self.activeOperationExecutable = ""
            // The shell entry points intentionally write their detailed
            // diagnostics to the shared log file and may not emit anything
            // on stdout.  Previously the panel therefore stayed at the
            // initial “正在执行……” line even after the process had
            // finished.  Always append an explicit terminal record and keep
            // captured stdout/stderr when a helper did return it.
            let captured = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty {
                self.appendOperationLog("\n\(captured)\n")
            } else {
                self.appendOperationLog("\n脚本未返回标准输出；详细诊断已写入 ~/Library/Logs/sidecar-auto.log。\n")
            }
            if let diagnosticTail = self.sidecarDiagnosticTail() {
                self.appendOperationLog("\n最近的诊断日志：\n\(diagnosticTail)\n")
            }
            if self.isCancelRequested {
                self.appendOperationLog("\n⚠️ \(operationLabel)已取消（进程退出码 \(result.status)）\n")
            } else if result.status == 0 {
                self.appendOperationLog("\n✅ \(operationLabel)成功（退出码 0）\n")
            } else {
                self.appendOperationLog("\n❌ \(operationLabel)失败（退出码 \(result.status)）\n")
            }
            self.isOperating = false
            self.operationStage = self.isCancelRequested ? "操作已取消" : (result.status == 0 ? "操作完成" : "操作失败")
            self.message = result.status == 0
                ? "\(operationLabel)完成；请确认 iPad 是否出现随航画面。"
                : self.isCancelRequested
                    ? "\(operationLabel)已取消；请确认当前没有残留随航会话。"
                    : "\(operationLabel)失败（退出码 \(result.status)）；请查看输出和诊断。"
            self.refresh()
        }
    }

    private func monitorOperation(operationLabel: String) async {
        while isOperating {
            let currentSize = Self.sidecarLogFileSize()
            if currentSize != lastObservedLogSize {
                lastObservedLogSize = currentSize
                if let tail = sidecarDiagnosticTail(), !tail.isEmpty {
                    operationStage = Self.operationStage(from: tail, fallback: "正在执行\(operationLabel)…")
                    operationLog = String("正在执行\(operationLabel)…\n\n最近日志：\n\(tail)".suffix(131_072))
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func appendOperationLog(_ text: String) {
        operationLog.append(contentsOf: text)
        if operationLog.count > 131_072 {
            operationLog = String(operationLog.suffix(131_072))
        }
    }

    private func appendInstallerLog(_ text: String) {
        installerLog.append(contentsOf: text)
        if installerLog.count > 65_536 {
            installerLog = String(installerLog.suffix(65_536))
        }
    }

    private nonisolated static func operationStage(from log: String, fallback: String) -> String {
        let lower = log.lowercased()
        if lower.contains("auto transport selected wired") { return "已检测到数据线，正在连接有线 Sidecar" }
        if lower.contains("auto transport selected wireless") { return "未检测到数据线，正在准备无线 Sidecar" }
        if lower.contains("wireless preflight") || lower.contains("bluetooth") { return "正在准备 Wi‑Fi、蓝牙和接力" }
        if lower.contains("display topology") { return "正在等待显示拓扑稳定" }
        if lower.contains("virtual display") || lower.contains("headless") || lower.contains("fallback") { return "正在创建并验证备用虚拟屏" }
        if lower.contains("sidecar api request") || lower.contains("connect request") { return "正在请求 Sidecar 连接" }
        if lower.contains("display online") || lower.contains("画面") { return "正在等待 iPad 画面上线" }
        if lower.contains("set as main") || lower.contains("main-display") || lower.contains("main display") { return "正在将 iPad 设为主屏" }
        if lower.contains("disconnect") { return "正在验证断开和屏幕恢复" }
        return fallback
    }

    /// The shell controllers keep a durable log so a headless Mac can be
    /// diagnosed after the app is closed. Include its tail in the manual-test
    /// panel as well; otherwise a normal run has no stdout because the
    /// controller deliberately captures its lower-level command output.
    private func sidecarDiagnosticTail() -> String? {
        let url = Self.sidecarLogURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        guard endOffset > 0 else { return nil }
        let configuredOffset = operationLogStartOffset > endOffset ? 0 : operationLogStartOffset
        let readOffset = max(configuredOffset, endOffset > 262_144 ? endOffset - 262_144 : 0)
        guard (try? handle.seek(toOffset: readOffset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(60)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func sidecarLogURL() -> URL {
        let defaultURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/sidecar-auto.log")
        let configURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/sidecar-auto/config")
        if let config = try? String(contentsOf: configURL, encoding: .utf8),
           let line = config.split(separator: "\n").first(where: {
               $0.trimmingCharacters(in: .whitespaces).hasPrefix("LOG_FILE=")
           }) {
            let raw = line.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let value = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
            if !value.isEmpty { return URL(fileURLWithPath: value) }
        }
        return defaultURL
    }

    private nonisolated static func sidecarLogFileSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sidecarLogURL().path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Stop the action and helper processes started beneath its shell entry
    /// point. Terminating only the top-level shell can leave a waiting `say`,
    /// display helper, or Sidecar request running after the UI says cancelled.
    ///
    /// A single process-tree snapshot is racy: a shell can start a helper
    /// immediately after the snapshot, and a helper can ignore TERM. Keep
    /// rescanning during a short grace period, then use KILL for every known
    /// survivor. This makes cancellation bounded even when a child is stuck
    /// in a system call or has inherited the controller's stdout/stderr.
    private nonisolated static func terminateProcessTree(rootPID: Int32) {
        guard rootPID > 0 else { return }

        var known = processTree(rootPID: rootPID)
        // Send TERM to descendants before their parent so the shell has a
        // chance to clean up its own children while it is still alive.
        signalProcesses(known, signal: "TERM")

        let graceDeadline = Date().addingTimeInterval(2.0)
        while Date() < graceDeadline {
            known.append(contentsOf: processTree(rootPID: rootPID))
            known = uniqueProcessIDs(known)
            if known.allSatisfy({ !processIsAlive($0) }) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // The root may have exited by now, so include descendants discovered
        // during the grace period before deciding who needs KILL.
        known.append(contentsOf: processTree(rootPID: rootPID))
        let survivors = uniqueProcessIDs(known).filter(processIsAlive)
        guard !survivors.isEmpty else { return }
        signalProcesses(survivors, signal: "KILL")

        // Do not return while a stubborn child is still alive. A short bounded
        // wait keeps the UI's "cancelled" state aligned with the process tree.
        let killDeadline = Date().addingTimeInterval(0.5)
        while Date() < killDeadline {
            if survivors.allSatisfy({ !processIsAlive($0) }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Return the root and every descendant visible in one `ps` snapshot.
    /// If `ps` cannot be started, retaining the root still lets the caller
    /// terminate the controller instead of silently reporting cancellation.
    private nonisolated static func processTree(rootPID: Int32) -> [Int32] {
        let ps = Process()
        let outputPipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        ps.standardOutput = outputPipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [rootPID] }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var children: [Int32: [Int32]] = [:]
        if let rows = String(data: data, encoding: .utf8) {
            for row in rows.split(separator: "\n") {
                let fields = row.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                      pid > 0, parent > 0 else { continue }
                children[parent, default: []].append(pid)
            }
        }

        var ordered: [Int32] = []
        var visited: Set<Int32> = [rootPID]
        func collect(_ parent: Int32) {
            for child in children[parent, default: []] where visited.insert(child).inserted {
                collect(child)
                ordered.append(child)
            }
        }
        collect(rootPID)
        ordered.append(rootPID)
        return ordered
    }

    private nonisolated static func processCommand(pid: Int32) -> String? {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func uniqueProcessIDs(_ pids: [Int32]) -> [Int32] {
        var seen = Set<Int32>()
        return pids.filter { seen.insert($0).inserted }
    }

    private nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // `kill(pid, 0)` performs an existence/permission check without
        // changing the process. EPERM still means the process exists.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private nonisolated static func signalProcesses(_ pids: [Int32], signal: String) {
        guard !pids.isEmpty else { return }
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/kill")
        killer.arguments = ["-\(signal)"] + pids.map(String.init)
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
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
            self.appendInstallerLog(result.output)
            self.isInstalling = false
            self.message = result.status == 0
                ? "连接和断开快捷指令导入完成；已尝试设置 ⌃⌥⌘S / ⌃⌥⌘D，请查看安装日志。"
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
            self?.appendInstallerLog(result.output)
            self?.isInstalling = false
            if result.status == 0 {
                self?.syncHeadlessAgentAfterInstall()
                let pending = self?.pendingRuntimeOperation
                self?.pendingRuntimeOperation = nil
                switch pending {
                case .connect:
                    self?.connect()
                case .disconnect:
                    self?.disconnect()
                case .none:
                    break
                }
            } else {
                self?.pendingRuntimeOperation = nil
                self?.message = "安装失败，请查看下方日志并按提示处理。"
            }
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
            let parsed = parseShellValue(raw)
            switch key {
            case "IPAD_NAME": value.iPadName = parsed
            case "IPAD_USB_SERIAL_NUMBER": value.usbSerial = parsed
            case "AUTO_ENABLE_HANDOFF": value.autoEnableHandoff = parsed != "0"
            case "AUTO_START_HEADLESS_DISPLAY": value.autoStartHeadlessDisplay = parsed != "0"
            case "VIRTUAL_DISPLAY_NAME": value.virtualDisplayName = parsed
            case "VIRTUAL_DISPLAY_BACKEND": value.virtualDisplayBackend = VirtualDisplayBackend(rawValue: parsed) ?? .auto
            default: break
            }
        }
        return value
    }

    /// Decode the small shell-value subset written by `writeConfig` and used
    /// by the bundled scripts.  A plain trim of quote characters corrupts
    /// names containing apostrophes because `shellQuote` writes them as the
    /// POSIX sequence `'\\''`.
    private func parseShellValue(_ raw: String) -> String {
        guard raw.count >= 2 else {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if raw.first == "'", raw.last == "'" {
            let inner = String(raw.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "'\\''", with: "'")
        }
        if raw.first == "\"", raw.last == "\"" {
            let inner = raw.dropFirst().dropLast()
            var result = ""
            var escaped = false
            for character in inner {
                if escaped {
                    // In POSIX double quotes, backslash only quotes a
                    // backslash, dollar sign, backtick, double quote, or a
                    // newline. Preserve it for other characters so a
                    // manually edited value such as `iPad\\ Pro` is not
                    // silently changed while reading the config.
                    if character == "\\" || character == "$" ||
                        character == "`" || character == "\"" {
                        result.append(character)
                    } else {
                        result.append("\\")
                        result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            if escaped { result.append("\\") }
            return result
        }
        return raw
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
            "AUTO_START_HEADLESS_DISPLAY": value.autoStartHeadlessDisplay ? "1" : "0",
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
                "AUTO_START_HEADLESS_DISPLAY=\(value.autoStartHeadlessDisplay ? "1" : "0")",
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
        let transport = usbTransportStatus()
        let physicalDisplay = physicalDisplayPresent()
        let wifi = wifiStatus()
        let bluetooth = bluetoothStatus()
        let handoff = handoffStatus()
        // These probes can invoke third-party CLIs or a resident display
        // helper. Do not pay that cost while a physical display is present or
        // when the selected backend cannot use the result.
        let builtinVirtual = (!physicalDisplay && config.virtualDisplayBackend != .betterdisplay)
            ? builtinVirtualDisplayStatus()
            : (ok: true, detail: "当前路径不需要项目内置虚拟屏；拔掉显示器后会按配置检查")
        let shouldCheckBetterDisplay = !physicalDisplay &&
            (config.virtualDisplayBackend == .betterdisplay ||
             (config.virtualDisplayBackend == .auto && !builtinVirtual.ok))
        let betterDisplay = shouldCheckBetterDisplay
            ? betterDisplayStatus(backend: config.virtualDisplayBackend)
            : (ok: true, detail: physicalDisplay
               ? "当前连接有实体显示器；BetterDisplay 只在无显示器方案中检查"
               : "当前自动方案优先使用项目内置虚拟屏；BetterDisplay 只作为后备")
        let betterDisplayRequired = !physicalDisplay &&
            (config.virtualDisplayBackend == .betterdisplay ||
             (config.virtualDisplayBackend == .auto && !builtinVirtual.ok))
        let configExists = FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/.config/sidecar-auto/config")
        let shortcuts = shortcutsStatus()
        let fileVault = fileVaultStatus()
        let autoLogin = autoLoginStatus(fileVaultEnabled: fileVault.enabled)
        let headlessAgent = headlessAgentStatus(config: config)
        let headlessRequired = !physicalDisplay && config.virtualDisplayBackend != .betterdisplay
        let headlessAction: CheckAction? = !Bundle.main.bundlePath.hasPrefix("/Applications/")
            ? .openApplicationsFolder
            : config.virtualDisplayBackend == .betterdisplay ? .betterDisplay : .headlessAgent

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
            CheckItem(id: "transport", title: "当前连接方式", detail: transport.detail,
                      state: transport.ok ? .good : .action,
                      action: .refresh, actionTitle: "重新检查"),
            CheckItem(id: "wifi", title: "Wi-Fi", detail: wifi.detail,
                      state: transport.isWired ? .optional : (wifi.ok ? .good : .warning),
                      action: transport.isWired ? nil : .refresh,
                      actionTitle: transport.isWired ? nil : "重新检查",
                      required: !transport.isWired),
            CheckItem(id: "bluetooth", title: "蓝牙", detail: bluetooth.detail,
                      state: transport.isWired ? .optional : bluetooth.checkState,
                      action: transport.isWired ? nil : bluetooth.action,
                      actionTitle: transport.isWired ? nil : bluetooth.actionTitle,
                      required: !transport.isWired),
            CheckItem(id: "handoff", title: "Mac 接力（Handoff）", detail: handoff.detail,
                      // A positive result here means the Mac-side preference
                      // is enabled. The iPad switch cannot be read remotely,
                      // so it is called out in the detail text rather than
                      // represented as a separate local check. This row still
                      // counts the Mac-side prerequisite toward readiness.
                      state: transport.isWired ? .optional : (handoff.ok ? .good : .warning),
                      action: transport.isWired ? nil : (handoff.ok ? .refresh : .handoff),
                      actionTitle: transport.isWired ? nil : (handoff.ok ? "重新检查" : "打开 Mac 接力设置"),
                      required: !transport.isWired),
            CheckItem(id: "betterdisplay", title: "BetterDisplay", detail: betterDisplay.detail,
                      state: betterDisplayRequired
                        ? (betterDisplay.ok ? .good : .action) : .optional,
                      action: betterDisplayRequired ? .betterDisplay : nil,
                      actionTitle: betterDisplayRequired
                        ? (betterDisplay.ok ? "打开 BetterDisplay" : "安装 / 打开 BetterDisplay") : nil,
                      required: betterDisplayRequired),
            CheckItem(id: "builtin-virtual", title: "项目内置虚拟屏", detail: builtinVirtual.detail,
                      state: builtinVirtual.ok ? .good : .action,
                      action: builtinVirtual.ok ? .refresh : .install,
                      actionTitle: builtinVirtual.ok ? "重新检查" : "安装 / 修复",
                      required: !physicalDisplay && config.virtualDisplayBackend != .betterdisplay),
            CheckItem(id: "shortcuts", title: "macOS 快捷指令", detail: shortcuts.detail,
                      state: shortcuts.ok ? .good : .action,
                      // Imported shortcuts still need Apple's one-time
                      // “Allow … to run Shell Script” consent. Opening
                      // Shortcuts lets the user run each action while a
                      // display is attached; the app never runs a real
                      // connection merely to probe that permission.
                      action: shortcuts.detail.contains("首次运行") ? .shortcuts
                        : shortcuts.ok ? .shortcuts : .installShortcuts,
                      actionTitle: shortcuts.detail.contains("首次运行") ? "打开并完成首次允许"
                        : shortcuts.ok ? "打开快捷指令" : "一键配置快捷指令"),
            CheckItem(id: "filevault", title: "文件保险箱（FileVault）", detail: fileVault.detail,
                      state: fileVault.state, action: .fileVault, actionTitle: "查看文件保险箱",
                      required: false),
            CheckItem(id: "autologin", title: "macOS 自动登录", detail: autoLogin.detail,
                      state: autoLogin.state, action: .loginOptions, actionTitle: "查看自动登录选项",
                      required: false),
            CheckItem(id: "headless-agent", title: "登录后静默启动 App", detail: headlessRequired
                        ? (headlessAgent.ok ? headlessAgent.detail : "无显示器模式必须开启此项：登录后先静默启动 App，App 才能创建虚拟屏并让 iPad 作为主屏使用。\n\(headlessAgent.detail)")
                        : headlessAgent.detail,
                      state: headlessAgent.ok ? .good : (headlessRequired ? .action : .optional), action: headlessAction,
                      actionTitle: headlessRequired ? (headlessAgent.actionTitle == "开启静默启动" ? "立即开启" : headlessAgent.actionTitle) : headlessAgent.actionTitle,
                      required: headlessRequired)
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

    private nonisolated static func usbTransportStatus() ->
        (ok: Bool, isWired: Bool, detail: String) {
        let detector = "\(NSHomeDirectory())/.local/bin/sidecar-ipad-usb-detect.sh"
        guard commandExists(detector) else {
            return (false, false, "尚未安装 iPad 数据线检测程序；将按无线条件检查。")
        }
        let output = command(detector, [], timeout: 5)
        if output.contains("USB_IPAD_MATCHED") {
            return (true, true, "已检测到 iPad 数据线；连接一次时将优先使用有线 Sidecar。")
        }
        if output.contains("USB_IPAD_AMBIGUOUS") {
            return (false, false, "检测到多台 iPad 数据设备，请填写 USB 序列号后再连接。")
        }
        if output.contains("USB_IPAD_NOT_FOUND") {
            return (true, false, "未检测到 iPad 数据线；连接一次时将准备无线 Sidecar。")
        }
        return (false, false, "暂时无法确认 iPad 数据线状态；连接前会再次检查。")
    }

    private nonisolated static func physicalDisplayPresent() -> Bool {
        let path = "\(NSHomeDirectory())/.local/bin/display-state"
        guard commandExists(path) else { return false }
        let output = command(path, [], timeout: 5)
        return output.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("physical=") &&
                (line.split(separator: "=").last.map(String.init) ?? "0") != "0"
        }
    }

    private nonisolated static func installedRuntimeIsCurrent() -> Bool {
        let markerPath = "\(NSHomeDirectory())/.local/bin/sidecar-runtime-common.sh"
        guard let commonText = try? String(contentsOfFile: markerPath, encoding: .utf8) else {
            return false
        }
        return commonText.contains("sidecar-auto-runtime-format: 2")
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
            "sidecar-runtime-common.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-headless-display.sh",
            "sidecar-doctor.sh",
            "install-sidecar-shortcuts.sh"
        ]
        let missing = names.filter { !commandExists("\(bin)/\($0)") }
        if !missing.isEmpty {
            return (false, "缺少：\(missing.joined(separator: "、"))")
        }
        guard installedRuntimeIsCurrent() else {
            return (false, "运行时版本过旧，请点击“安装 / 修复”更新连接工具")
        }
        return (true, "核心工具已安装到 ~/.local/bin")
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

    private nonisolated static func bluetoothStatus() -> BluetoothStatus {
        let output = command("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        let lowercased = output.lowercased()
        let radioOn = lowercased.contains("attrib_on") ||
            lowercased.contains("state: on") ||
            lowercased.contains("bluetooth power: on")
        let authorizationStatus: BluetoothAuthorizationStatus
        let permissionWasRequested = bluetoothPermissionWasRequested()
        let runningFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        if #available(macOS 10.15, *) {
            // CoreBluetooth's class property can be stale when read from the
            // detached status worker immediately after returning from System
            // Settings. Read it on the main queue, where CoreBluetooth
            // delivers its authorization state changes.
            let currentAuthorization: CBManagerAuthorization
            if Thread.isMainThread {
                currentAuthorization = CBManager.authorization
            } else {
                currentAuthorization = DispatchQueue.main.sync { CBManager.authorization }
            }
            switch currentAuthorization {
            case .allowedAlways:
                authorizationStatus = .allowed
            case .denied:
                authorizationStatus = .denied
            case .restricted:
                authorizationStatus = .restricted
            case .notDetermined:
                authorizationStatus = .notDetermined
            @unknown default:
                authorizationStatus = .unknown
            }
        } else {
            authorizationStatus = .unknown
        }
        let detail: String
        if radioOn && authorizationStatus == .allowed {
            detail = "Mac 蓝牙已开启，Sidecar Auto 已获授权。"
        } else if !radioOn {
            detail = "Mac 蓝牙未开启；请打开蓝牙后重新检查。"
        } else {
            switch authorizationStatus {
            case .notDetermined:
                detail = permissionWasRequested && !runningFromApplications
                    ? "Mac 蓝牙已开启，但当前运行的是仓库/开发副本；系统设置里的授权可能属于应用程序中的另一个副本。请从 /Applications/Sidecar Auto Setup.app 启动。"
                    : permissionWasRequested
                    ? "Mac 蓝牙已开启，但授权窗口尚未完成；请打开系统设置确认当前 App。"
                    : "Mac 蓝牙已开启，首次使用请点击“申请一次”并允许。"
            case .denied, .restricted:
                detail = permissionWasRequested && !runningFromApplications
                    ? "Mac 蓝牙已开启，但当前运行的是仓库/开发副本；系统设置里的授权可能属于应用程序中的另一个副本。请从 /Applications/Sidecar Auto Setup.app 启动。"
                    : permissionWasRequested
                    ? "Mac 蓝牙已开启，但当前运行副本未获授权；请统一从 /Applications 中的 App 启动后重新检查。"
                    : "Mac 蓝牙已开启，但 App 被拒绝；请在系统设置 → 隐私与安全性 → 蓝牙中允许它。"
            case .allowed:
                detail = "Mac 蓝牙已开启，正在同步 App 授权状态。"
            case .unknown:
                detail = "Mac 蓝牙已开启，但暂时无法读取 App 授权状态。"
            }
        }
        return BluetoothStatus(
            radioOn: radioOn,
            authorization: authorizationStatus,
            permissionWasRequested: permissionWasRequested,
            runningFromApplications: runningFromApplications,
            detail: detail
        )
    }

    private nonisolated static var bluetoothPermissionMarkerURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Sidecar Auto/bluetooth-permission-requested")
    }

    private nonisolated static func bluetoothPermissionWasRequested() -> Bool {
        FileManager.default.fileExists(atPath: bluetoothPermissionMarkerURL.path)
    }

    private nonisolated static func markBluetoothPermissionRequested() {
        let url = bluetoothPermissionMarkerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("requested=1\n".utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        let detail: String
        if macHint {
            detail = "Mac 接力已开启；请在 iPad 上也开启：设置 → 通用 → 隔空播放与接力 → 接力。App 无法读取 iPad 端开关，完成后即可使用无线随航。"
        } else {
            detail = "请在 Mac：系统设置 → 通用 → 隔空投送与连续互通中开启“允许在这台 Mac 和 iCloud 设备之间使用‘接力’”；然后在 iPad：设置 → 通用 → 隔空播放与接力 → 接力中开启。App 无法远程修改 iPad 端开关。"
        }
        return (macHint, detail)
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

    private nonisolated static func betterDisplayInspection() -> String {
        let candidates = [
            "/Applications/BetterDisplay.app",
            "\(NSHomeDirectory())/Applications/BetterDisplay.app"
        ]
        let app = candidates.first { FileManager.default.fileExists(atPath: $0) }
        let externalCLI = command("/usr/bin/which", ["betterdisplaycli"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledCLI = app.map { "\($0)/Contents/MacOS/BetterDisplay" }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        let cli = externalCLI.isEmpty ? bundledCLI : externalCLI
        guard let cli else {
            return "未发现 BetterDisplay.app 或 CLI。当前可以继续使用项目内置虚拟屏；只有选择 BetterDisplay 高级方案时才需要安装它。"
        }
        let running = !command("/usr/bin/pgrep", ["-x", "BetterDisplay"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var lines = [
            "已发现：\(app ?? "BetterDisplay CLI")",
            "CLI：\(cli)",
            "进程：\(running ? "正在运行" : "未运行（只读检查不会自动启动）")"
        ]
        guard running else {
            lines.append("Pro/试用资格：需要先在有显示器时打开 BetterDisplay 后再检查")
            lines.append("虚拟屏列表：未读取（应用未运行）")
            return lines.joined(separator: "\n")
        }
        let pro = command(cli, ["get", "-proAvailable"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Pro/试用资格：\(pro.isEmpty ? "无法读取" : pro)")
        let identifiers = command(cli, ["get", "-identifiers"])
        let identifierLooksValid = identifiers.contains("[") || identifiers.contains("{")
        lines.append("虚拟屏列表：\(identifierLooksValid ? "已读取" : "无法读取")")
        lines.append("本检查只读，不会创建、启用或移动显示器。")
        return lines.joined(separator: "\n")
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
        // Releases before 0.2.2 accidentally imported the filename slug
        // (`connect-sidecar`) as the shortcut title.  Count that legacy name
        // as the connect action so an upgrade only imports the missing
        // disconnect action and does not create a duplicate connection entry.
        let connect = names.contains("连接 Sidecar") || names.contains("connect-sidecar")
        let disconnect = names.contains("断开 Sidecar") || names.contains("disconnect-sidecar")
        if connect && disconnect {
            let connectKey = shortcutKeyConfigured(slug: "connect-sidecar", equivalent: "@~^s")
            let disconnectKey = shortcutKeyConfigured(slug: "disconnect-sidecar", equivalent: "@~^d")
            if connectKey && disconnectKey {
                let connectPermission = shortcutShellPermissionGranted(slug: "connect-sidecar")
                let disconnectPermission = shortcutShellPermissionGranted(slug: "disconnect-sidecar")
                if !connectPermission || !disconnectPermission {
                    return (false, "快捷键已设置，但首次运行仍需允许“运行 Shell 脚本”；请在有屏幕时在快捷指令中各运行一次并点击“允许”，再返回重新检查")
                }
                return (true, "已找到连接和断开快捷指令；⌃⌥⌘S / ⌃⌥⌘D 已设置")
            }
            // Keep this check actionable.  A shortcut can already be present
            // while its workflow row or pbs mapping is still being persisted
            // by Shortcuts.app.  Returning `ok=true` here made the UI show
            // only “打开快捷指令”, leaving no way to retry the automatic key
            // assignment after that short race.  Mark it as needing action so
            // the existing one-click installer is offered again; the helper
            // is idempotent and will skip importing the two existing entries.
            return (false, "已找到连接和断开快捷指令，但快捷键尚未设置；点击“一键配置快捷指令”自动重试 ⌃⌥⌘S / ⌃⌥⌘D")
        }
        if connect || disconnect {
            let missing = connect ? "断开 Sidecar" : "连接 Sidecar"
            return (false, "已找到一个快捷指令，还缺少“\(missing)”；点击“一键配置快捷指令”继续")
        }
        return (false, "尚未创建“连接 Sidecar”和“断开 Sidecar”；点击“一键配置快捷指令”导入")
    }

    /// Read the same per-user service mapping that Shortcuts.app updates when
    /// a keyboard shortcut is entered in its details panel. This is a local
    /// hint only; if a future macOS release removes the SQLite/pbs entries,
    /// the shortcut remains usable from the Shortcuts app itself.
    private nonisolated static func shortcutKeyConfigured(slug: String, equivalent: String) -> Bool {
        // Shortcuts.sqlite is protected by macOS privacy controls and is not
        // readable by a normal GUI app. The installer records the workflow ID
        // after import in this app-owned status file; defaults/pbs remains
        // readable and lets us verify the key mapping without Full Disk Access.
        let statusURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Sidecar Auto/Shortcuts/\(slug).key-status")
        guard let status = try? String(contentsOf: statusURL, encoding: .utf8),
              status.split(separator: "\n").contains(where: { $0 == "configured=1" }),
              let workflowLine = status.split(separator: "\n").first(where: { $0.hasPrefix("workflow_id=") }) else {
            return false
        }
        let workflowID = workflowLine.dropFirst("workflow_id=".count)
        guard workflowID.range(of: "^[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil else { return false }
        let preferences = command("/usr/bin/defaults", ["read", "pbs", "NSServicesStatus"], timeout: 5)
        guard let idRange = preferences.range(of: String(workflowID)) else { return false }
        let entry = String(preferences[idRange.upperBound...].split(separator: "}", maxSplits: 1).first ?? "")
        return entry.contains("\"key_equivalent\" = \"\(equivalent)\";")
    }

    /// Shortcuts presents a separate first-run consent for each Run Shell
    /// Script action. The generated action sets SIDECAR_SHORTCUT_INVOCATION,
    /// and the runtime records a marker only after macOS allowed the process
    /// to start. This is deliberately a local hint: macOS has no public API
    /// for querying the consent itself, and the app never attempts to bypass it.
    private nonisolated static func shortcutShellPermissionGranted(slug: String) -> Bool {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Sidecar Auto/Shortcuts/\(slug).shell-status")
        guard let status = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return status.split(separator: "\n").contains(where: { $0 == "authorized=1" })
    }

    private nonisolated static func fileVaultStatus() ->
        (enabled: Bool, state: CheckState, detail: String) {
        let output = command("/usr/bin/fdesetup", ["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return (false, .optional,
                    "可选安全设置：无法读取文件保险箱状态；需要时可打开系统设置确认。")
        }
        if output.localizedCaseInsensitiveContains("on") {
            return (true, .optional,
                    "可选安全设置：文件保险箱已开启；冷启动必须先在解密界面输入密码。普通 App 无法代办，也不会保存或盲打密码。")
        }
        if output.localizedCaseInsensitiveContains("off") {
            return (false, .optional,
                    "可选安全设置：文件保险箱未开启；自动登录是否可用仍由 macOS 的登录选项和组织策略决定。关闭它会降低启动前保护。")
        }
        return (false, .optional,
                "可选安全设置：\(output)；冷启动登录仍由 macOS 安全策略控制。")
    }

    private nonisolated static func autoLoginStatus(fileVaultEnabled: Bool) ->
        (state: CheckState, detail: String) {
        if fileVaultEnabled {
            return (.optional,
                    "可选安全设置：文件保险箱开启时，macOS 会禁用自动登录。请按需在“用户与群组”查看状态；App 不会建议关闭启动保护。")
        }
        return (.optional,
                "可选安全设置：自动登录由 macOS 的“用户与群组”设置、账户密码和组织策略决定；App 只能打开设置页，不能保存或输入密码。")
    }

    // The login item starts this app itself. The app then prepares the
    // virtual display, so launchd has one small responsibility and there is
    // no second independent display agent to drift out of sync.
    private nonisolated static let headlessAgentLabel = "com.sidecarauto.setup"
    private nonisolated static let legacyHeadlessAgentLabel = "com.sidecarauto.headless-display"

    private nonisolated static func headlessAgentURL() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(headlessAgentLabel).plist")
    }

    private nonisolated static func legacyHeadlessAgentURL() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(legacyHeadlessAgentLabel).plist")
    }

    private nonisolated static func headlessAgentTarget() -> String {
        "gui/\(getuid())/\(headlessAgentLabel)"
    }

    private nonisolated static func legacyHeadlessAgentTarget() -> String {
        "gui/\(getuid())/\(legacyHeadlessAgentLabel)"
    }

    private nonisolated static func headlessDisplayScriptURL() -> String {
        "\(NSHomeDirectory())/.local/bin/sidecar-headless-display.sh"
    }

    private nonisolated static func appExecutableURL() -> String {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.path
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SidecarAutoSetup").path
    }

    private nonisolated static func headlessAgentIsLoaded() -> Bool {
        execute(executable: "/bin/launchctl", arguments: ["print", headlessAgentTarget()]).status == 0
    }

    private nonisolated static func headlessAgentStatus(config: SetupConfig) ->
        (ok: Bool, detail: String, actionTitle: String) {
        guard config.virtualDisplayBackend != .betterdisplay else {
            return (false,
                    "当前选择 BetterDisplay；项目内置虚拟屏自动准备不适用，请在 BetterDisplay 中设置登录启动。",
                    "打开 BetterDisplay")
        }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            return (false,
                    "请先把 Sidecar Auto Setup.app 拖到“应用程序”，再开启登录后静默启动；登录项不能指向 DMG 或临时副本。",
                    "打开应用程序")
        }
        guard FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/.local/bin/sidecar-virtual-display") else {
            return (false, "尚未安装项目内置虚拟屏工具；请先点击“安装 / 修复工具”。", "安装 / 修复工具")
        }
        guard FileManager.default.isExecutableFile(atPath: headlessDisplayScriptURL()) else {
            return (false, "尚未安装登录后虚拟屏脚本；请先点击“安装 / 修复工具”。", "安装 / 修复工具")
        }
        if !config.autoStartHeadlessDisplay {
            return (false, "未开启；登录后不会静默启动 Sidecar Auto，也不会在无实体显示器时准备虚拟屏。", "开启静默启动")
        }
        if headlessAgentIsLoaded() {
            return (true, "已开启：登录进入桌面后会静默启动 Sidecar Auto；没有实体显示器时由 App 准备项目内置虚拟屏，不会自动连接或断开 iPad。", "停用静默启动")
        }
        if FileManager.default.fileExists(atPath: headlessAgentURL().path) {
            return (false, "已创建 Sidecar Auto 登录项但当前未加载；点击按钮可重新加载。", "重新加载")
        }
        return (false, "已开启配置但 Sidecar Auto 登录项尚未加载；无显示器模式必须点击此处启用静默启动。", "开启静默启动")
    }

    private nonisolated static func headlessAgentPlist() -> Data? {
        let logBase = "\(NSHomeDirectory())/Library/Logs/sidecar-auto-login"
        let object: [String: Any] = [
            "Label": headlessAgentLabel,
            "ProgramArguments": [appExecutableURL()],
            "EnvironmentVariables": ["SIDECAR_AUTO_LOGIN_START": "1"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "\(logBase).out.log",
            "StandardErrorPath": "\(logBase).err.log"
        ]
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private nonisolated static func setHeadlessAgent(enabled: Bool) -> ProcessResult {
        let url = headlessAgentURL()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if enabled {
                guard manager.isExecutableFile(atPath: appExecutableURL()),
                      manager.isExecutableFile(atPath: headlessDisplayScriptURL()),
                      manager.isExecutableFile(atPath: "\(NSHomeDirectory())/.local/bin/sidecar-virtual-display"),
                      let data = headlessAgentPlist() else {
                    return ProcessResult(status: 127, output: "找不到 Sidecar Auto 或虚拟屏运行时，请先完成安装 / 修复工具。")
                }
                try data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                _ = execute(executable: "/bin/launchctl", arguments: ["bootout", headlessAgentTarget()])
                _ = execute(executable: "/bin/launchctl", arguments: ["bootout", legacyHeadlessAgentTarget()])
                try? manager.removeItem(at: legacyHeadlessAgentURL())
                // Older development builds exposed a separate spoken
                // login-ready agent. Remove it when the silent app startup is
                // enabled so two login items cannot compete for the session.
                _ = execute(executable: "/bin/launchctl", arguments: ["bootout", loginAgentTarget()])
                try? manager.removeItem(at: loginAgentURL())
                let loaded = execute(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", url.path])
                guard loaded.status == 0 else {
                    return ProcessResult(status: loaded.status, output: loaded.output.isEmpty ? "launchctl bootstrap 失败" : loaded.output)
                }
                return ProcessResult(status: 0, output: "Sidecar Auto 登录后静默启动已加载。")
            }
            _ = execute(executable: "/bin/launchctl", arguments: ["bootout", headlessAgentTarget()])
            _ = execute(executable: "/bin/launchctl", arguments: ["bootout", legacyHeadlessAgentTarget()])
            try? manager.removeItem(at: url)
            try? manager.removeItem(at: legacyHeadlessAgentURL())
            return ProcessResult(status: 0, output: "Sidecar Auto 登录后静默启动已停用。")
        } catch {
            return ProcessResult(status: 1, output: error.localizedDescription)
        }
    }

    private func syncHeadlessAgentAfterInstall() {
        let shouldEnable = config.autoStartHeadlessDisplay && config.virtualDisplayBackend != .betterdisplay
        let worker = Task.detached(priority: .userInitiated) {
            Self.setHeadlessAgent(enabled: shouldEnable)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.message = result.status == 0
                ? (shouldEnable ? "安装完成，并已开启 Sidecar Auto 登录后静默启动。" : "安装完成；当前虚拟屏方案不需要项目内置登录启动。")
                : "安装完成，但登录后静默启动设置失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            if result.status == 0, shouldEnable {
                self.startHeadlessDisplayAfterLaunch()
            }
            self.refresh()
        }
    }

    private func toggleHeadlessAgent() {
        guard !isManagingHeadlessAgent else { return }
        isManagingHeadlessAgent = true
        let enable = !Self.headlessAgentIsLoaded()
        config.autoStartHeadlessDisplay = enable
        do {
            try writeConfig(config)
        } catch {
            isManagingHeadlessAgent = false
            message = "自动准备设置保存失败：\(error.localizedDescription)"
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            Self.setHeadlessAgent(enabled: enable)
        }
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.isManagingHeadlessAgent = false
            self.message = result.status == 0
                ? (enable ? "已开启 Sidecar Auto 登录后静默启动。没有实体显示器时，App 登录后会先创建虚拟屏，但不会自动连接 iPad。"
                          : "已停用 Sidecar Auto 登录后静默启动。")
                : "登录后静默启动设置失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            self.refresh()
        }
    }

    private nonisolated static let loginAgentLabel = "com.sidecarauto.login-ready"

    private nonisolated static func loginAgentURL() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(loginAgentLabel).plist")
    }

    private nonisolated static func loginAgentTarget() -> String {
        "gui/\(getuid())/\(loginAgentLabel)"
    }

    private nonisolated static func loginReadyScriptURL() -> String {
        "\(NSHomeDirectory())/.local/bin/sidecar-login-ready.sh"
    }

    private nonisolated static func loginAgentIsLoaded() -> Bool {
        execute(executable: "/bin/launchctl", arguments: ["print", loginAgentTarget()]).status == 0
    }

    private nonisolated static func loginAgentStatus() -> (ok: Bool, detail: String) {
        let plistExists = FileManager.default.fileExists(atPath: loginAgentURL().path)
        let scriptExists = FileManager.default.isExecutableFile(atPath: loginReadyScriptURL())
        guard scriptExists else {
            return (false, "尚未安装登录提示脚本；先点击“安装 / 修复工具”。")
        }
        if loginAgentIsLoaded() {
            return (true, "已开启：每次用户登录后播报桌面已准备好；不会自动连接或抢占 iPad。")
        }
        if plistExists {
            return (false, "已创建登录项但当前未加载；点击“开启提示”可重新加载。")
        }
        return (false, "未开启登录后提示；这是可选项，不影响手动连接和快捷键。")
    }

    private nonisolated static func loginAgentPlist() -> Data? {
        let logBase = "\(NSHomeDirectory())/Library/Logs/sidecar-auto-login-ready"
        let object: [String: Any] = [
            "Label": loginAgentLabel,
            "ProgramArguments": [loginReadyScriptURL()],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "\(logBase).out.log",
            "StandardErrorPath": "\(logBase).err.log"
        ]
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private nonisolated static func setLoginAgent(enabled: Bool) -> ProcessResult {
        let url = loginAgentURL()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if enabled {
                guard manager.isExecutableFile(atPath: loginReadyScriptURL()),
                      let data = loginAgentPlist() else {
                    return ProcessResult(status: 127, output: "找不到登录提示脚本，请先安装 / 修复工具。")
                }
                try data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                _ = execute(executable: "/bin/launchctl", arguments: ["bootout", loginAgentTarget()])
                let loaded = execute(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", url.path])
                guard loaded.status == 0 else {
                    return ProcessResult(status: loaded.status, output: loaded.output.isEmpty ? "launchctl bootstrap 失败" : loaded.output)
                }
                return ProcessResult(status: 0, output: "登录后提示已加载。")
            }
            _ = execute(executable: "/bin/launchctl", arguments: ["bootout", loginAgentTarget()])
            try? manager.removeItem(at: url)
            return ProcessResult(status: 0, output: "登录后提示已停用。")
        } catch {
            return ProcessResult(status: 1, output: error.localizedDescription)
        }
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    private nonisolated static func execute(executable: String, arguments: [String], pidFile: String? = nil) -> ProcessResult {
        let process = Process()
        // Drain output concurrently and retain only a bounded prefix. This
        // prevents both pipe-buffer deadlocks and unbounded temporary-file
        // growth when a helper emits continuously.
        let outputPipe = Pipe()
        let outputReadHandle = outputPipe.fileHandleForReading
        let outputLimit = 1_048_576
        let outputLock = NSLock()
        var captured = Data()
        let reader = DispatchWorkItem {
            while true {
                do {
                    guard let data = try outputReadHandle.read(upToCount: 16_384), !data.isEmpty else {
                        break
                    }
                    outputLock.lock()
                    if captured.count < outputLimit {
                        captured.append(data.prefix(outputLimit - captured.count))
                    }
                    outputLock.unlock()
                } catch {
                    // The child may close its output unexpectedly. Treat that
                    // as end-of-stream so a diagnostic helper cannot abort the
                    // whole SwiftUI process while the UI is still usable.
                    break
                }
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: reader)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var pidURL: URL?
        do {
            try process.run()
            if let pidFile {
                let url = URL(fileURLWithPath: pidFile)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "\(process.processIdentifier)\n".write(to: url, atomically: true, encoding: .utf8)
                pidURL = url
            }
            process.waitUntilExit()
            // Close the parent's write end first, then let the reader observe
            // EOF and finish. Closing the read end while readData(ofLength:)
            // is blocked raises an Objective-C exception on recent macOS and
            // was the cause of the App's crash reports.
            try? outputPipe.fileHandleForWriting.close()
            reader.wait()
            try? outputReadHandle.close()
            outputLock.lock()
            let output = String(data: captured, encoding: .utf8) ?? ""
            outputLock.unlock()
            if let pidURL { try? FileManager.default.removeItem(at: pidURL) }
            return ProcessResult(status: process.terminationStatus, output: output)
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            reader.wait()
            try? outputReadHandle.close()
            if let pidURL { try? FileManager.default.removeItem(at: pidURL) }
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
            "sidecar-runtime-common.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-headless-display.sh",
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
            "sidecar-runtime-common.sh",
            "sidecar-ipad-usb-detect.sh",
            "sidecar-disconnect-once.sh",
            "sidecar-hotkey.sh",
            "sidecar-login-ready.sh",
            "sidecar-headless-display.sh",
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
    @ObservedObject var model: SetupModel
    let appDelegate: SidecarAutoAppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var section: SetupSection = .overview
    @AppStorage("sidecarAutoSetupHasSeenWizard") private var hasSeenWizard = false
    @State private var showingWizard = false
    @State private var showAdvancedChecks = false

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
        .sheet(isPresented: $showingWizard) {
            SetupWizardView(model: model, section: $section) {
                hasSeenWizard = true
                showingWizard = false
            }
        }
        .onAppear {
            appDelegate.registerMainWindowOpener {
                openWindow(id: "main")
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
            if !hasSeenWizard { showingWizard = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AppMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidecar Auto").font(.headline)
                    Text("无显示器连接助手").font(.caption).foregroundStyle(.secondary)
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
        let total = model.requiredCount
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
                Text(section == .overview ? "让没有显示器的 Mac mini 把 iPad 作为主屏使用。" : model.message)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
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
            updatePanel
        }
    }

    private var updatePanel: some View {
        Panel {
            PanelTitle(title: "应用更新", subtitle: "当前版本 v\(model.currentAppVersion)；检查后可下载最新 arm64 DMG。", symbol: "arrow.down.circle")
            HStack(alignment: .top, spacing: 12) {
                Text(model.updateMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(model.isCheckingForUpdates ? "检查中…" : "检查更新") {
                    model.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)
            }
            if let update = model.availableUpdate {
                HStack(spacing: 10) {
                    Label("发现 v\(update.version)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(model.isDownloadingUpdate ? "下载中…" : "下载 DMG") {
                        model.downloadLatestUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isDownloadingUpdate)
                    Button("打开 Release") { model.openLatestReleasePage() }
                        .buttonStyle(.bordered)
                        .disabled(model.isDownloadingUpdate)
                }
                Text("下载完成后退出当前 App，把新版本拖到“应用程序”并重新打开。无显示器模式请确认新版本中的“登录后静默启动”仍已开启。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heroCard: some View {
        HStack(spacing: 18) {
            AppMark(size: 68)
            VStack(alignment: .leading, spacing: 7) {
                Text("让你的 Mac mini 使用 iPad 作为主屏").font(.title.bold())
                Text("专为无显示器使用场景设计。先完成一次配置，之后只需按快捷键，Sidecar Auto 会根据数据线和网络状态自动选择连接方式。")
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
        let total = model.requiredCount
        let passed = model.goodCount
        return Panel {
            PanelTitle(title: "当前状态", subtitle: "Mac 本机检查与 iPad 端确认分开显示。", symbol: "checkmark.shield")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(total == 0 ? "—" : "\(passed)")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Color.sidecarBlue)
                Text(total == 0 ? "正在检查" : "项已通过（Mac）").foregroundStyle(.secondary)
            }
            ProgressView(value: total == 0 ? 0 : Double(passed) / Double(total)).tint(Color.sidecarBlue)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label("Mac 本机", systemImage: passed == total && total > 0 ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(passed == total && total > 0 ? .green : .secondary)
                Label("iPad 端待确认", systemImage: "ipad")
                    .foregroundStyle(.orange)
                Text("请在 iPad：设置 → 通用 → 隔空播放与接力 → 开启“接力”，并保持 iPad 解锁。App 无法从 Mac 读取 iPad 端开关。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nextStepCard: some View {
        Panel {
            PanelTitle(title: "建议步骤", subtitle: "按顺序完成即可。", symbol: "list.number")
            VStack(alignment: .leading, spacing: 11) {
                StepLine(number: 1, title: "填写 iPad 名称", done: !model.config.iPadName.isEmpty)
                StepLine(number: 2, title: "保存连接设置", done: model.checks.contains(where: { $0.id == "config" && $0.state == .good }))
                StepLine(number: 3, title: "完成环境检查",
                         done: model.requiredCount > 0 && model.goodCount == model.requiredCount)
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
                    let shortcutNeedsConsent = model.checks.first {
                        $0.id == "shortcuts" && $0.detail.contains("首次运行")
                    } != nil
                    Button { model.perform(shortcutNeedsConsent ? .shortcuts : .installShortcuts) } label: {
                        Label(shortcutNeedsConsent ? "完成快捷指令授权" : "一键配置快捷指令",
                              systemImage: shortcutNeedsConsent ? "checkmark.shield" : "keyboard.badge.ellipsis")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstalling || model.isOperating)
                }
                Button { section = .test } label: { Label("打开手动测试", systemImage: "play.circle") }
                    .buttonStyle(.bordered)
                Button {
                    hasSeenWizard = false
                    showingWizard = true
                } label: { Label("重新打开配置向导", systemImage: "wand.and.stars") }
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
                    HStack(spacing: 10) {
                        Button {
                            model.scanConnectedIPad()
                        } label: {
                            Label(model.isScanningIPad ? "扫描中…" : "扫描已连接 iPad",
                                  systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isScanningIPad || model.isInstalling || model.isOperating)
                        if model.isScanningIPad { ProgressView().controlSize(.small) }
                    }
                    if !model.scanMessage.isEmpty {
                        Label(model.scanMessage, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.usbCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("检测到的 USB iPad").font(.caption.weight(.semibold))
                            Picker("选择目标 iPad", selection: $model.config.usbSerial) {
                                Text("请选择…").tag("")
                                ForEach(model.usbCandidates.filter { !$0.serial.isEmpty }) { candidate in
                                    Text(candidate.serial.isEmpty
                                         ? candidate.name
                                         : "\(candidate.name) · \(candidate.serial)")
                                        .tag(candidate.serial)
                                }
                            }
                            .pickerStyle(.menu)
                            Text("USB 产品名只是硬件描述；Sidecar 名称仍以 macOS 显示为准。")
                                .font(.caption2).foregroundStyle(.secondary)
                            if model.usbCandidates.allSatisfy({ $0.serial.isEmpty }) {
                                Text("这些 USB 设备没有可用序列号；请只连接目标 iPad，或使用无线连接。")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Panel {
                PanelTitle(title: "无显示器虚拟屏", subtitle: "拔掉显示器后，连接时按需创建，不会一直占用屏幕。", symbol: "rectangle.on.rectangle")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("使用方案", selection: $model.config.virtualDisplayBackend) {
                        ForEach(VirtualDisplayBackend.allCases) { backend in Text(backend.title).tag(backend) }
                    }.pickerStyle(.radioGroup)
                    if model.config.virtualDisplayBackend == .betterdisplay {
                        LabeledContent("BetterDisplay 屏幕名称") {
                            TextField("可选", text: $model.config.virtualDisplayName)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        }
                    }
                    Text("项目内置方案固定为 1920×1080、60Hz；BetterDisplay 支持更多分辨率和布局参数。内置方案依赖 macOS 的系统接口，系统升级后如遇兼容问题可切换方案。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("登录后静默启动 Sidecar Auto（无显示器必需）", isOn: $model.config.autoStartHeadlessDisplay)
                    Text("如果 Mac 没有实体显示器，必须开启此项并保存：登录进入 macOS 桌面后会静默启动本 App，由 App 创建虚拟屏，让 iPad 能作为主屏使用。它不会自动连接或断开 iPad，也不需要辅助功能或屏幕录制权限。")
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
            PageIntro(text: "这里只显示当前连接路径真正相关的状态。打开 App、刷新和关闭窗口都不会连接或断开 iPad；需要处理的项目会提供对应按钮。")
            if model.checks.isEmpty {
                Panel { HStack { ProgressView(); Text("正在读取本机状态……").foregroundStyle(.secondary) } }
            } else {
                connectionReadinessPanel
                checkGroup(
                    title: wiredTransport ? "本次有线连接需要" : "本次无线连接需要",
                    subtitle: wiredTransport
                        ? "已检测到 iPad 数据线，连接时会优先使用 USB；Wi‑Fi、蓝牙和接力不会阻塞这次有线连接。"
                        : "未检测到 iPad 数据线，连接时会使用无线 Sidecar。Mac 端状态可在这里读取，iPad 端接力仍需你在 iPad 上确认。",
                    ids: requiredCheckIDs
                )
                DisclosureGroup(isExpanded: $showAdvancedChecks) {
                    VStack(alignment: .leading, spacing: 14) {
                        if !optionalCheckIDs.isEmpty {
                            checkGroup(
                                title: "快捷指令",
                                subtitle: "只在你需要键盘快捷键时配置；不会自动连接 iPad。",
                                ids: optionalCheckIDs
                            )
                        }
                        securitySettingsPanel
                        betterDisplayInspectionPanel
                        headlessAgentPanel
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label("可选诊断和高级功能", systemImage: "ellipsis.circle")
                            .font(.headline)
                        Spacer()
                        Text(optionalSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !model.installerLog.isEmpty { installerPanel }
        }
    }

    private var wiredTransport: Bool {
        model.checks.first(where: { $0.id == "transport" })?.detail.contains("已检测到 iPad 数据线") == true
    }

    private var requiredCheckIDs: [String] {
        let required = Set(model.checks.filter(\.required).map(\.id))
        let preferred = ["mac", "runtime", "config", "transport", "wifi", "bluetooth", "handoff",
                         "builtin-virtual", "betterdisplay", "headless-agent"]
        return preferred.filter { required.contains($0) }
    }

    private var optionalCheckIDs: [String] {
        let optional = Set(model.checks.filter { !$0.required }.map(\.id))
        let preferred = ["shortcuts"]
        return preferred.filter { optional.contains($0) }
    }

    private var optionalSummary: String {
        let items = model.checks.filter { !$0.required }
        let ready = items.filter { $0.state == .good || $0.state == .partial }.count
        if items.isEmpty { return "按需查看" }
        return "\(ready)/\(items.count) 已确认 · 不影响连接"
    }

    private var connectionReadinessPanel: some View {
        let total = model.requiredCount
        let passed = model.goodCount
        return Panel {
            PanelTitle(
                title: wiredTransport ? "有线连接路径" : "无线连接路径",
                subtitle: wiredTransport ? "USB iPad 已识别" : "未检测到 USB iPad，将按无线条件连接",
                symbol: wiredTransport ? "cable.connector" : "wifi"
            )
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(total == 0 ? "—" : "\(passed)/\(total)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.sidecarBlue)
                Text("Mac 端状态已确认").foregroundStyle(.secondary)
                Spacer()
                if !wiredTransport {
                    Text("iPad 端接力需要在 iPad 上开启")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            ProgressView(value: total == 0 ? 0 : Double(passed) / Double(total)).tint(Color.sidecarBlue)
            Text(wiredTransport
                 ? "当前只需保持 iPad 解锁并信任这台 Mac。拔掉数据线后，App 会自动改用无线条件。"
                 : "请在 iPad：设置 → 通用 → 隔空播放与接力 → 开启“接力”，并保持 iPad 解锁。App 无法从 Mac 读取 iPad 端开关。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var securitySettingsPanel: some View {
        let fileVault = model.checks.first(where: { $0.id == "filevault" })
        let autoLogin = model.checks.first(where: { $0.id == "autologin" })
        return Panel {
            PanelTitle(title: "启动安全设置", subtitle: "可选；不会阻塞 Sidecar，也不会由 App 保存或输入密码。", symbol: "lock.shield")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: fileVault?.state.symbol ?? CheckState.optional.symbol)
                        .foregroundStyle(fileVault?.state.color ?? CheckState.optional.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件保险箱（FileVault）").font(.body.weight(.semibold))
                        Text(fileVault?.detail ?? "正在读取状态……")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let fileVault, let action = fileVault.action {
                        Button(fileVault.actionTitle ?? "查看") { model.perform(action) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: autoLogin?.state.symbol ?? CheckState.optional.symbol)
                        .foregroundStyle(autoLogin?.state.color ?? CheckState.optional.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS 自动登录").font(.body.weight(.semibold))
                        Text(autoLogin?.detail ?? "正在读取状态……")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let autoLogin, let action = autoLogin.action {
                        Button(autoLogin.actionTitle ?? "查看") { model.perform(action) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private var betterDisplayInspectionPanel: some View {
        Panel {
            PanelTitle(title: "BetterDisplay 检查向导", subtitle: "只读取安装、运行和能力状态，不会创建或移动虚拟屏。", symbol: "display.2")
            HStack(alignment: .top, spacing: 12) {
                Text(model.betterDisplayReport)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(model.isInspectingBetterDisplay ? "检查中…" : "检查 BetterDisplay") {
                    model.inspectBetterDisplay()
                }
                .buttonStyle(.bordered)
                .disabled(model.isInspectingBetterDisplay || model.isInstalling || model.isOperating)
            }
        }
    }

    private var headlessAgentPanel: some View {
        Panel {
            PanelTitle(title: "登录后静默启动（无显示器必需）", subtitle: "没有实体显示器时必须开启；登录时启动 App，由 App 准备虚拟屏。", symbol: "display.2")
            let headlessAgent = model.checks.first(where: { $0.id == "headless-agent" })
            HStack(alignment: .top, spacing: 12) {
                Text(headlessAgent?.detail ?? "正在读取登录项状态……")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let headlessAgent, let action = headlessAgent.action {
                    Button(model.isManagingHeadlessAgent ? "处理中…" : (headlessAgent.actionTitle ?? "开启静默启动")) {
                        model.perform(action)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isManagingHeadlessAgent || model.isInstalling || model.isOperating)
                }
            }
        }
    }

    @ViewBuilder
    private func checkGroup(title: String, subtitle: String, ids: [String]) -> some View {
        let items = ids.compactMap { id in model.checks.first(where: { $0.id == id }) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    CheckRow(item: item) { action in model.perform(action) }
                }
            }
        }
    }

    private var testPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageIntro(text: "连接和断开只会在你点击按钮后执行一次。\(model.connectionPrerequisiteSummary) 测试时请确保 iPad 已解锁，并准备好接受 Sidecar。")
            Panel {
                PanelTitle(title: "连接控制", subtitle: model.isOperating ? "正在执行，请稍候……" : "不会设置后台自动抢占。", symbol: "rectangle.connected.to.line.below")
                if model.isOperating {
                    Label(model.operationStage, systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.semibold)).foregroundStyle(Color.sidecarBlue)
                }
                HStack(spacing: 12) {
                    Button { model.connect() } label: { Label("连接一次", systemImage: "rectangle.connected.to.line.below") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isOperating || model.isInstalling || !model.canRunConnection)
                    Button { model.disconnect() } label: { Label("断开一次", systemImage: "rectangle.portrait.and.arrow.right") }
                        .buttonStyle(.bordered).disabled(model.isOperating || model.isInstalling || !model.canRunConnection)
                    if model.isOperating { ProgressView().controlSize(.small) }
                    if model.isOperating {
                        Button("取消") { model.cancelOperation() }
                            .buttonStyle(.bordered)
                            .disabled(model.isCancelRequested)
                    }
                }
                if !model.canRunConnection {
                    Label(model.connectionPrerequisiteSummary, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.operationLog.isEmpty { logPanel(title: "最近一次操作输出", text: model.operationLog) }
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

private struct SetupWizardView: View {
    @ObservedObject var model: SetupModel
    @Binding var section: SetupSection
    let finish: () -> Void
    @State private var step = 0

    private let steps = ["选择 iPad", "准备无线条件", "配置快捷键", "完成测试"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                AppMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("首次配置 Sidecar Auto").font(.title2.bold())
                    Text("完成一次设置后，日常只需按快捷键连接。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ProgressView(value: Double(step), total: Double(steps.count - 1))
                .tint(Color.sidecarBlue)
            Text("第 \(step + 1) 步：\(steps[step])")
                .font(.headline)
            wizardContent
            Spacer(minLength: 4)
            HStack {
                Button("稍后配置") { finish() }
                    .buttonStyle(.bordered)
                Spacer()
                if step > 0 {
                    Button("上一步") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                if step < steps.count - 1 {
                    Button("下一步") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("完成并进入概览") { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
        .frame(width: 620, height: 470)
    }

    @ViewBuilder private var wizardContent: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 14) {
                Text("先连接并解锁 iPad。连接 USB 数据线后点击扫描，助手会读取 USB 设备并自动填入序列号；Sidecar 名称仍请以 macOS 显示的名称为准，也可以直接填写名称使用无线连接。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("iPad 名称", text: $model.config.iPadName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.scanConnectedIPad()
                    } label: {
                        Label(model.isScanningIPad ? "扫描中…" : "扫描 iPad", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isScanningIPad || model.isInstalling || model.isOperating)
                }
                TextField("USB 序列号（可选）", text: $model.config.usbSerial)
                    .textFieldStyle(.roundedBorder)
                if !model.scanMessage.isEmpty {
                    Text(model.scanMessage).font(.caption).foregroundStyle(.secondary)
                }
                if !model.usbCandidates.isEmpty {
                    Picker("选择 USB iPad", selection: $model.config.usbSerial) {
                        Text("请选择…").tag("")
                        ForEach(model.usbCandidates.filter { !$0.serial.isEmpty }) { candidate in
                            Text(candidate.serial.isEmpty
                                 ? candidate.name
                                 : "\(candidate.name) · \(candidate.serial)")
                                .tag(candidate.serial)
                        }
                    }
                    .pickerStyle(.menu)
                    if model.usbCandidates.allSatisfy({ $0.serial.isEmpty }) {
                        Text("USB 设备没有可用序列号，请只连接目标 iPad。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Button("保存当前连接设置") { model.saveConfig() }
                    .buttonStyle(.borderedProminent)
            }
        case 1:
            VStack(alignment: .leading, spacing: 14) {
                Label("Mac 侧准备", systemImage: model.bluetoothReady ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.bluetoothReady ? .green : .secondary)
                Button(model.bluetoothReady ? "重新检查蓝牙" : "申请 / 开启蓝牙") {
                    model.requestBluetoothAccess()
                }
                .buttonStyle(.borderedProminent)
                Text("无线连接还需要两台设备都打开 Wi‑Fi、蓝牙和接力。Mac 的接力可以在环境检查中打开；iPad 端必须手动进入：设置 → 通用 → 隔空播放与接力 → 接力。此 App 无法从 Mac 读取 iPad 开关。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("有线连接不需要路由器，也不会因 iPad 端接力未确认而阻塞。", systemImage: "cable.connector")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case 2:
            VStack(alignment: .leading, spacing: 14) {
                Text("助手会导入“连接 Sidecar”和“断开 Sidecar”两个快捷指令，并尝试设置 ⌃⌥⌘S / ⌃⌥⌘D。首次运行时，macOS 仍会要求你在有屏幕时点击允许。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("一键配置快捷指令") { model.perform(.installShortcuts) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstalling || model.isOperating)
                if !model.installerLog.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text("最后做一次手动测试。连接时会自动判断 USB 数据线；没有数据线时才准备无线连接。没有显示器时会按你的方案创建虚拟屏。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开手动测试") {
                    section = .test
                    finish()
                }
                    .buttonStyle(.borderedProminent)
                Label("请保持 iPad 解锁。测试只执行一次，不会在后台自动重连。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    StatusPill(state: item.state, itemID: item.id)
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let itemAction = item.action, let title = item.actionTitle,
               item.state != .good || itemAction != .refresh {
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
    let itemID: String
    var body: some View {
        Text(
            itemID == "handoff" && state == .good ? "Mac 已开启 · iPad 待确认"
                : state == .good ? "正常"
                : state == .partial ? "Mac 已开启 · iPad 待确认"
                : state == .permission ? "需 App 授权"
                : state == .action ? "需要处理"
                : state == .warning ? "注意"
                : state == .optional ? "可选"
                : "需确认"
        )
            .font(.caption2.weight(.semibold)).foregroundStyle(state.color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(state.color.opacity(0.12), in: Capsule())
    }
}
