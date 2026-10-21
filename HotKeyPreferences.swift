import Foundation
import Carbon

struct HotKeySetting: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// 一个 App 的引用（用于「排除」和「始终全屏」两类名单）。
/// 用 bundleID 作唯一键（稳定、不受语言/改名影响），name 仅用于展示。
struct ExcludedApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}

/// 指定显示器上需要留白的一侧；原始值用于持久化，显示名称变化不会影响已保存的方向。
enum MarginDirection: String, CaseIterable {
    /// 左侧留白，窗口右边缘贴住可用区域右侧。
    case left
    /// 上方留白，窗口下边缘贴住可用区域底部。
    case top
    /// 右侧留白，窗口左边缘贴住可用区域左侧。
    case right
    /// 下方留白，窗口上边缘贴住可用区域顶部。
    case bottom

    /// 设置页展示的方向名称，表示空白所在的一侧。
    var title: String {
        switch self {
        case .left: return "左边距"
        case .top: return "上边距"
        case .right: return "右边距"
        case .bottom: return "下边距"
        }
    }

    /// 百分比对应的可用区域尺寸：左右按宽度，上下按高度。
    var dimensionTitle: String {
        switch self {
        case .left, .right: return "宽度"
        case .top, .bottom: return "高度"
        }
    }
}

extension HotKeyAction {
    static var allCases: [HotKeyAction] {
        [.smartLayout]
    }

    var title: String {
        switch self {
        case .smartLayout:
            return "智能布局（按鼠标所在屏）"
        }
    }

    var defaultSetting: HotKeySetting {
        switch self {
        case .smartLayout:
            return HotKeySetting(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | optionKey | controlKey))
        }
    }

    var keyCodeKey: String {
        "hotkey.\(storageKey).keyCode"
    }

    var modifiersKey: String {
        "hotkey.\(storageKey).modifiers"
    }

    private var storageKey: String {
        switch self {
        case .smartLayout:
            return "smartLayout"
        }
    }
}

extension Notification.Name {
    static let hotKeyPreferencesDidChange = Notification.Name("hotKeyPreferencesDidChange")
    /// 任一程序坞自动调整开关已保存；独立通知避免重新注册窗口快捷键。
    static let dockAutomationPreferenceDidChange = Notification.Name("dockAutomationPreferenceDidChange")
}

final class HotKeyPreferences: ObservableObject {
    static let shared = HotKeyPreferences()

    /// 滑块、数字输入、配置读取和窗口布局共用的百分比范围，至少保留 10% 的可用尺寸。
    static let marginPercentRange: ClosedRange<Double> = 0...90
    /// 新安装或配置数值无效时采用的留白百分比；旧版有效配置优先保留。
    static let defaultMarginPercent: Double = 10

    @Published private(set) var settings: [HotKeyAction: HotKeySetting] = [:]
    /// 留白方向；旧版没有此配置时默认为左侧，以保持升级前的布局。
    @Published private(set) var marginDirection: MarginDirection = .left
    /// 沿所选方向留出的百分比；左右以可用宽度为基准，上下以可用高度为基准。
    @Published private(set) var marginPercent: Double = HotKeyPreferences.defaultMarginPercent
    /// 「指定显示器」的名称（NSScreen.localizedName）。在它上面按配置留白，其它屏铺满可用区域。
    @Published private(set) var designatedDisplayName: String = ""
    /// 被排除的 App 列表；命中的前台 App 按快捷键时不生效。
    @Published private(set) var excludedApps: [ExcludedApp] = []
    /// 始终全屏的 App 列表；命中时无视所在显示器，一律铺满全屏（不留白）。
    @Published private(set) var alwaysFullscreenApps: [ExcludedApp] = []
    /// 是否根据笔记本开合盖和外接屏幕自动调整程序坞；沿用原配置键，保留已有开关选择。
    @Published private(set) var automaticallyPositionsDock: Bool = true
    /// 是否根据在线外接显示器自动控制程序坞隐藏；新功能默认关闭，避免升级后改变用户原有设置。
    @Published private(set) var automaticallyControlsDockAutohide: Bool = false

    private init() {
        loadAll()
    }

    func setting(for action: HotKeyAction) -> HotKeySetting {
        settings[action] ?? action.defaultSetting
    }

    func update(action: HotKeyAction, setting: HotKeySetting) {
        settings[action] = setting
        save(action: action, setting: setting)
        NotificationCenter.default.post(name: .hotKeyPreferencesDidChange, object: nil)
    }

    private func loadAll() {
        var result: [HotKeyAction: HotKeySetting] = [:]
        for action in HotKeyAction.allCases {
            result[action] = loadSetting(for: action)
        }
        settings = result
        marginDirection = MarginDirection(rawValue: UserDefaults.standard.string(forKey: "marginDirection") ?? "") ?? .left
        marginPercent = loadMarginPercent()
        designatedDisplayName = UserDefaults.standard.string(forKey: "designatedDisplayName") ?? ""
        excludedApps = loadExcludedApps()
        alwaysFullscreenApps = loadAppList(forKey: "alwaysFullscreenApps")
        automaticallyPositionsDock = UserDefaults.standard.object(forKey: "automaticallyPositionsDock") as? Bool ?? true
        automaticallyControlsDockAutohide =
            UserDefaults.standard.object(forKey: "automaticallyControlsDockAutohide") as? Bool ?? false
    }

    /// 保存程序坞开关并立即通知控制器；明确保存 false，确保重启后不会重新开启。
    func updateAutomaticallyPositionsDock(_ enabled: Bool) {
        guard automaticallyPositionsDock != enabled else { return }
        automaticallyPositionsDock = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticallyPositionsDock")
        NotificationCenter.default.post(name: .dockAutomationPreferenceDidChange, object: nil)
    }

    /// 保存外接显示器自动隐藏策略并立即通知控制器；关闭时保留程序坞当前的自动隐藏状态。
    func updateAutomaticallyControlsDockAutohide(_ enabled: Bool) {
        guard automaticallyControlsDockAutohide != enabled else { return }
        automaticallyControlsDockAutohide = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticallyControlsDockAutohide")
        NotificationCenter.default.post(name: .dockAutomationPreferenceDidChange, object: nil)
    }

    private func loadSetting(for action: HotKeyAction) -> HotKeySetting {
        let defaults = UserDefaults.standard
        let keyCodeObj = defaults.object(forKey: action.keyCodeKey) as? NSNumber
        let modifiersObj = defaults.object(forKey: action.modifiersKey) as? NSNumber
        if let keyCodeObj, let modifiersObj {
            return HotKeySetting(keyCode: keyCodeObj.uint32Value, modifiers: modifiersObj.uint32Value)
        }
        return action.defaultSetting
    }

    private func save(action: HotKeyAction, setting: HotKeySetting) {
        let defaults = UserDefaults.standard
        defaults.set(setting.keyCode, forKey: action.keyCodeKey)
        defaults.set(setting.modifiers, forKey: action.modifiersKey)
    }

    /// 保存留白方向；下一次触发智能布局时读取，无需重新注册快捷键或重启应用。
    func updateMarginDirection(_ direction: MarginDirection) {
        marginDirection = direction
        UserDefaults.standard.set(direction.rawValue, forKey: "marginDirection")
    }

    /// 将输入约束到统一范围并保存，滑块和数字输入始终共享同一个实际生效值。
    func updateMarginPercent(_ value: Double) {
        let clamped = Self.clampedMarginPercent(value)
        marginPercent = clamped
        UserDefaults.standard.set(clamped, forKey: "marginPercent")
    }

    /// 为设置和布局提供相同的数值保护，避免非有限值进入窗口坐标计算。
    static func clampedMarginPercent(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMarginPercent }
        return min(max(value, marginPercentRange.lowerBound), marginPercentRange.upperBound)
    }

    func updateDesignatedDisplayName(_ name: String) {
        designatedDisplayName = name
        UserDefaults.standard.set(name, forKey: "designatedDisplayName")
    }

    // MARK: - Excluded apps

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return excludedApps.contains { $0.bundleID == bundleID }
    }

    func addExcludedApp(_ app: ExcludedApp) {
        guard !excludedApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        excludedApps.append(app)
        saveAppList(excludedApps, forKey: "excludedApps")
    }

    func removeExcludedApp(bundleID: String) {
        excludedApps.removeAll { $0.bundleID == bundleID }
        saveAppList(excludedApps, forKey: "excludedApps")
    }

    // MARK: - Always-fullscreen apps

    func isAlwaysFullscreen(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return alwaysFullscreenApps.contains { $0.bundleID == bundleID }
    }

    func addAlwaysFullscreenApp(_ app: ExcludedApp) {
        guard !alwaysFullscreenApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        alwaysFullscreenApps.append(app)
        saveAppList(alwaysFullscreenApps, forKey: "alwaysFullscreenApps")
    }

    func removeAlwaysFullscreenApp(bundleID: String) {
        alwaysFullscreenApps.removeAll { $0.bundleID == bundleID }
        saveAppList(alwaysFullscreenApps, forKey: "alwaysFullscreenApps")
    }

    // MARK: - App list persistence

    private func loadExcludedApps() -> [ExcludedApp] {
        loadAppList(forKey: "excludedApps")
    }

    private func loadAppList(forKey key: String) -> [ExcludedApp] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ExcludedApp].self, from: data)) ?? []
    }

    private func saveAppList(_ list: [ExcludedApp], forKey key: String) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 优先读取通用百分比；首次升级回退到旧版左边距并写入新键，保留已有精度和有效的 0%。
    private func loadMarginPercent() -> Double {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "marginPercent") as? NSNumber
            ?? defaults.object(forKey: "leftMarginPercent") as? NSNumber
        let percent = Self.clampedMarginPercent(saved?.doubleValue ?? Self.defaultMarginPercent)
        defaults.set(percent, forKey: "marginPercent")
        return percent
    }
}
