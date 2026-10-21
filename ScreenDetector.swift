import AppKit
import CoreGraphics

enum ScreenDetector {
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
