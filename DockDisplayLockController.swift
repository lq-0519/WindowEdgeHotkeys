import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import OSLog

/// 实验性的程序坞屏幕保护：仅过滤 WindowServer 已投递给 Dock 进程的外接屏底部鼠标移动。
/// 复用 DockPositionController 的硬件通知；主线程维护生命周期和缓存，回调不查询系统、不写日志。
/// 进程级事件过滤是否早于系统的跨屏判断尚需实机验证，成功创建监听不代表程序坞已被固定。
final class DockDisplayLockController: NSObject, ObservableObject {
    /// 设置页与硬件协调器共享一个实例，避免重复建立针对 Dock 的事件过滤器。
    static let shared = DockDisplayLockController()
    /// 展示监听的实际生命周期；不将接口注册成功描述成已验证的跨屏保护效果。
    @Published private(set) var statusText = "程序坞屏幕保护已关闭"
    /// 仅由用户点击检查按钮时更新，避免每次鼠标事件都触发 SwiftUI 刷新。
    @Published private(set) var diagnosticText = ""
    /// 辅助功能权限缺失时展示已有的系统设置入口，不自动申请或重置权限。
    @Published private(set) var needsAccessibilityPermission = false
    /// 注册失败或监听被停用时允许用户手动重试，后台不建立重试轮询。
    @Published private(set) var canRetry = false
    /// Dock 启停时请求协调器通过已有单次计时器重新读取硬件状态。
    var onNeedsRefresh: (() -> Void)?

    /// 只在状态转换时记录诊断；不包含鼠标轨迹、窗口标题或应用内容。
    private let logger = Logger(subsystem: "com.local.WindowEdgeHotkeys", category: "DockDisplayLock")
    /// 当前运行期开关，与用户持久化偏好分开；退出应用时不会修改用户选择。
    private var enabled = false
    /// 只捕获针对 Dock 的鼠标移动，不注册会话级或 HID 级的全局事件过滤器。
    private var eventTap: CFMachPort?
    /// 主运行循环中的事件源；没有额外常驻线程，停止时成对移除并使端口失效。
    private var runLoopSource: CFRunLoopSource?
    /// 已绑定的 Dock PID；Dock 重启后必须重新解析 PSN，不能沿用旧的进程身份。
    private var dockProcessID: pid_t?
    /// Quartz 全局坐标中的外接屏底部区域，只在硬件状态稳定后重新计算。
    private var blockedZones: [CGRect] = []
    /// 当计时器已撤销但回调尚未拆除时让事件通过，避免使用过期屏幕缓存。
    private var filteringSuspended = true
    /// 本次注册后收到的鼠标移动计数；只在回调内加一，由用户按需读取。
    private var receivedEventCount: UInt64 = 0
    /// 本次注册后被过滤的边缘事件计数；不能据此推断程序坞的实际所属屏幕。
    private var filteredEventCount: UInt64 = 0
    /// 每次注册最多自动恢复两次超时停用，超过上限交给用户重试。
    private var timeoutRecoveryCount = 0
    /// 每次拆除监听都使旧的异步停用操作过期，防止旧回调误停新注册的 Dock 监听。
    private var eventTapGeneration: UInt64 = 0
    /// 触发带宽使用两个逻辑点；坐标来自 CGDisplayBounds，与 CGEvent.location 使用同一坐标系。
    private static let edgeDepth: CGFloat = 2

    /// 无捕获 C 回调仅恢复实例并执行缓存判断；普通鼠标事件不派发任务或发布界面状态。
    private static let eventCallback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<DockDisplayLockController>.fromOpaque(context).takeUnretainedValue()
        return controller.handleEvent(type: type, event: event)
    }

    /// 限制构造，确保事件回调上下文在应用生命周期内始终有效。
    private override init() {
        super.init()
    }

    /// 开关开启期间才观察 Dock 启停；事件过滤的建立还须等硬件协调器确认内建屏可用。
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        let center = NSWorkspace.shared.notificationCenter
        if value {
            center.addObserver(self, selector: #selector(dockProcessChanged(_:)),
                               name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            center.addObserver(self, selector: #selector(dockProcessChanged(_:)),
                               name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            setState("正在检测程序坞屏幕保护条件…")
        } else {
            center.removeObserver(self)
            removeEventTap()
            diagnosticText = ""
            setState("程序坞屏幕保护已关闭")
        }
    }

    /// 硬件开始切换、合盖或睡眠时立即拆除过滤，等待协调器重新取得稳定状态。
    func suspend(reason: String) {
        guard enabled else { return }
        removeEventTap()
        setState(reason)
    }

    /// 只在合盖、显示器、唤醒、设置或 Dock 生命周期事件后调用；不建立周期性检查。
    /// 状态未知、内建屏不可用或 Dock 不在底部时停止过滤；已有监听可直接替换屏幕缓存。
    func refresh(lidClosed: Bool?) {
        guard enabled else { return }
        guard let lidClosed else {
            suspend(reason: "无法确认开合盖状态，屏幕保护已暂停")
            canRetry = true
            return
        }
        guard !lidClosed else {
            suspend(reason: "笔记本已合盖，屏幕保护已暂停")
            return
        }

        let screens = NSScreen.screens
        var displays: [(id: CGDirectDisplayID, frame: CGRect)] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                suspend(reason: "显示器信息尚未就绪，屏幕保护已暂停")
                canRetry = true
                return
            }
            let id = number.uint32Value
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }
            let frame = CGDisplayBounds(id)
            guard frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
                suspend(reason: "显示器坐标尚未就绪，屏幕保护已暂停")
                canRetry = true
                return
            }
            displays.append((id, frame))
        }
        guard displays.contains(where: { CGDisplayIsBuiltin($0.id) != 0 }) else {
            suspend(reason: "MacBook 内建屏当前不可用，屏幕保护已暂停")
            return
        }
        guard displays.count > 1 else {
            suspend(reason: "当前仅使用内建屏，无需屏幕保护")
            return
        }
        let domain = "com.apple.dock" as CFString
        guard CFPreferencesAppSynchronize(domain),
              let position = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String else {
            suspend(reason: "无法确认程序坞位置，屏幕保护已暂停")
            canRetry = true
            return
        }
        guard position == "bottom" else {
            suspend(reason: "程序坞当前不在底部，屏幕保护已暂停")
            return
        }
        let zones = Self.externalBottomZones(displays: displays)
        guard !zones.isEmpty else {
            suspend(reason: "外接屏没有可触发程序坞的独立底边，无需过滤")
            return
        }
        guard AXIsProcessTrusted() else {
            removeEventTap()
            setState("请允许辅助功能权限后重试屏幕保护", needsPermission: true, retry: true)
            return
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            removeEventTap()
            setState("正在等待程序坞启动…", retry: true)
            return
        }
        if eventTap != nil, dockProcessID == dock.processIdentifier, !filteringSuspended {
            blockedZones = zones
            return
        }
        installEventTap(dock: dock, zones: zones)
    }

    /// 按需读取本次监听计数，并通过 Dock 的实际 AX 矩形检查当前所在屏幕。
    /// 只有点击检查按钮才进行这一次系统查询；不移动鼠标、程序坞或窗口，也不启动后台采样。
    func inspectEvents() {
        guard let eventTap, !filteringSuspended else {
            diagnosticText = "当前没有运行中的程序坞监听"
            return
        }
        guard CGEvent.tapIsEnabled(tap: eventTap) else {
            suspend(reason: "程序坞监听已被系统停用，请重试")
            canRetry = true
            return
        }
        diagnosticText = "监听正常：收到投递给程序坞的鼠标移动 \(receivedEventCount) 次，过滤外接屏底边 \(filteredEventCount) 次。"
            + "\n" + inspectDockLocation()
    }

    /// 根据实际 Dock 矩形的完整屏幕归属返回检查结果，不用过滤计数推断屏幕锁定效果。
    /// AX 查询失败、跨屏动画中或显示器信息缺失时明确返回未知，不能猜成主屏或内建屏。
    /// 仅供用户按需诊断；屏幕保护自身仍使用缓存矩形，不在鼠标回调中调用本方法。
    private func inspectDockLocation() -> String {
        guard let frame = ScreenDetector.visibleDockFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "暂时无法确认程序坞所在屏幕；事件计数不能代替屏幕检查。"
        }
        if CGDisplayIsBuiltin(number.uint32Value) != 0 {
            return "当前程序坞位于 MacBook 内建屏。"
        }
        return "当前程序坞位于外接屏。请先移回 MacBook 内建屏；若仍会移屏，进程级过滤可能无法阻止系统的跨屏判断。"
    }

    /// 通过公开的进程级 PSN 接口注册，仅捕获 Dock 的 mouseMoved；失败时不扩大为全局过滤。
    private func installEventTap(dock: NSRunningApplication, zones: [CGRect]) {
        removeEventTap()
        var serialNumber = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        let error = WindowEdgeGetProcessForPID(dock.processIdentifier, &serialNumber)
        guard error == noErr else {
            setState("无法获取程序坞进程身份，请重试", retry: true)
            logger.error("dock_psn_query_failed pid=\(dock.processIdentifier) error=\(error)")
            return
        }
        let tap = withUnsafeMutablePointer(to: &serialNumber) { pointer in
            CGEvent.tapCreateForPSN(
                processSerialNumber: UnsafeMutableRawPointer(pointer),
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
                callback: Self.eventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard let tap else {
            setState("系统未能创建程序坞专用监听，请检查辅助功能权限后重试", retry: true)
            return
        }
        guard !dock.isTerminated,
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            setState("程序坞进程正在切换，请重试", retry: true)
            return
        }
        eventTap = tap
        runLoopSource = source
        dockProcessID = dock.processIdentifier
        blockedZones = zones
        receivedEventCount = 0
        filteredEventCount = 0
        timeoutRecoveryCount = 0
        diagnosticText = ""
        filteringSuspended = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            removeEventTap()
            setState("程序坞专用监听未能启用，请重试", retry: true)
            return
        }
        setState("程序坞专用监听已启用")
    }

    /// 普通回调只累计计数并比较缓存矩形；不读屏幕、偏好、AX，不记录每次鼠标事件。
    /// 停用通知仅做有界恢复；用户主动停用或重复超时时先放行，再异步清理端口。
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard !filteringSuspended, let eventTap else { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout, timeoutRecoveryCount < 2 {
                timeoutRecoveryCount += 1
                CGEvent.tapEnable(tap: eventTap, enable: true)
                if CGEvent.tapIsEnabled(tap: eventTap) { return Unmanaged.passUnretained(event) }
            }
            filteringSuspended = true
            let requestedGeneration = eventTapGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.eventTapGeneration == requestedGeneration else { return }
                self.suspend(reason: "程序坞监听已被系统停用，请重试")
                self.canRetry = true
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved, !filteringSuspended else { return Unmanaged.passUnretained(event) }
        receivedEventCount &+= 1
        let point = event.location
        for zone in blockedZones where zone.contains(point) {
            filteredEventCount &+= 1
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// 移除事件源并使端口失效；先放行并清空缓存，保证关闭或硬件切换后不会继续过滤。
    private func removeEventTap() {
        eventTapGeneration &+= 1
        filteringSuspended = true
        blockedZones = []
        if !diagnosticText.isEmpty { diagnosticText = "" }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
        eventTap = nil
        dockProcessID = nil
    }

    /// 只响应 Dock 的启停；其他应用的通知立即返回，Dock 退出时立即释放旧 PSN 监听。
    @objc private func dockProcessChanged(_ notification: Notification) {
        guard enabled,
              let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier == "com.apple.dock" else { return }
        if notification.name == NSWorkspace.didTerminateApplicationNotification {
            guard dockProcessID == application.processIdentifier else { return }
            suspend(reason: "程序坞已退出，正在等待重新启动…")
        }
        onNeedsRefresh?()
    }

    /// 发布变化后的状态并记录一次元数据；相同状态重复出现时不唤醒设置视图或写重复日志。
    private func setState(_ text: String, needsPermission: Bool = false, retry: Bool = false) {
        if needsAccessibilityPermission != needsPermission { needsAccessibilityPermission = needsPermission }
        if canRetry != retry { canRetry = retry }
        guard statusText != text else { return }
        statusText = text
        logger.notice("dock_display_lock_state state=\(text, privacy: .public) pid=\(self.dockProcessID ?? 0)")
    }

    /// 计算外接屏独立底边，剔除与其他屏相接的区段；内建屏即使不是主屏也始终不被过滤。
    /// 区段裁剪只在配置事件后执行，鼠标回调直接使用结果数组。
    private static func externalBottomZones(
        displays: [(id: CGDirectDisplayID, frame: CGRect)]
    ) -> [CGRect] {
        var zones: [CGRect] = []
        for display in displays where CGDisplayIsBuiltin(display.id) == 0 {
            var segments = [(display.frame.minX, display.frame.maxX)]
            for neighbor in displays where neighbor.id != display.id
                && abs(neighbor.frame.minY - display.frame.maxY) <= 0.5 {
                segments = segments.flatMap { start, end -> [(CGFloat, CGFloat)] in
                    let overlapStart = max(start, neighbor.frame.minX)
                    let overlapEnd = min(end, neighbor.frame.maxX)
                    guard overlapEnd > overlapStart else { return [(start, end)] }
                    var remainder: [(CGFloat, CGFloat)] = []
                    if overlapStart > start { remainder.append((start, overlapStart)) }
                    if overlapEnd < end { remainder.append((overlapEnd, end)) }
                    return remainder
                }
            }
            zones += segments.map { start, end in
                CGRect(x: start, y: display.frame.maxY - edgeDepth, width: end - start, height: edgeDepth)
            }
        }
        return zones
    }
}
