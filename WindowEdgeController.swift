import AppKit
import ApplicationServices
import os

/// 一次当前 Space 自动布局操作的汇总结果，用于设置页展示成功、跳过和失败情况。
struct WindowMaximizationResult {
    /// 最终位置和尺寸均达到目标可用区域的窗口数量。
    let adjustedCount: Int
    /// 已尝试但最终未接受目标位置或尺寸的窗口数量。
    let failedCount: Int
    /// 因窗口类型、最小化、原生全屏或不可调整而跳过的窗口数量。
    let skippedWindowCount: Int
    /// 当前 Space 中命中排除名单并整组跳过的应用数量。
    let excludedApplicationCount: Int
    /// 是否因缺少辅助功能权限而没有读取或修改任何窗口。
    let accessibilityPermissionMissing: Bool
    /// 是否因用户正在拖动窗口或操作被新事件取代而提前取消。
    let cancelled: Bool
}

/// 已确认属于当前 Space、可调整且未被排除的标准窗口及其调整前矩形。
private struct VisibleWindowCandidate {
    /// 供后续写入和回读的辅助功能窗口元素。
    let window: AXUIElement
    /// 批量操作开始前的 AX 全局坐标矩形，用于日志和结果诊断。
    let before: CGRect
    /// 窗口原本所属的显示器 ID，自动布局始终保持该归属，不跟随鼠标跨屏。
    let displayID: CGDirectDisplayID
    /// 按该窗口所属应用和屏幕留白规则计算的 AX 目标矩形。
    let target: CGRect
    /// 该屏的 AX 可用区域，与目标共用稳定快照，供校验和诊断使用。
    let visibleFrame: CGRect
}

final class WindowEdgeController {
    /// 快捷键和程序坞自动策略共享控制器，确保两类延迟校正可以互相取消而不会争抢窗口。
    static let shared = WindowEdgeController()
    /// 每次快捷键操作递增；延迟校正只允许作用于最新一次操作，防止旧任务把窗口移回旧屏幕。
    private var layoutGeneration: UInt64 = 0
    /// 每次自动批量铺满操作递增；显示器变化、用户快捷键或新批次都会使旧回调失效。
    private var automaticMaximizeGeneration: UInt64 = 0
    /// 自动批次被显示器事件或用户快捷键取代时，只回调一次取消结果并清除自身。
    private var automaticMaximizeCancellation: (() -> Void)?
    /// 只记录布局几何数据、进程号和 AX 返回码，供排查跨屏后尺寸被目标应用重新调整的问题。
    private static let layoutLogger = Logger(subsystem: "com.local.WindowEdgeHotkeys", category: "WindowLayout")

    /// 限制实例创建，保证快捷键布局与自动批量铺满使用同一代次和取消机制。
    private init() {}

    /// 智能布局：识别鼠标当前所在的显示器。
    /// - 指定显示器：在 `marginDirection` 一侧留出 `marginPercent`% 的可用宽度或高度。
    /// - 其它显示器：铺满该屏可用区，避开菜单栏和未隐藏的 Dock。
    /// - 排除名单里的 App：不改变窗口大小，但仍会跟随鼠标移动到其所在的显示器。
    func applySmartLayout(designatedName: String, marginDirection: MarginDirection, marginPercent: Double) {
        layoutGeneration &+= 1
        cancelAutomaticWindowMaximization()
        let trusted = AccessibilityPermission.requestIfNeeded(prompt: false)
        if !trusted {
            _ = AccessibilityPermission.requestIfNeeded(prompt: true)
            return
        }
        guard let window = focusedWindowElement() else { return }
        guard let screen = ScreenDetector.screenUnderMouse() else { return }

        // 排除名单里的 App：保持窗口大小不变，只把它移到鼠标所在的显示器。
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if HotKeyPreferences.shared.isExcluded(bundleID: frontBundleID) {
            moveExcludedWindow(window, toMouseScreen: screen)
            return
        }

        let layoutFrame = ScreenDetector.windowLayoutFrame(for: screen)
        let targetCocoa = Self.smartLayoutCocoaRect(
            in: layoutFrame,
            isDesignated: !designatedName.isEmpty && screen.localizedName == designatedName,
            alwaysFullscreen: HotKeyPreferences.shared.isAlwaysFullscreen(bundleID: frontBundleID),
            direction: marginDirection, percent: marginPercent
        )
        applyCocoaRect(targetCocoa, to: window, on: screen, within: layoutFrame)
    }

    /// 取消尚未完成的自动批量铺满及其延迟验收；已完成的窗口调整不会被反向恢复。
    func cancelAutomaticWindowMaximization() {
        automaticMaximizeGeneration &+= 1
        let cancellation = automaticMaximizeCancellation
        automaticMaximizeCancellation = nil
        cancellation?()
    }

    /// 只重排当前 Space 中原本位于受影响屏幕的可见标准窗口，整组跳过排除应用，保留窗口屏幕归属。
    /// Dock 显示时复用快捷键的留白及始终全屏规则；隐藏时沿用无外接屏铺满行为。
    /// 稳定快照覆盖全部屏幕以正确判断归属；每个窗口独立计算目标，初次写入后最多重试一次并回读验收。
    func applySmartLayoutToVisibleWindowsOnCurrentSpace(
        screenLayouts: [ScreenLayoutSnapshot],
        affectedDisplayIDs: Set<CGDirectDisplayID>,
        dockAutohide: Bool,
        completion: @escaping (WindowMaximizationResult) -> Void
    ) {
        layoutGeneration &+= 1
        cancelAutomaticWindowMaximization()
        let generation = automaticMaximizeGeneration
        guard AccessibilityPermission.requestIfNeeded(prompt: false) else {
            completion(WindowMaximizationResult(
                adjustedCount: 0,
                failedCount: 0,
                skippedWindowCount: 0,
                excludedApplicationCount: 0,
                accessibilityPermissionMissing: true,
                cancelled: false
            ))
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            completion(WindowMaximizationResult(
                adjustedCount: 0,
                failedCount: 0,
                skippedWindowCount: 0,
                excludedApplicationCount: 0,
                accessibilityPermissionMissing: false,
                cancelled: true
            ))
            return
        }

        let visibleRectsByPID = currentSpaceWindowRectsByPID()
        var candidates: [VisibleWindowCandidate] = []
        var skippedWindowCount = 0
        var excludedApplicationCount = 0
        let prefs = HotKeyPreferences.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && !app.isTerminated
            && app.processIdentifier != ownPID {
            guard let visibleRects = visibleRectsByPID[app.processIdentifier],
                  visibleRects.contains(where: { rect in
                      guard let id = ScreenDetector.displayID(containing: axToCocoa(rect), in: screenLayouts) else {
                          return false
                      }
                      return affectedDisplayIDs.contains(id)
                  }) else { continue }
            if prefs.isExcluded(bundleID: app.bundleIdentifier) {
                excludedApplicationCount += 1
                continue
            }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.25)
            for window in copyWindows(of: application) {
                guard copyStringAttribute(window, attribute: kAXRoleAttribute) == kAXWindowRole,
                      copyStringAttribute(window, attribute: kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      copyBoolAttribute(window, attribute: kAXMinimizedAttribute) != true,
                      copyBoolAttribute(window, attribute: "AXFullScreen") != true,
                      isAttributeSettable(window, attribute: kAXPositionAttribute),
                      isAttributeSettable(window, attribute: kAXSizeAttribute),
                      let before = windowRect(window: window),
                      Self.matchesCurrentSpaceBounds(before, visibleRects: visibleRects) else {
                    skippedWindowCount += 1
                    continue
                }
                guard let displayID = ScreenDetector.displayID(containing: axToCocoa(before), in: screenLayouts),
                      affectedDisplayIDs.contains(displayID),
                      let screen = screenLayouts.first(where: { $0.displayID == displayID }) else { continue }
                let targetCocoa = Self.smartLayoutCocoaRect(
                    in: screen.layoutFrame,
                    isDesignated: !dockAutohide && !prefs.designatedDisplayName.isEmpty
                        && screen.name == prefs.designatedDisplayName,
                    alwaysFullscreen: prefs.isAlwaysFullscreen(bundleID: app.bundleIdentifier),
                    direction: prefs.marginDirection, percent: prefs.marginPercent
                )
                let targetAX = cocoaToAX(targetCocoa)
                let target = CGRect(
                    x: snap(targetAX.minX, scale: screen.scale, rule: .toNearestOrEven),
                    y: snap(targetAX.minY, scale: screen.scale, rule: .toNearestOrEven),
                    width: snap(targetAX.width, scale: screen.scale, rule: .down),
                    height: snap(targetAX.height, scale: screen.scale, rule: .down)
                )
                candidates.append(VisibleWindowCandidate(window: window, before: before, displayID: displayID,
                                                          target: target, visibleFrame: cocoaToAX(screen.layoutFrame)))
            }
        }

        for candidate in candidates where !Self.rectMatches(candidate.before, candidate.target) {
            let errors = setWindowRect(window: candidate.window, rect: candidate.target)
            logLayout(stage: "auto_layout_initial", window: candidate.window, target: candidate.target,
                      visibleFrame: candidate.visibleFrame, before: candidate.before,
                      actual: windowRect(window: candidate.window), errors: errors)
        }

        if candidates.isEmpty {
            completion(WindowMaximizationResult(
                adjustedCount: 0,
                failedCount: 0,
                skippedWindowCount: skippedWindowCount,
                excludedApplicationCount: excludedApplicationCount,
                accessibilityPermissionMissing: false,
                cancelled: false
            ))
            return
        }

        automaticMaximizeCancellation = {
            completion(WindowMaximizationResult(
                adjustedCount: 0,
                failedCount: candidates.count,
                skippedWindowCount: skippedWindowCount,
                excludedApplicationCount: excludedApplicationCount,
                accessibilityPermissionMissing: false,
                cancelled: true
            ))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.automaticMaximizeGeneration == generation else { return }
            guard self.automaticLayoutIsCurrent(screenLayouts: screenLayouts, dockAutohide: dockAutohide) else {
                self.cancelAutomaticWindowMaximization()
                return
            }
            for candidate in candidates {
                guard let actual = self.windowRect(window: candidate.window),
                      !Self.rectMatches(actual, candidate.target) else { continue }
                guard ScreenDetector.displayID(containing: self.axToCocoa(actual), in: screenLayouts)
                    == candidate.displayID else {
                    self.cancelAutomaticWindowMaximization()
                    return
                }
                let errors = self.setWindowRect(window: candidate.window, rect: candidate.target)
                self.logLayout(stage: "auto_layout_retry", window: candidate.window, target: candidate.target,
                               visibleFrame: candidate.visibleFrame, before: actual,
                               actual: self.windowRect(window: candidate.window), errors: errors)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.automaticMaximizeGeneration == generation else { return }
            guard self.automaticLayoutIsCurrent(screenLayouts: screenLayouts, dockAutohide: dockAutohide) else {
                self.cancelAutomaticWindowMaximization()
                return
            }
            self.automaticMaximizeCancellation = nil
            var adjustedCount = 0
            var failedCount = 0
            for candidate in candidates {
                let actual = self.windowRect(window: candidate.window)
                if let actual, Self.rectMatches(actual, candidate.target) {
                    adjustedCount += 1
                } else {
                    failedCount += 1
                }
                self.logLayout(stage: "auto_layout_final", window: candidate.window, target: candidate.target,
                               visibleFrame: candidate.visibleFrame, before: candidate.before, actual: actual, errors: [:])
            }
            completion(WindowMaximizationResult(
                adjustedCount: adjustedCount,
                failedCount: failedCount,
                skippedWindowCount: skippedWindowCount,
                excludedApplicationCount: excludedApplicationCount,
                accessibilityPermissionMissing: false,
                cancelled: false
            ))
        }
    }

    /// 延迟重试和最终验收前确认屏幕几何、Dock 实值及鼠标拖动状态仍有效，避免重新应用旧区域。
    private func automaticLayoutIsCurrent(screenLayouts: [ScreenLayoutSnapshot], dockAutohide: Bool) -> Bool {
        NSEvent.pressedMouseButtons == 0
            && ScreenDetector.dockAutohideEnabled() == dockAutohide
            && ScreenDetector.windowLayoutSnapshots(dockAutohide: dockAutohide) == screenLayouts
    }

    // MARK: - Layout math (Cocoa coordinates, bottom-left origin)

    /// 快捷键与自动布局共享的目标计算；始终全屏名单优先于指定屏留白，排除名单由调用方提前跳过。
    static func smartLayoutCocoaRect(in layoutFrame: CGRect, isDesignated: Bool, alwaysFullscreen: Bool,
                                    direction: MarginDirection, percent: Double) -> CGRect {
        isDesignated && !alwaysFullscreen
            ? marginCocoaRect(in: layoutFrame, direction: direction, percent: percent)
            : layoutFrame
    }

    /// 在屏幕可用区域内计算单侧留白，使用 Cocoa 左下角原点坐标，最后统一转换为 AX 坐标。
    /// 左右按宽度、上下按高度计算；沿调整方向尽量保留至少 80 点，并以相对边锚定避免越界。
    /// 当可用尺寸本身不足 80 点时使用完整可用尺寸；不读取鼠标或窗口状态，便于独立验证布局。
    static func marginCocoaRect(in visibleFrame: CGRect, direction: MarginDirection, percent: Double) -> CGRect {
        let ratio = CGFloat(HotKeyPreferences.clampedMarginPercent(percent) / 100)
        switch direction {
        case .left, .right:
            let width = min(visibleFrame.width, max(80, visibleFrame.width * (1 - ratio)))
            let x = direction == .left ? visibleFrame.maxX - width : visibleFrame.minX
            return CGRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
        case .top, .bottom:
            let height = min(visibleFrame.height, max(80, visibleFrame.height * (1 - ratio)))
            let y = direction == .bottom ? visibleFrame.maxY - height : visibleFrame.minY
            return CGRect(x: visibleFrame.minX, y: y, width: visibleFrame.width, height: height)
        }
    }

    // MARK: - Coordinate conversion (Cocoa bottom-left → Accessibility top-left)

    /// AX/Quartz 全局坐标以主屏左上角为原点、Y 向下；NSScreen 以主屏左下角为原点、Y 向上。
    /// 用主屏（原点屏）高度做一次翻转，任意副屏都能摆对。
    private func cocoaToAX(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.height
        let axY = primaryHeight - rect.maxY
        return CGRect(x: rect.minX, y: axY, width: rect.width, height: rect.height)
    }

    /// AX（左上原点）→ Cocoa（左下原点）。用主屏高度翻转，与 `cocoaToAX` 互逆。
    private func axToCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.height
        let cocoaY = primaryHeight - (rect.origin.y + rect.height)
        return CGRect(x: rect.minX, y: cocoaY, width: rect.width, height: rect.height)
    }

    // MARK: - Excluded app: move only, keep size

    /// 排除名单里的窗口：宽高不变，仅在其当前不在鼠标所在屏时，移动到该屏可用区的正中央（越界则夹取）。
    private func moveExcludedWindow(_ window: AXUIElement, toMouseScreen mouseScreen: NSScreen) {
        guard let axRect = windowRect(window: window) else { return }
        let cocoaRect = axToCocoa(axRect)

        // 已经在鼠标所在屏则不动。
        guard let sourceScreen = ScreenDetector.screen(containing: cocoaRect) else { return }
        if sourceScreen == mouseScreen { return }

        let dstVF = ScreenDetector.windowLayoutFrame(for: mouseScreen)

        // 居中到目标屏可用区。
        var newX = dstVF.midX - cocoaRect.width / 2
        var newBottom = dstVF.midY - cocoaRect.height / 2

        // 夹取，保证窗口完整落在目标屏可用区内（尺寸大于目标屏时贴左上）。
        newX = min(max(newX, dstVF.minX), max(dstVF.minX, dstVF.maxX - cocoaRect.width))
        newBottom = min(max(newBottom, dstVF.minY), max(dstVF.minY, dstVF.maxY - cocoaRect.height))
        let newCocoa = CGRect(x: newX, y: newBottom, width: cocoaRect.width, height: cocoaRect.height)

        let scale = mouseScreen.backingScaleFactor
        let ax = cocoaToAX(newCocoa)
        let origin = CGPoint(
            x: snap(ax.minX, scale: scale, rule: .toNearestOrEven),
            y: snap(ax.minY, scale: scale, rule: .toNearestOrEven)
        )
        _ = withResizeCompatibility(window: window) {
            ["position": setWindowPosition(window: window, origin: origin).rawValue]
        }
    }

    /// 将完整目标矩形写入窗口，使用目标屏幕的缩放比例，随后检查目标应用实际接受的位置和尺寸。
    /// 跨屏时系统可能按旧屏约束尺寸，应用也可能稍后恢复最大化尺寸，因此在 120/350ms 按需校正、600ms 最终验收。
    /// 校正次数固定；新快捷键、焦点切换、目标屏断开或检测到鼠标拖动时取消，不进行常驻轮询。
    /// within 与初始目标共用同一布局区域快照，防止最终位置夹取又把窗口移回隐藏 Dock 的旧预留区域。
    private func applyCocoaRect(_ cocoaRect: CGRect, to window: AXUIElement, on screen: NSScreen,
                                within layoutFrame: CGRect) {
        let generation = layoutGeneration
        let scale = screen.backingScaleFactor
        let ax = cocoaToAX(cocoaRect)
        let visibleAX = cocoaToAX(layoutFrame)
        let target = CGRect(
            x: snap(ax.minX, scale: scale, rule: .toNearestOrEven),
            y: snap(ax.minY, scale: scale, rule: .toNearestOrEven),
            width: snap(ax.width, scale: scale, rule: .down),
            height: snap(ax.height, scale: scale, rule: .down)
        )
        let before = windowRect(window: window)
        let errors = setWindowRect(window: window, rect: target)
        logLayout(stage: "initial", window: window, target: target, visibleFrame: visibleAX,
                  before: before, actual: windowRect(window: window), errors: errors)

        for (index, delay) in [0.12, 0.35, 0.60].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                guard NSEvent.pressedMouseButtons == 0,
                      NSScreen.screens.contains(screen),
                      let focused = self.focusedWindowElement(), CFEqual(window, focused) else {
                    self.layoutGeneration &+= 1
                    return
                }
                guard let actual = self.windowRect(window: window) else { return }
                if Self.rectMatches(actual, target) {
                    if index == 2 {
                        self.logLayout(stage: "settled", window: window, target: target, visibleFrame: visibleAX,
                                       before: actual, actual: actual, errors: [:])
                    }
                    return
                }

                var retryErrors: [String: Int32] = [:]
                if index < 2 {
                    retryErrors = self.setWindowRect(window: window, rect: target)
                }
                // 最终验收与最后一次尺寸请求间隔 250ms，避免把尚未完成的缩放直接当成最小尺寸限制。
                // 若应用仍未接受目标尺寸，优先把实际窗口收回屏内；必要时减少留白。
                // 若应用连屏幕大小都不接受，只能贴住可用区域左上角，并在日志中保留实际溢出尺寸。
                if index == 2 {
                    let origin = Self.containedOrigin(for: actual, preferredOrigin: target.origin, in: visibleAX)
                    if abs(actual.minX - origin.x) > 0.5 || abs(actual.minY - origin.y) > 0.5 {
                        retryErrors = self.withResizeCompatibility(window: window) {
                            ["containPosition": self.setWindowPosition(window: window, origin: origin).rawValue]
                        }
                    }
                }
                self.logLayout(stage: index == 2 ? "final_mismatch" : "retry_\(index + 1)", window: window,
                               target: target, visibleFrame: visibleAX, before: actual,
                               actual: self.windowRect(window: window), errors: retryErrors)
            }
        }
    }

    /// 位置和宽高均须落在半个逻辑点的误差内；只比较原点会漏掉“顶部正确但底部溢出”的窗口。
    static func rectMatches(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.minX - target.minX) <= 0.5 && abs(actual.minY - target.minY) <= 0.5
            && abs(actual.width - target.width) <= 0.5 && abs(actual.height - target.height) <= 0.5
    }

    /// 按实际尺寸夹取 AX 左上角坐标，尽量保留首选位置并防止右侧/底部溢出。
    /// 当实际尺寸大于可用区域时，优先保持左上角可操作，不能声称已经把整个窗口放入屏内。
    static func containedOrigin(for actual: CGRect, preferredOrigin: CGPoint, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - actual.width)),
            y: min(max(preferredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - actual.height))
        )
    }

    /// 将每次初始布局、实际发生的重试及最终稳定结果记录为 JSON；不采集窗口标题或内容。
    /// before/actual/target/visibleFrame 的数组顺序均为 AX 坐标中的 [x, y, width, height]。
    private func logLayout(stage: String, window: AXUIElement, target: CGRect, visibleFrame: CGRect,
                           before: CGRect?, actual: CGRect?, errors: [String: Int32]) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let payload: [String: Any] = [
            "stage": stage, "pid": pid, "generation": layoutGeneration,
            "windowToken": CFHash(window),
            "bundleID": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "",
            "target": Self.rectComponents(target), "visibleFrame": Self.rectComponents(visibleFrame),
            "before": before.map(Self.rectComponents) as Any? ?? NSNull(),
            "actual": actual.map(Self.rectComponents) as Any? ?? NSNull(),
            "matchesTarget": actual.map { Self.rectMatches($0, target) } ?? false,
            "axErrors": errors
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
              let message = String(data: data, encoding: .utf8) else { return }
        Self.layoutLogger.notice("window_layout \(message, privacy: .public)")
    }

    /// 按固定顺序输出矩形数值，方便比较目标底边 y + height 与可用区域底边。
    private static func rectComponents(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private func snap(_ value: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(rule) / scale
    }

    /// 读取当前 Space 中屏幕层级为普通窗口的 Quartz 矩形，并按进程分组供 AX 窗口匹配。
    /// 只使用 PID、层级和几何信息，不读取窗口标题或内容，也不需要屏幕录制权限。
    private func currentSpaceWindowRectsByPID() -> [pid_t: [CGRect]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        for row in rows {
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNumber = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 1, rect.height > 1 else { continue }
            result[pidNumber.int32Value, default: []].append(rect)
        }
        return result
    }

    /// 用同一 PID 下的 Quartz 屏幕矩形确认 AX 窗口属于当前 Space；只允许少量边框和缩放取整误差。
    /// 不使用“有大面积交集”作为兜底，避免把其它 Space 中坐标相近的窗口误判为当前窗口。
    private static func matchesCurrentSpaceBounds(_ axRect: CGRect, visibleRects: [CGRect]) -> Bool {
        guard axRect.width.isFinite, axRect.height.isFinite, axRect.width > 1, axRect.height > 1 else { return false }
        let tolerance: CGFloat = 4
        return visibleRects.contains {
            abs(axRect.minX - $0.minX) <= tolerance
                && abs(axRect.minY - $0.minY) <= tolerance
                && abs(axRect.width - $0.width) <= tolerance
                && abs(axRect.height - $0.height) <= tolerance
        }
    }

    // MARK: - Accessibility helpers

    /// 读取一个应用公开的全部 AX 窗口；失败、超时或返回类型异常时按无窗口处理。
    private func copyWindows(of application: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard error == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// 读取 AX 字符串属性，用于筛选标准窗口角色；属性缺失或类型不符时返回 nil。
    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    /// 读取 AX 布尔属性，用于保留最小化和原生全屏状态；不支持该属性时返回 nil。
    private func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// 确认窗口允许写入指定 AX 属性，避免对固定尺寸窗口和不可移动面板发出无效请求。
    private func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    private func focusedWindowElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        var window: AnyObject?
        let error = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &window)
        guard error == .success else { return nil }
        return window as! AXUIElement?
    }

    private func windowRect(window: AXUIElement) -> CGRect? {
        guard let pos = copyCGPointAttribute(window: window, attribute: kAXPositionAttribute) else { return nil }
        guard let size = copyCGSizeAttribute(window: window, attribute: kAXSizeAttribute) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// AX 的位置和尺寸只能分别写入：先缩放，再跨屏移动，再在目标屏重新设置尺寸。
    /// 这覆盖旧屏尺寸约束和跨屏后的最大化尺寸恢复；最后修正部分应用缩放时重置的位置。
    /// 返回每一步原始 AX 状态码用于日志，是否真正生效仍以窗口矩形回读为准。
    @discardableResult
    private func setWindowRect(window: AXUIElement, rect: CGRect) -> [String: Int32] {
        withResizeCompatibility(window: window) {
            var errors: [String: Int32] = [:]
            errors["sizeBeforeMove"] = setWindowSize(window: window, size: rect.size).rawValue
            errors["position"] = setWindowPosition(window: window, origin: rect.origin).rawValue
            errors["sizeAfterMove"] = setWindowSize(window: window, size: rect.size).rawValue
            if let actual = windowRect(window: window),
               abs(actual.minX - rect.minX) > 0.5 || abs(actual.minY - rect.minY) > 0.5 {
                errors["positionAfterResize"] = setWindowPosition(window: window, origin: rect.origin).rawValue
            }
            return errors
        }
    }

    /// 部分应用开启 AXEnhancedUserInterface 后，窗口写入会动画执行，连续的尺寸/位置请求可能互相覆盖。
    /// 按应用实际能力检查该属性，不按 Chrome 等应用名限制；GoLand 多个窗口分别通过自身 PID 定位所属应用。
    /// 仅原值为 true 时，在一次同步调整期间尝试关闭并用 defer 恢复；不跨越延迟重试持有此状态。
    /// 部分应用写入返回失败却实际生效，因此恢复判断同时使用返回码和回读，避免遗留关闭状态。
    /// 属性不支持、读取失败或原值为 false 时不写入；VoiceOver/切换控制启用时保留其辅助功能模式。
    /// 状态恢复发生在返回结果之前，确保日志同时保留窗口写入和状态恢复的原始 AX 返回码。
    private func withResizeCompatibility(window: AXUIElement, update: () -> [String: Int32]) -> [String: Int32] {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return update()
        }
        let application = AXUIElementCreateApplication(pid)
        let attribute = "AXEnhancedUserInterface" as CFString
        var errors: [String: Int32] = [:]
        var states: [String: Any] = [
            "pid": pid, "generation": layoutGeneration, "windowToken": CFHash(window),
            "bundleID": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        ]
        let assistiveTechnologyEnabled = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        states["assistiveTechnologyEnabled"] = assistiveTechnologyEnabled
        var originalValue: AnyObject?
        let readError = AXUIElementCopyAttributeValue(application, attribute, &originalValue)
        errors["enhancedUIRead"] = readError.rawValue
        let wasEnabled = (originalValue as? NSNumber)?.boolValue
        states["before"] = wasEnabled as Any? ?? NSNull()

        do {
            var shouldRestore = false
            var attemptedDisable = false
            if readError == .success, wasEnabled == true, !assistiveTechnologyEnabled {
                attemptedDisable = true
                let disableError = AXUIElementSetAttributeValue(application, attribute, kCFBooleanFalse)
                errors["enhancedUIDisable"] = disableError.rawValue
                shouldRestore = disableError == .success
            }
            defer {
                if shouldRestore {
                    errors["enhancedUIRestore"] = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue).rawValue
                }
                var finalValue: AnyObject?
                errors["enhancedUIReadAfter"] = AXUIElementCopyAttributeValue(application, attribute, &finalValue).rawValue
                states["after"] = (finalValue as? NSNumber)?.boolValue as Any? ?? NSNull()
            }

            var currentValue: AnyObject?
            let currentReadError = AXUIElementCopyAttributeValue(application, attribute, &currentValue)
            errors["enhancedUIReadDuring"] = currentReadError.rawValue
            let isEnabledDuring = (currentValue as? NSNumber)?.boolValue
            states["during"] = isEnabledDuring as Any? ?? NSNull()
            // 写入报错后仍可能已关闭；无法确认当前值时也恢复已知原值，只有确认未改变才跳过。
            if attemptedDisable, currentReadError != .success || isEnabledDuring != true {
                shouldRestore = true
            }
            errors.merge(update(), uniquingKeysWith: { _, new in new })
        }

        states["axErrors"] = errors
        if let data = try? JSONSerialization.data(withJSONObject: states, options: .sortedKeys),
           let message = String(data: data, encoding: .utf8) {
            Self.layoutLogger.notice("window_resize_compat \(message, privacy: .public)")
        }
        return errors
    }

    /// 仅调整窗口大小并忠实返回 AX 状态；调用方结合回读判断应用是否接受目标尺寸。
    @discardableResult
    private func setWindowSize(window: AXUIElement, size: CGSize) -> AXError {
        var requestedSize = size
        guard let value = AXValueCreate(.cgSize, &requestedSize) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// 仅移动窗口并返回 AX 状态；排除名单仍只调用此方法，不改变窗口尺寸。
    @discardableResult
    private func setWindowPosition(window: AXUIElement, origin: CGPoint) -> AXError {
        var point = origin
        guard let pos = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
    }

    private func copyCGPointAttribute(window: AXUIElement, attribute: String) -> CGPoint? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        let ok = AXValueGetValue(axValue, .cgPoint, &point)
        return ok ? point : nil
    }

    private func copyCGSizeAttribute(window: AXUIElement, attribute: String) -> CGSize? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        let ok = AXValueGetValue(axValue, .cgSize, &size)
        return ok ? size : nil
    }
}
