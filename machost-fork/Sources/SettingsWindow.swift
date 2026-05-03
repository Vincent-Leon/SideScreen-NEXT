import Cocoa
import SwiftUI

// MARK: - Frosted GroupBox Component

@available(macOS 14.0, *)
struct FrostedGroupBox<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - Visual Effect Blur

@available(macOS 14.0, *)
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Settings View

@available(macOS 14.0, *)
struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false
    @State private var headerHovered = false

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with frosted glass
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)

                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .scaleEffect(headerHovered ? 1.05 : 1)
                    .animation(.spring(response: 0.3), value: headerHovered)
                    .onHover { headerHovered = $0 }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Side Screen")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(L("Turn your tablet into a second display", "把平板变成 Mac 的副屏"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: { showResetConfirmation = true }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background {
                                Circle().fill(.ultraThinMaterial)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(L("Reset settings", "重置设置"))
                    .alert(L("Reset Settings", "重置设置"), isPresented: $showResetConfirmation) {
                        Button(L("Cancel", "取消"), role: .cancel) { }
                        Button(L("Reset", "重置"), role: .destructive) {
                            settings.resetToDefaults()
                            if let window = NSApp.windows.first(where: { $0.title == "Side Screen" }) {
                                window.center()
                            }
                        }
                    } message: {
                        Text(L("This will reset all settings to default values.", "将把所有设置恢复到默认值。"))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Display Configuration
                        FrostedGroupBox(title: L("Display Configuration", "显示器配置"), icon: "display") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Resolution
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(L("Resolution", "分辨率"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Toggle(L("Show all", "全部"), isOn: $settings.showAllResolutions)
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                    }

                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 0) {
                                            if settings.showAllResolutions {
                                                ForEach(DisplaySettings.resolutionGroups) { group in
                                                    HStack(spacing: 6) {
                                                        Text(group.name)
                                                            .font(.system(size: 11, weight: .semibold))
                                                        Text(group.ratio)
                                                            .font(.system(size: 10))
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 6)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color.primary.opacity(0.03))

                                                    ForEach(group.resolutions, id: \.self) { res in
                                                        ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                                            settings.resolution = res
                                                        }
                                                    }
                                                }
                                            } else {
                                                ForEach(DisplaySettings.commonResolutions, id: \.self) { res in
                                                    ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                                        settings.resolution = res
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: 180)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )

                                    if settings.showAllResolutions {
                                        HStack(spacing: 8) {
                                            TextField(L("W", "宽"), value: $settings.customWidth, format: .number)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(width: 70)
                                            Text("×")
                                                .foregroundColor(.secondary)
                                            TextField(L("H", "高"), value: $settings.customHeight, format: .number)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(width: 70)
                                            Button(L("Apply", "应用")) {
                                                settings.applyCustomResolution()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }

                                // HiDPI (Retina)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("HiDPI (Retina)", "HiDPI（Retina）"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text(L("Renders at 2× resolution for sharper text. Increases bandwidth.",
                                               "以 2× 像素渲染，文字更清晰，带宽消耗更高。"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.hiDPI)
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .disabled(settings.isRunning)
                                }

                                // Rotation
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L("Rotation", "方向"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                                                .frame(width: 80, height: 50)
                                                .rotationEffect(.degrees(Double(settings.rotation)))

                                            Text(settings.rotation == 90 || settings.rotation == 270
                                                ? L("Portrait", "竖屏")
                                                : L("Landscape", "横屏"))
                                                .font(.system(size: 8))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 100, height: 80)

                                        VStack(spacing: 6) {
                                            HStack(spacing: 6) {
                                                RotationButton(degrees: 270, label: "270", isSelected: settings.rotation == 270) {
                                                    settings.rotation = 270
                                                }
                                                RotationButton(degrees: 0, label: "0", isSelected: settings.rotation == 0) {
                                                    settings.rotation = 0
                                                }
                                                RotationButton(degrees: 90, label: "90", isSelected: settings.rotation == 90) {
                                                    settings.rotation = 90
                                                }
                                            }
                                            HStack(spacing: 6) {
                                                Spacer()
                                                RotationButton(degrees: 180, label: "180", isSelected: settings.rotation == 180) {
                                                    settings.rotation = 180
                                                }
                                                Spacer()
                                            }
                                        }
                                    }

                                    if settings.rotation == 90 || settings.rotation == 270 {
                                        Text(L("Display will be in portrait mode", "副屏将以竖屏方向显示"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.accentColor)
                                    }
                                }

                                // Refresh Rate
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(L("Refresh Rate", "刷新率"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(settings.refreshRate) Hz")
                                            .font(.system(size: 11, weight: .medium))
                                    }

                                    Picker("", selection: $settings.refreshRate) {
                                        Text("30").tag(30)
                                        Text("60").tag(60)
                                        Text("90").tag(90)
                                        Text("120").tag(120)
                                    }
                                    .pickerStyle(.segmented)

                                    if settings.refreshRate >= 90 {
                                        Text(L("High refresh rate for smooth experience", "高刷新率，画面更流畅"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }

                        // Touch Control
                        FrostedGroupBox(title: L("Touch Control", "触控"), icon: "hand.tap") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Enable Touch Input", "启用触控输入"))
                                            .font(.system(size: 12, weight: .medium))
                                        Text(L("Control Mac from tablet touch", "用平板触控操作 Mac"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.touchEnabled)
                                        .labelsHidden()
                                }

                                if !settings.touchEnabled {
                                    Text(L("Touch input is disabled — tablet is display-only", "触控已关闭——平板仅作显示"))
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                        }

                        // Network Settings
                        FrostedGroupBox(title: L("Network Settings", "网络设置"), icon: "network") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L("Server Port", "服务端口"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField(L("Port", "端口"), value: $settings.port, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .disabled(settings.isRunning)
                                }

                                if settings.isRunning {
                                    Text(L("Stop server to change port", "停止服务后才能修改端口"))
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                } else if settings.port != 8888 {
                                    Text(L("Enter this port in the client app", "在客户端 App 里使用此端口"))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }

                                Divider().padding(.vertical, 4)

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Eager Virtual Display", "立即创建副屏"))
                                            .font(.system(size: 12, weight: .medium))
                                        Text(L("Create the virtual display on Start instead of waiting for a client. Recommended for headless Macs (MacMini etc.).",
                                               "点 Start 立刻建副屏，无需等客户端连接。适合无显示器的 Mac（如 MacMini）。"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.eagerVirtualDisplay)
                                        .labelsHidden()
                                        .disabled(settings.isRunning)
                                }
                            }
                        }

                        // Gaming Boost
                        FrostedGroupBox(title: L("Gaming Boost", "游戏增强"), icon: settings.gamingBoost ? "bolt.fill" : "bolt") {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Enable Gaming Mode", "启用游戏模式"))
                                            .font(.system(size: 12, weight: .medium))
                                        Text(L("Optimized for competitive gaming", "针对竞技游戏优化"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.gamingBoost)
                                        .labelsHidden()
                                }

                                if settings.gamingBoost {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text(L("High bitrate (1000 Mbps)", "高码率（1000 Mbps）"))
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text(L("120 Hz refresh rate", "120 Hz 刷新率"))
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text(L("Ultra-low latency encoding", "超低延迟编码"))
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .padding(.leading, 4)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Streaming Settings
                        FrostedGroupBox(title: L("Streaming Settings", "推流设置"), icon: "antenna.radiowaves.left.and.right") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Bitrate
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(L("Bitrate", "码率"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(settings.effectiveBitrate) Mbps")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.accentColor)
                                    }

                                    HStack(spacing: 6) {
                                        BitrateButton(label: "100", value: 100, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 100
                                        }
                                        BitrateButton(label: "300", value: 300, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 300
                                        }
                                        BitrateButton(label: "500", value: 500, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 500
                                        }
                                        BitrateButton(label: "1000", value: 1000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 1000
                                        }
                                        BitrateButton(label: "2000", value: 2000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 2000
                                        }
                                    }

                                    HStack(spacing: 8) {
                                        Text("20")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        Slider(value: Binding(
                                            get: { Double(settings.bitrate) },
                                            set: { settings.bitrate = Int($0) }
                                        ), in: 20...5000, step: 10)
                                        .disabled(settings.gamingBoost)
                                        Text("5000")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }

                                    if settings.gamingBoost {
                                        HStack(spacing: 4) {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 10))
                                            Text(L("Locked at 1000 Mbps in Gaming Boost", "游戏增强模式下锁定为 1000 Mbps"))
                                                .font(.system(size: 10))
                                        }
                                        .foregroundColor(.orange)
                                    }
                                }

                                // Quality
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L("Quality Preset", "质量预设"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    Picker("", selection: $settings.quality) {
                                        Text(L("Ultra Low", "极低")).tag("ultralow")
                                        Text(L("Low", "低")).tag("low")
                                        Text(L("Medium", "中")).tag("medium")
                                        Text(L("High", "高")).tag("high")
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(settings.gamingBoost)

                                    if settings.gamingBoost {
                                        Text(L("Quality locked to Ultra Low in Gaming Boost mode", "游戏增强模式下锁定为「极低」"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    } else if settings.quality == "ultralow" {
                                        Text(L("Fastest encoding, lowest latency", "最快编码，最低延迟"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }

                        // Status
                        FrostedGroupBox(title: L("Status", "状态"), icon: "checkmark.circle") {
                            VStack(alignment: .leading, spacing: 12) {
                                StatusRow(title: L("Virtual Display", "虚拟屏幕"),
                                          status: settings.displayCreated ? L("Active", "已激活") : L("Inactive", "未激活"),
                                          color: settings.displayCreated ? .green : .secondary)
                                StatusRow(title: L("Client Connected", "客户端连接"),
                                          status: settings.clientConnected ? L("Yes", "是") : L("No", "否"),
                                          color: settings.clientConnected ? .green : .secondary)
                                StatusRow(
                                    title: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                        ? L("Screen & System Audio", "屏幕和系统音频")
                                        : L("Screen Recording", "屏幕录制"),
                                    status: settings.hasScreenRecordingPermission ? L("Granted", "已授权") : L("Required", "需授权"),
                                    color: settings.hasScreenRecordingPermission ? .green : .red
                                )
                                StatusRow(title: L("Accessibility", "辅助功能"),
                                          status: settings.hasAccessibilityPermission ? L("Granted", "已授权") : L("Optional", "可选"),
                                          color: settings.hasAccessibilityPermission ? .green : .orange)
                                if settings.isRunning {
                                    StatusRow(title: L("Capture Method", "采集方式"),
                                              status: settings.captureMethod,
                                              color: settings.captureMethod.contains("fallback") ? .orange : .green)
                                }

                                if !settings.hasScreenRecordingPermission {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.orange)
                                            Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                                ? L("Screen & System Audio Recording Required", "需要屏幕和系统音频录制权限")
                                                : L("Screen Recording Required", "需要屏幕录制权限"))
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                            ? L("Required to capture the virtual display. Go to System Settings > Privacy & Security > Screen & System Audio Recording.",
                                                "用于采集虚拟屏幕。请打开 系统设置 > 隐私与安全 > 屏幕和系统音频录制。")
                                            : L("Required to capture the virtual display.", "用于采集虚拟屏幕。"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Button(action: {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                        }) {
                                            HStack {
                                                Image(systemName: "gear")
                                                Text(L("Open System Settings", "打开系统设置"))
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                }

                                if !settings.hasAccessibilityPermission {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "hand.tap.fill")
                                                .foregroundColor(.blue)
                                            Text(L("Enable Touch Control", "启用触控"))
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text(L("Control your Mac from your tablet.", "通过平板控制 Mac。"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Button(action: {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                        }) {
                                            HStack {
                                                Image(systemName: "gear")
                                                Text(L("Open Settings", "打开设置"))
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(8)
                                }
                            }
                        }

                        // Performance (when connected)
                        if settings.clientConnected {
                            FrostedGroupBox(title: L("Performance", "实时性能"), icon: "speedometer") {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("FPS")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f", settings.currentFPS))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.green)
                                    }
                                    Spacer()
                                    VStack(alignment: .leading) {
                                        Text(L("Bitrate", "码率"))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f Mbps", settings.currentBitrate))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                // Footer
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)

                    HStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                settings.toggleServer()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: settings.isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 12))
                                Text(settings.isRunning ? L("Stop", "停止") : L("Start", "启动"))
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .frame(width: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.isRunning ? .red : .accentColor)
                        .controlSize(.large)
                        .disabled(!settings.hasScreenRecordingPermission)

                        if settings.isRunning {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.green.opacity(0.3), lineWidth: 2)
                                            .scaleEffect(1.5)
                                    }
                                Text(L("Running on port \(settings.port)", "运行在端口 \(settings.port)"))
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                    .overlay {
                                        Capsule().strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
                                    }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }

                        Spacer()

                        // Restart button
                        Button(action: {
                            restartApp()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background {
                                    Circle().fill(.ultraThinMaterial)
                                        .overlay {
                                            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(L("Restart App", "重启应用"))

                        // Quit button
                        Button(action: {
                            NSApp.terminate(nil)
                        }) {
                            Image(systemName: "power")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background {
                                    Circle().fill(.ultraThinMaterial)
                                        .overlay {
                                            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Quit Side Screen (⌘Q)")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .frame(width: 480, height: 780)
    }

    /// Restart the app by launching a new instance and terminating current one
    private func restartApp() {
        // Get the app bundle path
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("❌ Could not get app path")
            return
        }

        // Use Process to launch a new instance after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current app
            NSApp.terminate(nil)
        } catch {
            print("❌ Failed to restart: \(error)")
        }
    }
}

// MARK: - Supporting Views

@available(macOS 14.0, *)
struct StatusRow: View {
    let title: String
    let status: String
    let color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(color)
            }
        }
    }
}

@available(macOS 14.0, *)
struct ResolutionRow: View {
    let resolution: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(resolution.replacingOccurrences(of: "x", with: " x "))
                    .font(.system(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

@available(macOS 14.0, *)
struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                    }
                }
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }
}

@available(macOS 14.0, *)
struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: degrees == 90 || degrees == 270 ? 16 : 24, height: degrees == 90 || degrees == 270 ? 24 : 16)

                Text("\(label)")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 50, height: 40)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Settings

@available(macOS 14.0, *)
class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "SideScreen_"

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet { save("refreshRate", refreshRate) }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet { save("bitrate", bitrate) }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet { save("port", Int(port)) }
    }
    @Published var rotation: Int {
        didSet { save("rotation", rotation) }
    }
    @Published var showAllResolutions: Bool {
        didSet { save("showAllResolutions", showAllResolutions) }
    }
    @Published var customWidth: Int {
        didSet { save("customWidth", customWidth) }
    }
    @Published var customHeight: Int {
        didSet { save("customHeight", customHeight) }
    }
    @Published var touchEnabled: Bool {
        didSet { save("touchEnabled", touchEnabled) }
    }
    /// Eager mode: 点 Start 立刻建虚拟显示器（不等 client 连上）。MacMini 等无显示器主机
    /// 用户场景——副屏要立即可用 + 远程登录能直接看到副屏。默认 false（lazy）。
    @Published var eagerVirtualDisplay: Bool {
        didSet { save("eagerVirtualDisplay", eagerVirtualDisplay) }
    }
    // Runtime state (not persisted)
    @Published var displayCreated = false
    @Published var clientConnected = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
    @Published var captureMethod: String = "Initializing..."

    var onToggleServer: (() -> Void)?

    init() {
        self.resolution = defaults.string(forKey: keyPrefix + "resolution") ?? "1920x1200"
        self.refreshRate = defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? 120  // Default: highest FPS
        self.hiDPI = defaults.bool(forKey: keyPrefix + "hiDPI")
        self.bitrate = defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? 1000  // Default: 1000 Mbps
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? "ultralow"  // Default: fastest encoding
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        self.port = UInt16(defaults.object(forKey: keyPrefix + "port") as? Int ?? 8888)
        self.rotation = defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0
        self.showAllResolutions = defaults.bool(forKey: keyPrefix + "showAllResolutions")
        self.customWidth = defaults.object(forKey: keyPrefix + "customWidth") as? Int ?? 1920
        self.customHeight = defaults.object(forKey: keyPrefix + "customHeight") as? Int ?? 1200
        self.touchEnabled = defaults.object(forKey: keyPrefix + "touchEnabled") as? Bool ?? true
        self.eagerVirtualDisplay = defaults.bool(forKey: keyPrefix + "eagerVirtualDisplay")

        print("Loaded settings: \(resolution) @ \(refreshRate)Hz, bitrate=\(bitrate), quality=\(quality)")
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    struct ResolutionGroup: Identifiable {
        let id = UUID()
        let name: String
        let ratio: String
        let resolutions: [String]
    }

    static let resolutionGroups: [ResolutionGroup] = [
        ResolutionGroup(name: "16:10", ratio: L("Widescreen", "宽屏"), resolutions: [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600"
        ]),
        ResolutionGroup(name: "16:9", ratio: L("HD/4K", "高清/4K"), resolutions: [
            "1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"
        ]),
        ResolutionGroup(name: "4:3", ratio: L("Classic", "经典"), resolutions: [
            "1024x768", "1280x960", "1600x1200"
        ]),
        ResolutionGroup(name: "3:2", ratio: L("Surface/Pixel", "Surface/Pixel"), resolutions: [
            "1920x1280", "2160x1440", "2736x1824"
        ]),
        ResolutionGroup(name: "5:3", ratio: L("Tablet Wide", "宽屏平板"), resolutions: [
            "2000x1200", "2560x1536", "2800x1680"
        ]),
        ResolutionGroup(name: "4:3", ratio: L("iPad", "iPad"), resolutions: [
            "2048x1536", "2224x1668", "2388x1668", "2732x2048"
        ])
    ]

    static let commonResolutions = [
        "1920x1080", "1920x1200", "2560x1440", "2560x1600"
    ]

    static var allResolutions: [String] {
        resolutionGroups.flatMap { $0.resolutions }
    }

    var effectiveBitrate: Int {
        return gamingBoost ? 1000 : bitrate
    }

    var effectiveQuality: String {
        return gamingBoost ? "ultralow" : quality
    }

    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    func toggleServer() {
        onToggleServer?()
    }

    func resetToDefaults() {
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "showAllResolutions",
                    "customWidth", "customHeight", "touchEnabled"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        resolution = "1920x1200"
        refreshRate = 120  // Default: highest FPS
        hiDPI = false
        bitrate = 1000  // Default: 1000 Mbps
        quality = "ultralow"  // Default: fastest encoding
        gamingBoost = false
        port = 8888
        rotation = 0
        showAllResolutions = false
        customWidth = 1920
        customHeight = 1200
        touchEnabled = true

        print("Settings reset to defaults")
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

    func applyCustomResolution() {
        if customWidth >= 640 && customWidth <= 7680 && customHeight >= 480 && customHeight <= 4320 {
            resolution = "\(customWidth)x\(customHeight)"
        }
    }
}

// MARK: - Window Controller

@available(macOS 14.0, *)
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Side Screen"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

@available(macOS 14.0, *)
class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}
