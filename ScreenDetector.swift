import AppKit
import CoreGraphics
import ApplicationServices

/// 一次自动布局使用的屏幕快照；按显示器 ID 比较几何变化，避免依赖 NSScreen 实例或鼠标位置。
struct ScreenLayoutSnapshot: Equatable {
    /// Core Graphics 显示器 ID，用于窗口归属、热插拔校验和受影响屏幕筛选。
    let displayID: CGDirectDisplayID
    /// 设置中用于匹配指定显示器的本地化名称。
    let name: String
    /// Cocoa 全局坐标中的完整屏幕区域，包含菜单栏和程序坞预留。
    let frame: CGRect
    /// 已根据程序坞隐藏实值计算的布局区域，整批窗口共用该快照。
    let layoutFrame: CGRect
    /// 当前屏幕的像素缩放比例，用于窗口位置和尺寸取整。
    let scale: CGFloat

    /// 检查系统是否已在程序坞目标边缘预留空间；顶部菜单栏不参与程序坞识别。
    func reservesDockSpace(at position: String) -> Bool {
        switch position {
        case "bottom": return layoutFrame.minY - frame.minY > 0.5
        case "left": return layoutFrame.minX - frame.minX > 0.5
        case "right": return frame.maxX - layoutFrame.maxX > 0.5
        default: return false
        }
    }
}

enum ScreenDetector {
    /// macOS 27 的 Dock AXList 朝窗口一侧比可见外框多出 5 个逻辑点，本机 Retina 截图实测为 10 像素。
    /// 只补偿已测版本的视觉边界差；按逻辑点计算，不受屏幕缩放影响，也不需要后台截图或轮询。
    private static let dockVisualEdgeInset: CGFloat =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 ? 5 : 0

    /// 读取包含镜像和休眠屏幕的在线显示器 ID，供程序坞策略区分内置屏与外接屏。
    /// 查询失败、切换期间无屏幕或列表容量不足时返回 nil，不能将这些情况当作外接屏已拔除。
    static func onlineDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        // 为两次查询之间的热插拔预留空间；列表恰好填满时交给调用方稍后重新检测。
        let capacity = count + 4
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &displays, &count) == .success,
              count > 0, count < capacity else { return nil }
        return Array(displays.prefix(Int(count))).sorted()
    }

    /// 鼠标当前所在的显示器。`NSEvent.mouseLocation` 与 `NSScreen.frame`
    /// 同为 Cocoa 全局坐标（主屏左下角为原点），可直接命中。
    static func screenUnderMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        if let screen = screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return screens.first
    }

    /// 按 `localizedName` 查找显示器（用于「指定显示器」匹配）。
    static func screen(named name: String) -> NSScreen? {
        NSScreen.screens.first { $0.localizedName == name }
    }

    /// 当前所有已连接显示器的名称列表（设置页下拉用）。
    static func connectedScreenNames() -> [String] {
        NSScreen.screens.map { $0.localizedName }
    }

    /// 同步并读取系统程序坞的自动隐藏实值；缺失或读取失败时返回 nil，布局应保留系统可用区域。
    /// 只在布局或有界状态确认时调用，不建立轮询，也不修改任何程序坞偏好。
    static func dockAutohideEnabled() -> Bool? {
        let domain = "com.apple.dock" as CFString
        guard CFPreferencesAppSynchronize(domain) else { return nil }
        return (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue
    }

    /// 读取已同步的程序坞边缘，仅接受系统支持的三个值；未知时不根据窗口位置猜测边缘。
    /// 调用方先通过 dockAutohideEnabled 同步同一偏好域，确保边缘和隐藏状态来自本次检查。
    static func dockPosition() -> String? {
        guard let position = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String,
              ["bottom", "left", "right"].contains(position) else { return nil }
        return position
    }

    /// 读取 Dock 自身 AXList 的实际矩形并转换为 Cocoa 坐标，不遍历图标或读取窗口标题、内容。
    /// 仅在自动隐藏已确认为 false 的布局事件中调用；复用现有辅助功能授权，不弹窗、不建立轮询。
    /// 查询有超时上限；权限缺失、Dock 尚未就绪、类型错误或多个列表无法确定时返回 nil。
    static func visibleDockFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first(where: { !$0.isTerminated }),
              let primaryFrame = NSScreen.screens.first?.frame else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        var dockLists: [AXUIElement] = []
        for child in children {
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success else {
                return nil
            }
            if role as? String == kAXListRole { dockLists.append(child) }
        }
        guard dockLists.count == 1, let list = dockLists.first else { return nil }
        AXUIElementSetMessagingTimeout(list, 0.25)
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              [position.x, position.y, size.width, size.height, primaryFrame.maxY].allSatisfy(\.isFinite),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: position.x, y: primaryFrame.maxY - position.y - size.height,
                      width: size.width, height: size.height)
    }

    /// 所有窗口布局共用的可用区域；隐藏时回收 Dock 预留，显示时额外避开实际 Dock 边界。
    /// macOS 热插拔后可能漏报或保留旧的 visibleFrame 预留，手动快捷键和自动布局必须共用修正。
    static func windowLayoutFrame(for screen: NSScreen) -> CGRect {
        let autohide = dockAutohideEnabled()
        return windowLayoutFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                 dockAutohide: autohide,
                                 dockPosition: autohide == false ? dockPosition() : nil,
                                 dockFrame: autohide == false ? visibleDockFrame() : nil,
                                 dockVisualEdgeInset: dockVisualEdgeInset)
    }

    /// 根据完整屏幕、系统可用矩形和 Dock 实值计算布局区域，不依赖窗口状态，便于验证边缘及多屏坐标。
    /// 隐藏时保留顶部菜单栏并回收其余三侧；显示时用 Dock 可见外框替换同侧系统预留，避免重复留缝。
    /// dockVisualEdgeInset 仅用于扣除 AX 边界与可见外框的差值；其它三侧仍保留 visibleFrame 的约束。
    /// Dock 必须完整属于该屏、形状符合目标边缘且距边缘不超过自身厚度，避免采用动画中间状态或其它屏的 Dock。
    /// 无效矩形、未知状态或 AX 查询失败时保留系统区域，不根据偏好中的图标尺寸猜测 Dock 厚度。
    static func windowLayoutFrame(screenFrame: CGRect, visibleFrame: CGRect, dockAutohide: Bool?,
                                  dockPosition: String? = nil, dockFrame: CGRect? = nil,
                                  dockVisualEdgeInset: CGFloat = 0) -> CGRect {
        guard [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0,
              screenFrame.contains(visibleFrame) else { return visibleFrame }
        if dockAutohide == true {
            return CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width,
                          height: visibleFrame.maxY - screenFrame.minY)
        }
        guard dockAutohide == false, let dockFrame,
              [dockFrame.minX, dockFrame.minY, dockFrame.width, dockFrame.height].allSatisfy(\.isFinite),
              dockFrame.width > 0, dockFrame.height > 0,
              dockVisualEdgeInset.isFinite, dockVisualEdgeInset >= 0,
              dockVisualEdgeInset < min(dockFrame.width, dockFrame.height) / 2,
              screenFrame.contains(dockFrame) else { return visibleFrame }
        let outsideDock: CGRect
        switch dockPosition {
        case "bottom":
            guard dockFrame.width > dockFrame.height, dockFrame.height < screenFrame.height / 2,
                  dockFrame.minY - screenFrame.minY <= dockFrame.height else { return visibleFrame }
            let boundary = dockFrame.maxY - dockVisualEdgeInset
            outsideDock = CGRect(x: visibleFrame.minX, y: boundary, width: visibleFrame.width,
                                 height: visibleFrame.maxY - boundary)
        case "left":
            guard dockFrame.height > dockFrame.width, dockFrame.width < screenFrame.width / 2,
                  dockFrame.minX - screenFrame.minX <= dockFrame.width else { return visibleFrame }
            let boundary = dockFrame.maxX - dockVisualEdgeInset
            outsideDock = CGRect(x: boundary, y: visibleFrame.minY,
                                 width: visibleFrame.maxX - boundary, height: visibleFrame.height)
        case "right":
            guard dockFrame.height > dockFrame.width, dockFrame.width < screenFrame.width / 2,
                  screenFrame.maxX - dockFrame.maxX <= dockFrame.width else { return visibleFrame }
            let boundary = dockFrame.minX + dockVisualEdgeInset
            outsideDock = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                                 width: boundary - visibleFrame.minX, height: visibleFrame.height)
        default:
            return visibleFrame
        }
        guard outsideDock.width > 0, outsideDock.height > 0, screenFrame.contains(outsideDock) else {
            return visibleFrame
        }
        return outsideDock
    }

    /// 一次性采集所有屏幕的布局快照；同一批仅查询一次实际 Dock 矩形，再用于全部屏幕。
    /// 显示器 ID 缺失、矩形无效或切换期间没有屏幕时返回 nil，不能把异常快照用于自动移动窗口。
    static func windowLayoutSnapshots(dockAutohide: Bool) -> [ScreenLayoutSnapshot]? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let dockPosition = dockAutohide ? nil : Self.dockPosition()
        let dockFrame = dockAutohide ? nil : visibleDockFrame()
        var snapshots: [ScreenLayoutSnapshot] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let frame = screen.frame
            let layoutFrame = windowLayoutFrame(screenFrame: frame, visibleFrame: screen.visibleFrame,
                                                dockAutohide: dockAutohide,
                                                dockPosition: dockPosition, dockFrame: dockFrame,
                                                dockVisualEdgeInset: dockVisualEdgeInset)
            guard [frame.minX, frame.minY, frame.width, frame.height,
                   layoutFrame.minX, layoutFrame.minY, layoutFrame.width, layoutFrame.height,
                   screen.backingScaleFactor].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0, layoutFrame.width > 0, layoutFrame.height > 0,
                  screen.backingScaleFactor > 0, frame.contains(layoutFrame) else { return nil }
            snapshots.append(ScreenLayoutSnapshot(displayID: number.uint32Value, name: screen.localizedName,
                                                   frame: frame, layoutFrame: layoutFrame,
                                                   scale: screen.backingScaleFactor))
        }
        guard Set(snapshots.map(\.displayID)).count == snapshots.count else { return nil }
        return snapshots.sorted { $0.displayID < $1.displayID }
    }

    /// 按窗口中心优先、有效交集面积其次确定归属屏幕；完全离屏时返回 nil，避免误移动到主屏。
    /// 输入均为 Cocoa 全局坐标，使用全部屏幕判断归属后再筛选受影响显示器，防止把其它屏窗口拉过来。
    static func displayID(containing rect: CGRect, in snapshots: [ScreenLayoutSnapshot]) -> CGDirectDisplayID? {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = snapshots.first(where: { $0.frame.contains(center) }) {
            return screen.displayID
        }
        return snapshots.compactMap { snapshot -> (CGDirectDisplayID, CGFloat)? in
            let intersection = rect.intersection(snapshot.frame)
            guard !intersection.isNull else { return nil }
            let area = intersection.width * intersection.height
            return area.isFinite && area > 0 ? (snapshot.displayID, area) : nil
        }.max { $0.1 < $1.1 }?.0
    }

    /// 比较稳定快照确定需重排的屏幕；首次同步只处理实际预留 Dock 空间的屏幕。
    /// 后续同时覆盖原 Dock 屏腾出空间、新 Dock 屏占用空间及屏幕几何变化，不影响区域未变的其它屏。
    static func affectedDisplayIDs(current: [ScreenLayoutSnapshot], previous: [ScreenLayoutSnapshot]?,
                                   dockPosition: String) -> Set<CGDirectDisplayID> {
        Set(current.filter { screen in
            guard let old = previous?.first(where: { $0.displayID == screen.displayID }) else {
                return screen.reservesDockSpace(at: dockPosition)
            }
            return old != screen
        }.map(\.displayID))
    }

    /// 返回 AppKit 当前可用的内建屏幕；用于无外接屏策略在 Dock 隐藏后读取最新可用区域。
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    /// 按窗口矩形（Cocoa 全局坐标）判断它所在的显示器：中心点优先，否则取交集面积最大的屏。
    static func screen(containing rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }

        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let intersection = rect.intersection(screen.frame)
            let area = intersection.width * intersection.height
            if area.isFinite, area > 0, best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        return best?.screen ?? screens.first
    }
}
