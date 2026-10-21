import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var prefs = HotKeyPreferences.shared
    @ObservedObject private var loginItem = LoginItemManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("快捷键设置")
                    .font(.headline)
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    HotKeyRow(action: action, prefs: prefs)
                }
                Divider()
                DesignatedDisplaySetting(prefs: prefs)
                MarginSetting(prefs: prefs)
                Divider()
                DockAutomationSetting(prefs: prefs)
                Divider()
                ExcludedAppsSetting(prefs: prefs)
                Divider()
                AlwaysFullscreenAppsSetting(prefs: prefs)
                Divider()
                LoginItemSetting(loginItem: loginItem)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 640)
    }
}

/// 程序坞位置和自动隐藏的设置入口，同时显示规则、实际结果和授权失败时的恢复操作。
private struct DockAutomationSetting: View {
    /// 共享持久化开关；两个策略可以独立启停，关闭后均保留当前程序坞状态。
    @ObservedObject var prefs: HotKeyPreferences
    /// 展示菜单栏后台控制器的实时结果，设置窗口本身不创建额外监听。
    @ObservedObject private var controller = DockPositionController.shared

    /// 开关即时生效；失败时才显示重试和相应的系统权限入口。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("根据笔记本开合盖自动调整程序坞", isOn: Binding(
                get: { prefs.automaticallyPositionsDock },
                set: { prefs.updateAutomaticallyPositionsDock($0) }
            ))
            Text("开盖时始终放底部；合盖并连接外接显示器时放左侧")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("根据外接显示器自动隐藏程序坞", isOn: Binding(
                get: { prefs.automaticallyControlsDockAutohide },
                set: { prefs.updateAutomaticallyControlsDockAutohide($0) }
            ))
            .padding(.top, 4)
            Text("未连接外接显示器时自动隐藏，并铺满当前 Space 中除排除名单外的可见窗口；连接任一外接显示器时始终显示")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(controller.statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if prefs.automaticallyPositionsDock || prefs.automaticallyControlsDockAutohide,
               controller.canRetry {
                HStack {
                    if controller.needsAutomationPermission {
                        Button("打开自动化设置") { controller.openAutomationSettings() }
                    }
                    if controller.needsAccessibilityPermission {
                        Button("打开辅助功能设置") { controller.openAccessibilitySettings() }
                    }
                    Button("重试") { controller.retry() }
                }
            }
        }
    }
}

private struct DesignatedDisplaySetting: View {
    @ObservedObject var prefs: HotKeyPreferences
    @State private var screenNames: [String] = ScreenDetector.connectedScreenNames()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("指定显示器")
                    .frame(width: 160, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { prefs.designatedDisplayName },
                        set: { prefs.updateDesignatedDisplayName($0) }
                    )
                ) {
                    ForEach(pickerOptions, id: \.self) { name in
                        Text(displayLabel(for: name)).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button("刷新") {
                    screenNames = ScreenDetector.connectedScreenNames()
                }
            }
            Text("在此显示器上按配置留白；其它显示器铺满可用区域")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 172)
        }
        .onAppear { screenNames = ScreenDetector.connectedScreenNames() }
    }

    /// 已连接屏 + 已保存但当前未连接的屏（避免拔线后选中项消失）。
    private var pickerOptions: [String] {
        var names = screenNames
        let saved = prefs.designatedDisplayName
        if !saved.isEmpty, !names.contains(saved) {
            names.append(saved)
        }
        return names
    }

    private func displayLabel(for name: String) -> String {
        if !screenNames.contains(name) {
            return "\(name)（未连接）"
        }
        return name
    }
}

private struct ExcludedAppsSetting: View {
    @ObservedObject var prefs: HotKeyPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("排除的应用")
                    .frame(width: 160, alignment: .leading)
                Spacer()
                Button("添加应用…") { addApp() }
            }
            Text("自动铺满会完整跳过这些应用；快捷键沿用原有排除规则")
                .font(.caption)
                .foregroundColor(.secondary)

            if prefs.excludedApps.isEmpty {
                Text("（未排除任何应用）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(prefs.excludedApps) { app in
                            ExcludedAppRow(app: app) {
                                prefs.removeExcludedApp(bundleID: app.bundleID)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func addApp() {
        for app in AppPicker.pickApplications() {
            prefs.addExcludedApp(app)
        }
    }
}

private struct AlwaysFullscreenAppsSetting: View {
    @ObservedObject var prefs: HotKeyPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("始终全屏的应用")
                    .frame(width: 160, alignment: .leading)
                Spacer()
                Button("添加应用…") { addApp() }
            }
            Text("这些应用无论在哪个显示器都铺满可用区域，不留白")
                .font(.caption)
                .foregroundColor(.secondary)

            if prefs.alwaysFullscreenApps.isEmpty {
                Text("（未指定任何应用）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(prefs.alwaysFullscreenApps) { app in
                            ExcludedAppRow(app: app) {
                                prefs.removeAlwaysFullscreenApp(bundleID: app.bundleID)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func addApp() {
        for app in AppPicker.pickApplications() {
            prefs.addAlwaysFullscreenApp(app)
        }
    }
}

private struct ExcludedAppRow: View {
    let app: ExcludedApp
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// 从「应用程序」文件夹用系统文件框选取一个或多个 .app，读出 bundleID 和显示名。
private enum AppPicker {
    static func pickApplications() -> [ExcludedApp] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return ExcludedApp(bundleID: bundleID, name: name)
        }
    }
}

/// 将留白方向和百分比放在同一设置区，方向变化时同步说明百分比对应的尺寸。
private struct MarginSetting: View {
    /// 共享配置源；所有控件通过更新方法保存并同步显示实际生效值。
    @ObservedObject var prefs: HotKeyPreferences

    /// 方向四选一，滑块和数字输入共用 0～90% 的范围及持久化逻辑。
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("留白方向")
                    .frame(width: 160, alignment: .leading)
                Picker("留白方向", selection: Binding(
                    get: { prefs.marginDirection },
                    set: { prefs.updateMarginDirection($0) }
                )) {
                    ForEach(MarginDirection.allCases, id: \.self) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            HStack(spacing: 12) {
                Text("留白比例")
                    .frame(width: 160, alignment: .leading)
                Slider(value: percentBinding, in: HotKeyPreferences.marginPercentRange)
                    .accessibilityLabel("留白比例")
                TextField("留白比例", value: percentBinding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text("%")
            }
            Text("占屏幕可用区域\(prefs.marginDirection.dimensionTitle)的 0～90%；0% 不留白")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 172)
        }
    }

    /// 共用绑定保证拖动滑块和输入数字走相同的范围校验，并实时更新另一控件。
    private var percentBinding: Binding<Double> {
        Binding(
            get: { prefs.marginPercent },
            set: { prefs.updateMarginPercent($0) }
        )
    }
}

private struct LoginItemSetting: View {
    @ObservedObject var loginItem: LoginItemManager

    var body: some View {
        Toggle(isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )) {
            Text("开机自启动")
        }
    }
}

private struct HotKeyRow: View {
    let action: HotKeyAction
    @ObservedObject var prefs: HotKeyPreferences
    @State private var isRecording = false

    var body: some View {
        let setting = prefs.setting(for: action)
        HStack(spacing: 12) {
            Text(action.title)
                .frame(width: 160, alignment: .leading)
            Text(hotKeyDisplay(setting: setting))
                .frame(minWidth: 140, alignment: .leading)
            Spacer()
            Button(isRecording ? "按下快捷键" : "录制") {
                isRecording.toggle()
            }
            Button("恢复默认") {
                prefs.update(action: action, setting: action.defaultSetting)
            }
        }
        .background(
            KeyCaptureViewRepresentable(isRecording: $isRecording) { keyCode, modifiers in
                prefs.update(action: action, setting: HotKeySetting(keyCode: keyCode, modifiers: modifiers))
                isRecording = false
            }
        )
    }
}

private struct KeyCaptureViewRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class KeyCaptureView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        let modifiers = carbonModifiers(from: event.modifierFlags)
        onCapture?(UInt32(event.keyCode), modifiers)
    }
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    return modifiers
}

private func hotKeyDisplay(setting: HotKeySetting) -> String {
    let modifiers = modifierSymbols(setting.modifiers)
    let key = keyDisplayName(for: setting.keyCode)
    return modifiers + key
}

private func modifierSymbols(_ modifiers: UInt32) -> String {
    var result = ""
    if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
    return result
}

private func keyDisplayName(for keyCode: UInt32) -> String {
    switch keyCode {
    case UInt32(kVK_LeftArrow): return "←"
    case UInt32(kVK_RightArrow): return "→"
    case UInt32(kVK_UpArrow): return "↑"
    case UInt32(kVK_DownArrow): return "↓"
    case UInt32(kVK_Return): return "↩"
    case UInt32(kVK_Escape): return "⎋"
    case UInt32(kVK_Tab): return "⇥"
    case UInt32(kVK_Space): return "␣"
    case UInt32(kVK_Delete): return "⌫"
    default:
        if let name = keyCodeToString(keyCode) {
            return name.uppercased()
        }
        return "\(keyCode)"
    }
}

private func keyCodeToString(_ keyCode: UInt32) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = unsafeBitCast(layoutData, to: CFData.self)
    let keyLayout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
    var deadKeyState: UInt32 = 0
    let maxLength = 4
    var chars = [UniChar](repeating: 0, count: maxLength)
    var actualLength = 0
    let error = UCKeyTranslate(
        keyLayout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        maxLength,
        &actualLength,
        &chars
    )
    guard error == noErr else { return nil }
    return String(utf16CodeUnits: chars, count: actualLength)
}
