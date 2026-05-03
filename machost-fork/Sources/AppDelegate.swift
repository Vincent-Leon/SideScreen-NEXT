import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
@preconcurrency import ScreenCaptureKit

// MARK: - i18n helper
// 简化版 i18n：根据系统语言偏好从两个字面量里选一个。中文系统（语言代码以 "zh" 开头）
// 用第二个参数，其他用第一个（英文）。Module 内通用，AppDelegate 与 SettingsWindow 共用。
internal let isZHLocale: Bool = {
    let lang = Locale.current.language.languageCode?.identifier ?? "en"
    return lang == "zh"
}()

internal func L(_ en: String, _ zh: String) -> String {
    return isZHLocale ? zh : en
}

// Debug file logger - writes to /tmp/sidescreen.log
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    print(message)
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/sidescreen.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Server State Machine

/// Server lifecycle. Transitions are serialized on the @MainActor.
///
/// - .idle → .listening: user clicks Start
/// - .listening → .starting: client first connects (probe or real)
/// - .starting → .streaming: virtualDisplay + capture ready, frames flowing
/// - .starting → .listening: client disconnected before stream came up (e.g. probe)
/// - .streaming → .listening: client disconnected (lock screen, USB pull)
/// - .listening / .streaming → .stopping → .idle: user clicks Stop
enum ServerState {
    case idle
    case listening
    case starting
    case streaming
    case stopping
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    /// Minimum total movement (either axis) before a 2-finger gesture is classified.
    /// Higher = harder to trigger but resists touchscreen jitter.
    static let twoFingerActivateDistance: CGFloat = 25
    /// One axis must be ≥ ratio × the other to win classification; else stay ambiguous.
    static let twoFingerAxisRatio: CGFloat = 1.4
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
    /// Hold time before a pointerCount change (1↔2) is committed. Filters out
    /// touchscreen spurious second-pointer blips during a 1-finger drag.
    static let pointerCountHoldNs: UInt64 = 60_000_000  // 60ms
}

@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    /// Server lifecycle state. All transitions on @MainActor.
    @MainActor private var state: ServerState = .idle
    /// In-flight stream startup task — cancellable so probe disconnects (or stopServer)
    /// can interrupt before resources are created.
    @MainActor private var pendingStartStream: Task<Void, Never>?
    /// Reentry guard: prevents double-Start race that creates a stranded second
    /// streamingServer (encoder pipes frames to it but its bind() failed).
    /// Always read/written on the main thread (where onToggleServer fires).
    private var startInFlight: Bool = false
    private var permissionCheckTimer: Timer?
    /// HDC reverse tunnel auto-recovery (HarmonyOS device equivalent of adb reverse).
    /// Polls every few seconds while server is up; re-runs `hdc rport` when the
    /// tunnel is missing (e.g. MatePad just plugged in, or hap reinstall flushed it).
    private var hdcMonitorTimer: DispatchSourceTimer?
    private var cachedHDCPath: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Show settings window
        showSettings()
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes (chỉ áp dụng khi encoder đang chạy)
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.screenCapture != nil else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.screenCapture != nil, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        // Observer cho rotation changes - send to connected client immediately.
        // streamingServer 在 .listening 起就存在，此处用 isRunning 判别即可（idle 时不发）。
        settings.$rotation
            .dropFirst()
            .sink { [weak self] rotation in
                guard let self = self, self.settings.isRunning else { return }
                print("🔄 Rotation changed to \(rotation)°")
                self.streamingServer?.updateRotation(rotation)
            }
            .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Virtual Display")
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning {
                Task { [weak self] in
                    await self?.stopServer()
                }
                return
            }
            // Guard against double-click / racing toggles before settings.isRunning
            // flips to true (it's only set after all the async setup completes).
            // Without this, a second click spawns a parallel startServer Task that
            // creates a second streamingServer whose bind() fails (port already in
            // use) yet ends up referenced by the encoder — frames go nowhere.
            guard !self.startInFlight else {
                debugLog("startServer ignored — start already in flight")
                return
            }
            self.startInFlight = true
            Task { [weak self] in
                await self?.startServer()
                await MainActor.run { self?.startInFlight = false }
            }
        }
    }

    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")

            // On macOS 26+, also verify ScreenCaptureKit is actually functional
            if version.majorVersion >= 26 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    debugLog("SCShareableContent verification OK — \(content.displays.count) displays found")
                } catch {
                    debugLog("WARNING: CGPreflight OK but SCShareableContent failed on macOS 26: \(error.localizedDescription)")
                    debugLog("CGDisplayStream fallback will likely activate at capture time")
                }
            }
        } else {
            debugLog("Screen recording permission not granted yet")
            // Prompt user to grant permission
            CGRequestScreenCaptureAccess()
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse() async {
        let port = settings.port
        print("🔌 Setting up ADB reverse for port \(port)...")

        await Task.detached(priority: .utility) {
            // Try common adb paths
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "~/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]

            var adbPath: String?
            for path in adbPaths {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    adbPath = expandedPath
                    break
                }
            }

            // Also try 'which adb' to find it in PATH
            if adbPath == nil {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["adb"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        adbPath = path
                    }
                } catch {
                    // Ignore
                }
            }

            guard let finalAdbPath = adbPath else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")

            // Retry adb reverse up to 3 times — handles first-install authorization delay
            for attempt in 1...3 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: finalAdbPath)
                process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        print("✅ ADB reverse setup successful: tcp:\(port) -> tcp:\(port)")
                        return
                    } else {
                        print("⚠️  ADB reverse attempt \(attempt)/3 failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                } catch {
                    print("⚠️  Failed to run ADB (attempt \(attempt)/3): \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }

            print("💡 Make sure Android device is connected via USB with debugging enabled")
        }.value
    }

    // MARK: - HDC reverse tunnel (HarmonyOS device equivalent of adb reverse)

    /// 找 hdc 二进制：优先 SideScreen.app bundle 内置（Resources/hdc/hdc），其次外部 SDK 路径。
    /// 内置版本 + libusb_shared.dylib 跟 hdc 在同目录，rpath @loader_path/. 自动解析。
    private func findHDCBinary() -> String? {
        if let cached = cachedHDCPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        // 1) Bundle 内置（最优先，开箱即用）
        if let bundled = Bundle.main.path(forResource: "hdc", ofType: nil, inDirectory: "hdc"),
           FileManager.default.fileExists(atPath: bundled) {
            // 拷贝过来时 +x 位有可能丢，主动补一下
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled)
            cachedHDCPath = bundled
            debugLog("hdc: using bundled \(bundled)")
            return bundled
        }
        // 2) 外部 SDK 路径
        let homedir = NSHomeDirectory()
        var candidates: [String] = [
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        ]
        let sdkRoot = "\(homedir)/Library/Huawei/Sdk/HarmonyOS-NEXT"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: sdkRoot) {
            for v in versions {
                candidates.append("\(sdkRoot)/\(v)/openharmony/toolchains/hdc")
            }
        }
        let ohSdkRoot = "\(homedir)/Library/OpenHarmony/Sdk"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: ohSdkRoot) {
            for v in versions {
                candidates.append("\(ohSdkRoot)/\(v)/toolchains/hdc")
            }
        }
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                cachedHDCPath = path
                debugLog("hdc: using external SDK \(path)")
                return path
            }
        }
        // 3) which hdc
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["hdc"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let p = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty, FileManager.default.fileExists(atPath: p) {
                cachedHDCPath = p
                debugLog("hdc: using PATH \(p)")
                return p
            }
        } catch { /* ignore */ }
        debugLog("hdc not found anywhere — USB tunnel will not auto-establish")
        return nil
    }

    /// 检测当前设备列表里目标 port 的 reverse 隧道是否已存在。
    private func hdcReverseAlreadySet(hdc: String, port: UInt16) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hdc)
        proc.arguments = ["fport", "ls"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // 行格式：62BBB25A29201944    tcp:8888 tcp:8888    [Reverse]
            return out.contains("[Reverse]") && out.contains("tcp:\(port) tcp:\(port)")
        } catch {
            return false
        }
    }

    /// 单次尝试建立 hdc rport（如果已存在则跳过）。
    private func setupHDCReverseOnce() {
        guard let hdc = findHDCBinary() else { return }
        let port = settings.port
        if hdcReverseAlreadySet(hdc: hdc, port: port) { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hdc)
        proc.arguments = ["rport", "tcp:\(port)", "tcp:\(port)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus == 0 || out.contains("OK") {
                debugLog("hdc rport established: tcp:\(port) → tcp:\(port)")
            } else if out.contains("not found") || out.contains("no targets") || out.contains("Empty") {
                // 设备没插 / hdc daemon 没识别到设备 — 等下次轮询
            } else {
                // 某些 hdc 版本对已存在的转发会报 "TCP Port listen failed"，是良性的，跳过日志噪音
                if !out.contains("listen failed") {
                    debugLog("hdc rport: \(out)")
                }
            }
        } catch {
            debugLog("hdc rport spawn failed: \(error.localizedDescription)")
        }
    }

    /// 启动 5s 巡检循环，每次 tick 检查 + 必要时重建。
    /// 设备插拔 / hap 重装造成的隧道丢失会被自动恢复。
    private func startHDCMonitor() {
        stopHDCMonitor()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.setupHDCReverseOnce()
        }
        timer.resume()
        hdcMonitorTimer = timer
        debugLog("HDC monitor started (5s polling)")
    }

    private func stopHDCMonitor() {
        hdcMonitorTimer?.cancel()
        hdcMonitorTimer = nil
    }

    @MainActor
    func showPermissionAlert() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26 = version.majorVersion >= 26

        let alert = NSAlert()
        if isMacOS26 {
            alert.messageText = L("Screen & System Audio Recording Permission Required",
                                  "需要屏幕和系统音频录制权限")
            alert.informativeText = L("Please grant Screen & System Audio Recording permission in System Settings > Privacy & Security.",
                                      "请在 系统设置 > 隐私与安全 中授予屏幕和系统音频录制权限。")
        } else {
            alert.messageText = L("Screen Recording Permission Required", "需要屏幕录制权限")
            alert.informativeText = L("Please grant Screen Recording permission in System Settings > Privacy & Security.",
                                      "请在 系统设置 > 隐私与安全 中授予屏幕录制权限。")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open System Settings", "打开系统设置"))
        alert.addButton(withTitle: L("Later", "稍后"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Start listener layer only — virtualDisplay + capture are lazy-built when a real
    /// client connects (see `startStream`). This way lock-screen / USB-pull events
    /// (which manifest as TCP disconnects) auto-tear-down the virtual display, and
    /// reconnects auto-rebuild it, without leaving stranded副屏图标 on Mac desktop.
    func startServer() async {
        guard settings.hasScreenRecordingPermission else {
            await showPermissionAlert()
            return
        }

        // ADB / HDC tunnels: useful from the moment we start listening so the client
        // can find us via 127.0.0.1. setupADBReverse can fail silently (no adb).
        await setupADBReverse()
        setupHDCReverseOnce()
        startHDCMonitor()

        let server = StreamingServer(port: settings.port)
        server.onClientConnected = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleClientConnected()
            }
        }
        server.onClientReady = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleClientReady()
            }
        }
        server.onClientDisconnected = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleClientDisconnected()
            }
        }
        server.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2 in
            self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2)
        }
        server.onClientRotation = { [weak self] rotation in
            guard let self = self else { return }
            Task { @MainActor in
                await self.handleClientRotation(rotation)
            }
        }
        server.onStats = { [weak self] fps, mbps in
            let captured = self
            Task { @MainActor in
                captured?.settings.currentFPS = fps
                captured?.settings.currentBitrate = mbps
            }
        }
        server.start()

        await MainActor.run {
            self.streamingServer = server
            self.state = .listening
            self.settings.isRunning = true

            // Eager mode: build virtualDisplay + capture immediately so the
            //副屏 is usable as soon as the user starts the server, even
            // before any client connects. Lazy mode (default) defers this to
            // the first real-client message via handleClientReady.
            if self.settings.eagerVirtualDisplay {
                self.state = .starting
                self.pendingStartStream?.cancel()
                self.pendingStartStream = Task { @MainActor [weak self] in
                    await self?.startStreamBody()
                }
            }
        }

        print("✅ Server listening on port \(settings.port) — waiting for client")
    }

    /// User-initiated Stop: notify any connected client (type=0x06), tear down stream
    /// + listener, return to .idle. Cancels any in-flight startStream task to avoid
    /// stranded virtualDisplay.
    func stopServer() async {
        await MainActor.run {
            self.state = .stopping
            // Cancel any in-flight stream startup (probe race window)
            self.pendingStartStream?.cancel()
        }

        // Tell client this is a polite shutdown so it returns to idle (rather than
        // entering USB-only paused state). Best-effort: brief sleep lets bytes flush
        // before we close the socket.
        streamingServer?.sendServerShutdown()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Wait for cancelled start task to finish its cleanup, if any.
        if let task = await MainActor.run(body: { self.pendingStartStream }) {
            await task.value
        }

        await MainActor.run {
            self.forceStopServerSync()
        }

        print("⏹️ Server stopped")
    }

    /// Synchronous teardown — used by applicationWillTerminate (which can't await)
    /// and by stopServer's main-actor cleanup phase. Skips sendServerShutdown.
    @MainActor
    private func forceStopServerSync() {
        pendingStartStream?.cancel()
        pendingStartStream = nil
        tearDownStreamArtifacts()
        streamingServer?.stop()
        streamingServer = nil
        stopHDCMonitor()
        state = .idle
        settings.isRunning = false
        settings.clientConnected = false
    }

    // MARK: - Stream lifecycle (lazy-built on real client connect)

    /// 一个 TCP 连接进来——我们尚不知是 probe 还是真实 client。仅切到 .starting，
    /// 等 onClientReady（首条上行消息）才真正分配 virtualDisplay + capture。
    /// Probe 永远不会发任何消息，所以不会触发 .starting → 资源分配，从根本避免
    /// 每次 probe 都建/拆一次副屏的闪烁。
    @MainActor
    private func handleClientConnected() {
        switch state {
        case .listening:
            state = .starting
            pendingStartStream?.cancel()  // defensive

        case .starting:
            // probe 后紧接真实 client，或者并发探测。state 已经是 .starting，无事可做。
            // 等 receiveLoop 触发 onClientReady。
            break

        case .streaming:
            // 快速换 client（旧 client 断开 + 新 client 连上的极小窗口期）：stream 已起，
            // 只需要给新 client 推 displayConfig + 强制下一帧 IDR。
            screenCapture?.requestKeyframe()
            streamingServer?.sendDisplaySize()
            settings.clientConnected = true

        case .idle, .stopping:
            debugLog("client connect ignored — state=\(state)")
        }
    }

    /// 收到客户端首条上行消息（rotation/ping）——确认是真实 client，开始分配资源。
    /// Probe 不会触发本回调，所以这里跑到的都是真 client。
    @MainActor
    private func handleClientReady() {
        switch state {
        case .starting:
            // 只在没有 in-flight 任务时才 spawn。eager 模式下 startServer 已经
            // 起了一个 startStreamBody，让它跑完就行；不要 cancel + respawn。
            if pendingStartStream == nil {
                pendingStartStream = Task { @MainActor [weak self] in
                    await self?.startStreamBody()
                }
            }
        case .streaming:
            // 已经在跑。可能是新 client 切换后又发了一条 rotation/ping，
            // 或者 eager 模式下 client 终于连上来了。
            // 推一次 displayConfig + IDR 让它立刻能解码当前帧。
            screenCapture?.requestKeyframe()
            streamingServer?.sendDisplaySize()
        case .listening, .idle, .stopping:
            debugLog("client ready ignored — state=\(state)")
        }
    }

    @MainActor
    private func handleClientDisconnected() {
        switch state {
        case .starting:
            // Probe disconnected (or stream startup failed during sleep). Cancel the
            // in-flight task; nothing was created yet so tearDown is a no-op.
            pendingStartStream?.cancel()
            tearDownStreamArtifacts()
            settings.clientConnected = false
            if settings.eagerVirtualDisplay {
                // Eager mode: rebuild the virtual display so it's ready when next
                // client (or local Mac use) needs it.
                state = .starting
                pendingStartStream = Task { @MainActor [weak self] in
                    await self?.startStreamBody()
                }
            } else {
                state = .listening
            }

        case .streaming:
            settings.clientConnected = false
            if settings.eagerVirtualDisplay {
                // Eager: keep stream alive — encoder keeps running but sendFrame
                // is a no-op when no client fd is connected. Virtual display
                // stays available on Mac for local use / next client.
                print("ℹ️ Client disconnected — eager mode, virtual display kept up")
            } else {
                // Lazy: lock screen / USB pull / network drop → kill virtualDisplay
                // + capture, keep listener for next reconnect.
                tearDownStreamArtifacts()
                state = .listening
                print("ℹ️ Client disconnected — virtual display destroyed, listener kept")
            }

        case .listening, .idle, .stopping:
            settings.clientConnected = false
        }
    }

    /// Body of the cancellable startStream task. Builds virtualDisplay + capture +
    /// kicks off encoding. On cancellation or failure, leaves the system in a clean
    /// .listening state (or .idle if stopServer cancelled us).
    @MainActor
    private func startStreamBody() async {
        defer { pendingStartStream = nil }

        // No probe-eat sleep: handleClientReady gates entry on first real client
        // message (rotation/ping). Probes never get here.
        guard !Task.isCancelled, state == .starting else { return }

        do {
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "SideScreen"
            )
            try? virtualDisplayManager?.disableMirrorMode()
            settings.displayCreated = true

            // Give SCShareableContent time to register the new display.
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                tearDownStreamArtifacts()
                return
            }
            guard !Task.isCancelled, state == .starting else {
                tearDownStreamArtifacts()
                return
            }

            virtualDisplayManager?.restoreDisplayPosition()

            if let vdm = virtualDisplayManager, !vdm.verifyDisplayRegistered() {
                debugLog("WARNING: Virtual display not found in online display list — capture may fail")
            }

            guard let displayID = virtualDisplayManager?.displayID else {
                debugLog("startStream: no displayID after create")
                tearDownStreamArtifacts()
                state = .listening
                return
            }

            screenCapture = try await ScreenCapture()
            screenCapture?.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in
                    self.settings.captureMethod = method
                }
            }
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)

            guard !Task.isCancelled, state == .starting else {
                tearDownStreamArtifacts()
                return
            }

            let physWidth = screenCapture?.displayWidth ?? size.width
            let physHeight = screenCapture?.displayHeight ?? size.height
            streamingServer?.setDisplaySize(width: physWidth, height: physHeight, rotation: settings.rotation)
            streamingServer?.sendDisplaySize()

            screenCapture?.startStreaming(
                to: streamingServer,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: settings.effectiveRefreshRate
            )
            screenCapture?.requestKeyframe()

            state = .streaming
            settings.clientConnected = true
            debugLog("Stream started for client (\(physWidth)x\(physHeight))")
        } catch {
            debugLog("startStream failed: \(error.localizedDescription)")
            tearDownStreamArtifacts()
            if state == .starting {
                state = .listening
            }
        }
    }

    /// Idempotent: stops streaming, destroys virtualDisplay, clears state. Safe to
    /// call from any state (no-op if nothing to tear down).
    @MainActor
    private func tearDownStreamArtifacts() {
        if virtualDisplayManager == nil && screenCapture == nil { return }
        virtualDisplayManager?.saveDisplayPosition()
        screenCapture?.stopStreaming()
        screenCapture = nil
        virtualDisplayManager?.destroyDisplay()
        virtualDisplayManager = nil
        settings.displayCreated = false
        settings.currentFPS = 0
        settings.currentBitrate = 0
    }

    /// 响应客户端发起的旋转请求：保持 listener / streamingServer 活着，只重建虚拟
    /// 显示器与 ScreenCapture（W/H 互换）。客户端的 TCP 连接不断，重建完毕后会收到
    /// 新的 displayConfig (type=0x01)，自己 reset decoder 即可。
    @MainActor
    private func handleClientRotation(_ requestedDegrees: Int) async {
        let normalized = ((requestedDegrees % 360) + 360) % 360
        let snapped = (normalized / 90) * 90  // 0/90/180/270
        if state != .streaming {
            debugLog("ignoring client rotation \(snapped)°: state=\(state)")
            return
        }

        // 客户端发的是"我物理处于这个方向"，Mac 的 settings.rotation 是"相对 base 是否 swap"
        // 用户的 base 可能是横屏 (1920x1080) 也可能是竖屏 (1050x1680)
        // → 根据 base 方向 vs 客户端方向算出该不该 swap
        let clientWantsPortrait = (snapped == 90 || snapped == 270)
        let parts = settings.resolution.split(separator: "x")
        let baseW = Int(parts.first.map { String($0) } ?? "1920") ?? 1920
        let baseH = Int(parts.dropFirst().first.map { String($0) } ?? "1200") ?? 1200
        let baseIsPortrait = baseH > baseW
        let targetRotation = (clientWantsPortrait != baseIsPortrait) ? 90 : 0

        if targetRotation == settings.rotation {
            debugLog("client rotation \(snapped)°: already in correct orientation (rotation=\(settings.rotation))")
            return
        }
        debugLog("client physically \(snapped)° (base=\(baseW)x\(baseH)) → applying rotation \(targetRotation)°")
        settings.rotation = targetRotation

        // Mark transient .starting so concurrent client connect/disconnect handlers
        // don't race with our teardown/recreate.
        state = .starting

        // Tear down capture + virtual display via shared helper.
        tearDownStreamArtifacts()

        do {
            // 重新创建（resolutionSize getter 已根据 rotation 自动 swap W/H）
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "SideScreen"
            )
            try? virtualDisplayManager?.disableMirrorMode()
            virtualDisplayManager?.restoreDisplayPosition()

            guard let displayID = virtualDisplayManager?.displayID else {
                debugLog("rotation: no displayID after recreate")
                return
            }
            screenCapture = try await ScreenCapture()
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)

            let physW = screenCapture?.displayWidth ?? size.width
            let physH = screenCapture?.displayHeight ?? size.height
            streamingServer?.setDisplaySize(width: physW, height: physH, rotation: snapped)
            streamingServer?.sendDisplaySize()  // 推新 dims 给客户端

            screenCapture?.startStreaming(
                to: streamingServer,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: settings.effectiveRefreshRate
            )
            // 客户端 decoder 在拿到 displayConfig 后会重启,需要立刻拿到 IDR
            screenCapture?.requestKeyframe()
            settings.displayCreated = true
            state = .streaming
            debugLog("rotation: capture restarted at \(physW)x\(physH)")
        } catch {
            debugLog("rotation: rebuild failed: \(error)")
            tearDownStreamArtifacts()
            state = .listening
        }
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0
    /// Midpoint at the start of the 2-finger gesture (Down event); used to measure
    /// total midpoint travel for scroll-vs-pinch classification.
    private var twoFingerStartMidpoint: CGPoint = .zero
    /// Last seen pointer count from incoming touch packets — used to apply
    /// hysteresis when a touch screen reports a brief spurious second pointer
    /// during a one-finger move (would otherwise flip to two-finger gesture).
    private var lastPointerCount: Int = 0
    /// Time at which we first saw pointerCount transition; the new mode is only
    /// applied after the count has been stable for `pointerCountHoldNs`.
    private var pointerCountChangeTimeNs: UInt64 = 0
    /// Effective pointer count after hysteresis filtering.
    private var effectivePointerCount: Int = 0

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        // Apply pointer-count hysteresis: a touchscreen sometimes reports a brief
        // spurious second pointer during a 1-finger drag. We only commit the
        // pointerCount change after it has held steady for `pointerCountHoldNs`.
        // For Down/Up actions we trust the count immediately (those are user-driven
        // discrete events); only Move events are filtered.
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let raw = max(1, min(2, pointerCount))
        if action == 0 || action == 2 {
            // Down / Up: snap immediately.
            effectivePointerCount = raw
            lastPointerCount = raw
            pointerCountChangeTimeNs = nowNs
        } else {
            // Move: filter blips.
            if raw != lastPointerCount {
                pointerCountChangeTimeNs = nowNs
                lastPointerCount = raw
            }
            if raw != effectivePointerCount &&
               nowNs - pointerCountChangeTimeNs >= GestureThresholds.pointerCountHoldNs {
                effectivePointerCount = raw
            }
        }

        if effectivePointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            twoFingerStartMidpoint = midpoint
            touchLastPosition = midpoint

        case 1: // Move
            // Cumulative metrics from gesture start — far more stable than
            // per-frame deltas for classification. Touchscreen jitter on a single
            // axis can push per-frame deltas wildly; cumulative values average it.
            let totalDistanceChange = abs(distance - initialPinchDistance)
            let totalMidDelta = hypot(midpoint.x - twoFingerStartMidpoint.x,
                                      midpoint.y - twoFingerStartMidpoint.y)

            // Classify only once the gesture has clearly committed to one axis.
            // Both axes must clear an absolute threshold AND one must dominate
            // the other by `twoFingerAxisRatio`. While ambiguous, do nothing —
            // user just hasn't moved enough yet to know intent.
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                let activate = GestureThresholds.twoFingerActivateDistance
                let ratio = GestureThresholds.twoFingerAxisRatio
                if totalMidDelta > activate &&
                   totalMidDelta > totalDistanceChange * ratio {
                    gestureState = .twoFingerScroll
                } else if totalDistanceChange > activate &&
                          totalDistanceChange > totalMidDelta * ratio {
                    gestureState = .pinching
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                // Direction: fingers spreading (distance ↑) → zoom in;
                // fingers pinching together → zoom out. With macOS natural
                // scrolling on (default), Cmd + wheel↑ = zoom OUT, so we send
                // the negative of the raw distance delta to match user
                // expectation ("spread = bigger").
                let scaleDelta = distance - lastPinchDistance
                let zoomAmount = -Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // Synchronous teardown — applicationWillTerminate can't await.
        // App is exiting, no need for the polite shutdown notice.
        forceStopServerSync()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
