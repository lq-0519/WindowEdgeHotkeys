import AppKit
import CoreGraphics
import OSLog

/// 一次刷新中可以确定并执行的程序坞目标；nil 表示对应策略关闭或本次检测无法可靠判断。
private struct DockTargetState {
    /// 位置策略的目标边缘，当前只会是 AppleScript 接受的 bottom 或 left。
    let position: String?
    /// 自动隐藏策略的目标值：无外接显示器时为 true，存在外接显示器时为 false。
    let autohide: Bool?
    /// 本次读取到的物理盖子状态，仅用于位置状态文案和诊断日志。
    let lidClosed: Bool?
    /// 本次可靠检测到的在线外接显示器数量；未执行或检测失败时为 nil。
    let externalDisplayCount: Int?
}

/// 监听物理开合盖、屏幕连接和唤醒事件，按独立开关调整程序坞位置与自动隐藏。
/// 所有状态在主线程维护；通过异步子进程发送 Apple Events，授权等待不会阻塞窗口快捷键。
final class DockPositionController: NSObject, ObservableObject {
    /// 应用与设置页使用同一实例；进程生命周期内保持显示器回调的上下文有效。
    static let shared = DockPositionController()
    /// 设置页展示最近一次检测或调整结果，不把失败的操作显示为已完成。
    @Published private(set) var statusText = "正在检测程序坞状态…"
    /// Apple Events 被拒绝时展示自动化设置入口，由用户在系统中授予权限。
    @Published private(set) var needsAutomationPermission = false
    /// Dock 已隐藏但缺少窗口控制权限时展示辅助功能设置入口。
    @Published private(set) var needsAccessibilityPermission = false
    /// 检测或执行失败后提供手动重试，避免后台不断请求授权。
    @Published private(set) var canRetry = false

    /// 日志仅包含开合盖状态、显示器 ID、程序坞目标和系统脚本结果，不读取应用窗口内容。
    private let logger = Logger(subsystem: "com.local.WindowEdgeHotkeys", category: "DockPosition")
    /// 防止重复注册通知；退出应用后不再安排任何任务。
    private var started = false
    /// 开关开启期间才注册硬件通知；关闭后只保留开关通知，避免无效事件唤醒。
    private var monitoring = false
    /// 原生盖子状态读取和推送监听器，复用电源节点，避免启动检测用的子进程。
    private let lidMonitor = LidStateMonitor()
    /// 与快捷键共享窗口控制器；外接屏重新连接或用户快捷键会取消旧的批量铺满。
    private let windowController = WindowEdgeController.shared
    /// 记录 Core Graphics 回调是否注册成功，用于成对注销。
    private var displayCallbackRegistered = false
    /// 系统休眠期间暂停调整，等待 didWake 后重新读取显示器。
    private var systemSleeping = false
    /// 屏幕休眠独立于整机休眠，只有两者均唤醒才开始调整。
    private var screensSleeping = false
    /// 屏幕配置开始到完成期间暂停读取，避免将中间状态识别为拔线。
    private var displayReconfiguring = false
    /// 可撤销的单次计时器合并短时间内的事件；取消时移除底层计时，空闲时不存在定时任务。
    private var refreshTimer: DispatchSourceTimer?
    /// Dock 隐藏后等待屏幕可用区域扩展的单次计时器，最多进行三次有界检查。
    private var windowMaximizeWaitTimer: DispatchSourceTimer?
    /// 标识最新屏幕状态或开关操作，过期脚本完成后仅触发一次重新检测。
    private var generation: UInt64 = 0
    /// 同时最多执行一个脚本；两个策略均关闭时终止尚未完成的子进程。
    private var scriptProcess: Process?
    /// 脚本授权或执行超时后的终止任务，避免子进程一直驻留。
    private var scriptTimeout: DispatchSourceTimer?
    /// 区分超时终止与系统脚本正常返回的错误。
    private var scriptTimedOut = false
    /// 辅助功能缺失或部分窗口失败后保留手动重试入口，不因 Dock 已经隐藏而丢失操作。
    private var pendingWindowMaximization = false
    /// 标记等待可用区域或批量验收尚未结束；硬件事件取消时据此保留一次手动重试。
    private var windowMaximizationInProgress = false
    /// 任一程序坞策略开启时保持硬件监听；两个策略关闭后立即释放监听和等待任务。
    private var isAutomationEnabled: Bool {
        let prefs = HotKeyPreferences.shared
        return prefs.automaticallyPositionsDock || prefs.automaticallyControlsDockAutohide
    }

    /// Core Graphics 回调只转发事件到主队列，绝不在显示器重配置回调中修改系统设置。
    private let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context else { return }
        let controller = Unmanaged<DockPositionController>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak controller] in
            controller?.displayConfigurationChanged(flags)
        }
    }

    /// 限制实例创建，确保设置页和 AppDelegate 不会各自注册监听或同时修改程序坞。
    private override init() {
        super.init()
    }

    /// 应用启动时仅固定监听开关；硬件监听和首次同步由两个持久化策略共同决定。
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(preferenceChanged), name: .dockAutomationPreferenceDidChange, object: nil)
        preferenceChanged()
    }

    /// 开启后注册盖子、显示器和睡眠通知；AppKit 屏幕通知仅在 Core Graphics 注册失败时兜底。
    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        systemSleeping = false
        screensSleeping = false
        displayReconfiguring = false
        lidMonitor.onChange = { [weak self] in self?.scheduleRefresh(reason: "lid_changed") }
        if !lidMonitor.start() {
            logger.error("dock_lid_notification_registration_failed")
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(sleepStateChanged(_:)), name: name, object: nil)
        }
        let error = CGDisplayRegisterReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
        displayCallbackRegistered = error == .success
        if error != .success {
            NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
            logger.error("dock_display_callback_failed error=\(error.rawValue)")
        }
    }

    /// 关闭功能时注销全部硬件通知，取消单次计时器，并终止尚未完成的调整脚本。
    private func stopMonitoring() {
        monitoring = false
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
        lidMonitor.stop()
        cancelPendingWork(terminateScript: true)
    }

    /// 移除所有监听，取消等待任务并终止脚本；退出时不额外恢复或修改程序坞设置。
    func stop() {
        guard started else { return }
        started = false
        NotificationCenter.default.removeObserver(self)
        stopMonitoring()
    }

    /// 设置页的手动重试入口；窗口批次待重试时直接复核无外接屏条件，否则重新检测全部硬件状态。
    func retry() {
        if pendingWindowMaximization,
           HotKeyPreferences.shared.automaticallyControlsDockAutohide,
           let displays = ScreenDetector.onlineDisplayIDs(),
           displays.allSatisfy({ CGDisplayIsBuiltin($0) != 0 }) {
            cancelPendingWork(terminateScript: false)
            pendingWindowMaximization = false
            let target = DockTargetState(position: nil, autohide: true, lidClosed: nil, externalDisplayCount: 0)
            scheduleWindowMaximization(
                target: target,
                visibleFrameBeforeAutohide: nil,
                failedDetectionStates: [],
                reason: "manual_window_retry",
                attempt: 0,
                requestedGeneration: generation
            )
            return
        }
        scheduleRefresh(reason: "manual_retry")
    }

    /// 打开 macOS 自动化权限设置；权限必须由用户授予，本程序不修改 TCC 数据。
    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开 macOS 辅助功能权限设置；批量铺满窗口只在系统已授权时执行，不主动反复弹窗。
    func openAccessibilitySettings() {
        AccessibilityPermission.openPrivacyPane()
    }

    /// 两个开关独立即时生效；全部关闭时释放监听，任一开启时按当前硬件状态重新计算。
    @objc private func preferenceChanged() {
        needsAutomationPermission = false
        if !HotKeyPreferences.shared.automaticallyControlsDockAutohide {
            pendingWindowMaximization = false
            needsAccessibilityPermission = false
        }
        if !pendingWindowMaximization {
            needsAccessibilityPermission = false
            canRetry = false
        }
        if isAutomationEnabled {
            startMonitoring()
            if !pendingWindowMaximization {
                statusText = "正在检测程序坞状态…"
            }
            scheduleRefresh(reason: "enabled")
        } else {
            stopMonitoring()
            statusText = "程序坞自动调整已关闭，保留当前设置"
        }
    }

    /// Core Graphics 注册失败时使用 AppKit 通知兜底，正常情况下不订阅两套重复的屏幕事件。
    @objc private func screenParametersChanged() {
        scheduleRefresh(reason: "screen_parameters_changed")
    }

    /// 分别追踪系统和屏幕休眠；睡眠时撤销任务，唤醒后留出一秒等待显示器重新连接。
    @objc private func sleepStateChanged(_ notification: Notification) {
        guard monitoring else { return }
        switch notification.name {
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        default: return
        }
        if systemSleeping || screensSleeping {
            cancelPendingWork(terminateScript: true)
        } else {
            scheduleRefresh(reason: "wake")
        }
    }

    /// 区分重配置开始与结束；合盖、镜像及多次热插拔统一从最终在线显示器列表判断。
    private func displayConfigurationChanged(_ flags: CGDisplayChangeSummaryFlags) {
        guard monitoring else { return }
        if flags.contains(.beginConfigurationFlag) {
            displayReconfiguring = true
            cancelPendingWork(terminateScript: false)
        } else {
            displayReconfiguring = false
            scheduleRefresh(reason: "display_configuration_changed")
        }
    }

    /// 使之前的回调结果过期；已发送的 Apple Event 无法撤回，完成后不会继续重复执行。
    private func cancelPendingWork(terminateScript: Bool) {
        let interruptedWindowMaximization = windowMaximizeWaitTimer != nil || windowMaximizationInProgress
        generation &+= 1
        refreshTimer?.cancel()
        refreshTimer = nil
        windowMaximizeWaitTimer?.cancel()
        windowMaximizeWaitTimer = nil
        windowController.cancelAutomaticWindowMaximization()
        windowMaximizationInProgress = false
        if interruptedWindowMaximization, HotKeyPreferences.shared.automaticallyControlsDockAutohide {
            pendingWindowMaximization = true
            canRetry = true
            if !needsAccessibilityPermission {
                statusText = "窗口铺满被新的硬件状态中断；确认无外接显示器后可重试"
            }
        }
        if terminateScript, let process = scriptProcess, process.isRunning {
            process.terminate()
        }
    }

    /// 合并一秒内的事件；没有周期性轮询，检测异常最多额外重试两次。
    private func scheduleRefresh(reason: String, attempt: Int = 0) {
        guard started, monitoring, isAutomationEnabled else { return }
        cancelPendingWork(terminateScript: false)
        guard !systemSleeping, !screensSleeping, !displayReconfiguring else { return }
        let requestedGeneration = generation
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            self.refresh(reason: reason, attempt: attempt, requestedGeneration: requestedGeneration)
        }
        refreshTimer = timer
        timer.resume()
    }

    /// 分别计算位置和自动隐藏目标；一项检测失败时仍执行另一项可可靠确定的策略。
    /// 位置策略开盖时无需查询显示器，自动隐藏策略则始终按在线非内建显示器判断。
    private func refresh(reason: String, attempt: Int, requestedGeneration: UInt64) {
        guard scriptProcess == nil else { return }
        let prefs = HotKeyPreferences.shared
        let positionEnabled = prefs.automaticallyPositionsDock
        let autohideEnabled = prefs.automaticallyControlsDockAutohide
        var failedDetectionStates: [String] = []

        var lidClosed: Bool?
        if positionEnabled {
            lidClosed = lidMonitor.isClosed()
            if lidClosed == nil {
                failedDetectionStates.append("开合盖")
            }
        }

        let displayQueryRequired = autohideEnabled || lidClosed == true
        var displays: [CGDirectDisplayID]?
        if displayQueryRequired {
            displays = ScreenDetector.onlineDisplayIDs()
            if displays == nil {
                failedDetectionStates.append("显示器")
            }
        }

        let externalDisplays = displays?.filter { CGDisplayIsBuiltin($0) == 0 }
        var positionTarget: String?
        if positionEnabled, let lidClosed {
            if !lidClosed {
                positionTarget = "bottom"
            } else if let externalDisplays {
                positionTarget = externalDisplays.isEmpty ? "bottom" : "left"
            }
        }
        let autohideTarget = autohideEnabled ? externalDisplays.map(\.isEmpty) : nil
        let target = DockTargetState(
            position: positionTarget,
            autohide: autohideTarget,
            lidClosed: lidClosed,
            externalDisplayCount: externalDisplays?.count
        )
        if autohideTarget != true {
            pendingWindowMaximization = false
        }
        guard positionTarget != nil || autohideTarget != nil else {
            detectionFailed(reason: reason, attempt: attempt, states: failedDetectionStates)
            return
        }

        // 同步偏好缓存后只读当前值；全部匹配时无需启动脚本，也不会弹出不必要的授权请求。
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let currentPosition =
            CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        let currentAutohide =
            (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? NSNumber)?.boolValue
        let positionNeedsChange = positionTarget.map { currentPosition != $0 } ?? false
        let autohideNeedsChange = autohideTarget.map { currentAutohide != $0 } ?? false
        if !positionNeedsChange, !autohideNeedsChange {
            logger.debug("dock_automation_unchanged reason=\(reason, privacy: .public)")
            if failedDetectionStates.isEmpty {
                if pendingWindowMaximization, autohideTarget == true {
                    canRetry = true
                } else {
                    showSuccess(target: target)
                }
            } else {
                detectionFailed(reason: reason, attempt: attempt, states: failedDetectionStates)
            }
            return
        }

        let request: [String: Any] = [
            "reason": reason,
            "attempt": attempt,
            "position_enabled": positionEnabled,
            "autohide_enabled": autohideEnabled,
            "lid_closed": jsonValue(lidClosed),
            "display_query_performed": displayQueryRequired,
            "display_ids": displays ?? [],
            "external_display_ids": externalDisplays ?? [],
            "before_position": currentPosition ?? "unknown",
            "before_autohide": jsonValue(currentAutohide),
            "target_position": jsonValue(positionTarget),
            "target_autohide": jsonValue(autohideTarget),
            "detection_failures": failedDetectionStates
        ]
        let maximizeWindowsAfterAutohide = autohideNeedsChange && autohideTarget == true
        let visibleFrameBeforeAutohide =
            maximizeWindowsAfterAutohide ? ScreenDetector.builtInScreen()?.visibleFrame : nil
        runScript(
            target: target,
            changesPosition: positionNeedsChange,
            changesAutohide: autohideNeedsChange,
            maximizeWindowsAfterAutohide: maximizeWindowsAfterAutohide,
            visibleFrameBeforeAutohide: visibleFrameBeforeAutohide,
            failedDetectionStates: failedDetectionStates,
            reason: reason,
            attempt: attempt,
            request: request,
            requestedGeneration: requestedGeneration
        )
    }

    /// 只为本次未知的硬件状态安排最多两次单次重试；已确定的另一项策略不受影响。
    private func detectionFailed(reason: String, attempt: Int, states: [String]) {
        let stateText = states.isEmpty ? "硬件" : states.joined(separator: "、")
        statusText = "暂时无法确定\(stateText)状态，已保留对应的程序坞设置"
        needsAutomationPermission = false
        canRetry = true
        logger.error("dock_state_query_failed states=\(stateText, privacy: .public) attempt=\(attempt)")
        if attempt < 2 { scheduleRefresh(reason: reason, attempt: attempt + 1) }
    }

    /// 只修改本次已确定的程序坞属性并返回边缘和自动隐藏实值；保持 Dock 进程及其它偏好不变。
    /// stdout、stderr 和退出码在完成时原样记录为 JSON，子进程等待期间主线程仍可响应设置与快捷键。
    private func runScript(
        target: DockTargetState,
        changesPosition: Bool,
        changesAutohide: Bool,
        maximizeWindowsAfterAutohide: Bool,
        visibleFrameBeforeAutohide: CGRect?,
        failedDetectionStates: [String],
        reason: String,
        attempt: Int,
        request: [String: Any],
        requestedGeneration: UInt64
    ) {
        let positionStatement = target.position.map {
            "if screen edge is not \($0) then set screen edge to \($0)"
        } ?? ""
        let autohideStatement = target.autohide.map {
            "if autohide is not \($0) then set autohide to \($0)"
        } ?? ""
        let source = """
        with timeout of 15 seconds
            tell application "System Events"
                tell dock preferences
                    \(positionStatement)
                    \(autohideStatement)
                    return (screen edge as text) & "|" & (autohide as text)
                end tell
            end tell
        end timeout
        """
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self?.scriptFinished(
                    finished,
                    target: target,
                    maximizeWindowsAfterAutohide: maximizeWindowsAfterAutohide,
                    visibleFrameBeforeAutohide: visibleFrameBeforeAutohide,
                    failedDetectionStates: failedDetectionStates,
                    reason: reason,
                    attempt: attempt,
                    request: request,
                    stdout: stdout,
                    stderr: stderr,
                    requestedGeneration: requestedGeneration
                )
            }
        }
        scriptProcess = process
        scriptTimedOut = false
        if changesPosition, changesAutohide {
            statusText = "正在调整程序坞位置和自动隐藏…"
        } else if changesPosition {
            statusText = "正在将程序坞调整到\(target.position == "left" ? "左侧" : "底部")…"
        } else {
            statusText = "正在\(target.autohide == true ? "打开" : "关闭")程序坞自动隐藏…"
        }
        canRetry = false
        needsAutomationPermission = false
        do {
            try process.run()
        } catch {
            scriptProcess = nil
            statusText = "无法启动程序坞调整，请重试"
            canRetry = true
            recordScript(request: request, response: ["launch_error": error.localizedDescription])
            return
        }
        // 授权弹窗可能需要用户操作；最多等待 45 秒，并且用户关闭开关时可以提前终止。
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + 45, leeway: .seconds(1))
        timeout.setEventHandler { [weak self, weak process] in
            guard let self, let process, self.scriptProcess === process, process.isRunning else { return }
            self.scriptTimeout?.cancel()
            self.scriptTimeout = nil
            self.scriptTimedOut = true
            process.terminate()
        }
        scriptTimeout = timeout
        timeout.resume()
    }

    /// 验证脚本返回的两个程序坞属性并展示结果；旧硬件状态不会覆盖新状态，授权失败不自动反复重试。
    private func scriptFinished(
        _ process: Process,
        target: DockTargetState,
        maximizeWindowsAfterAutohide: Bool,
        visibleFrameBeforeAutohide: CGRect?,
        failedDetectionStates: [String],
        reason: String,
        attempt: Int,
        request: [String: Any],
        stdout: String,
        stderr: String,
        requestedGeneration: UInt64
    ) {
        guard scriptProcess === process else { return }
        scriptProcess = nil
        scriptTimeout?.cancel()
        scriptTimeout = nil
        let timedOut = scriptTimedOut
        let superseded = generation != requestedGeneration
        defer {
            recordScript(request: request, response: ["stdout": stdout, "stderr": stderr,
                         "exit_status": process.terminationStatus, "timed_out": timedOut,
                         "superseded": superseded])
        }
        guard started, isAutomationEnabled, !systemSleeping, !screensSleeping else { return }
        if superseded {
            scheduleRefresh(reason: "state_changed_during_script")
            return
        }
        let values = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let returnedPosition = values.first
        let returnedAutohide: Bool?
        if values.count > 1, values[1] == "true" {
            returnedAutohide = true
        } else if values.count > 1, values[1] == "false" {
            returnedAutohide = false
        } else {
            returnedAutohide = nil
        }
        let positionMatches = target.position.map { returnedPosition == $0 } ?? true
        let autohideMatches = target.autohide.map { returnedAutohide == $0 } ?? true
        if !timedOut, process.terminationStatus == 0, positionMatches, autohideMatches {
            if maximizeWindowsAfterAutohide {
                scheduleWindowMaximization(
                    target: target,
                    visibleFrameBeforeAutohide: visibleFrameBeforeAutohide,
                    failedDetectionStates: failedDetectionStates,
                    reason: reason,
                    attempt: attempt,
                    requestedGeneration: requestedGeneration
                )
            } else if failedDetectionStates.isEmpty {
                showSuccess(target: target)
            } else {
                detectionFailed(reason: reason, attempt: attempt, states: failedDetectionStates)
            }
        } else {
            needsAutomationPermission = stderr.contains("(-1743)") || stderr.contains("(-1744)")
            canRetry = true
            if needsAutomationPermission {
                statusText = "请在系统自动化设置中允许本应用控制“系统事件”，然后重试"
            } else if timedOut {
                statusText = "调整超时；如有系统授权提示，请允许后重试"
            } else {
                statusText = "程序坞调整未完成，请重试"
            }
        }
    }

    /// 在 Dock 自动隐藏成功后等待内建屏可用区域扩展，再启动一次当前 Space 窗口批量铺满。
    /// 检查次数固定且可被显示器、睡眠和偏好事件取消；最终仍未扩展时保留手动重试，不使用旧区域调整窗口。
    private func scheduleWindowMaximization(
        target: DockTargetState,
        visibleFrameBeforeAutohide: CGRect?,
        failedDetectionStates: [String],
        reason: String,
        attempt: Int,
        requestedGeneration: UInt64,
        frameCheckAttempt: Int = 0
    ) {
        guard started, monitoring, requestedGeneration == generation,
              HotKeyPreferences.shared.automaticallyControlsDockAutohide,
              !systemSleeping, !screensSleeping else { return }
        windowMaximizationInProgress = true
        windowMaximizeWaitTimer?.cancel()
        windowMaximizeWaitTimer = nil
        statusText = "程序坞已隐藏，正在等待屏幕可用区域更新…"

        let delays: [TimeInterval] = [0.15, 0.20, 0.35]
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delays[min(frameCheckAttempt, delays.count - 1)],
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            self.windowMaximizeWaitTimer?.cancel()
            self.windowMaximizeWaitTimer = nil
            guard let displays = ScreenDetector.onlineDisplayIDs() else {
                self.windowMaximizationInProgress = false
                self.pendingWindowMaximization = true
                self.detectionFailed(reason: reason, attempt: attempt, states: ["显示器"])
                return
            }
            guard displays.allSatisfy({ CGDisplayIsBuiltin($0) != 0 }) else {
                self.windowMaximizationInProgress = false
                self.pendingWindowMaximization = false
                self.scheduleRefresh(reason: "external_display_reconnected_before_window_maximize")
                return
            }
            guard let screen = ScreenDetector.builtInScreen() else {
                self.windowMaximizationInProgress = false
                self.pendingWindowMaximization = true
                self.detectionFailed(reason: reason, attempt: attempt, states: ["内建屏幕"])
                return
            }

            let previousArea = visibleFrameBeforeAutohide.map { $0.width * $0.height }
            let currentArea = screen.visibleFrame.width * screen.visibleFrame.height
            let visibleFrameExpanded = previousArea == nil || currentArea > previousArea! + 1
            if !visibleFrameExpanded, frameCheckAttempt + 1 < delays.count {
                self.scheduleWindowMaximization(
                    target: target,
                    visibleFrameBeforeAutohide: visibleFrameBeforeAutohide,
                    failedDetectionStates: failedDetectionStates,
                    reason: reason,
                    attempt: attempt,
                    requestedGeneration: requestedGeneration,
                    frameCheckAttempt: frameCheckAttempt + 1
                )
                return
            }
            guard visibleFrameExpanded else {
                self.windowMaximizationInProgress = false
                self.pendingWindowMaximization = true
                self.canRetry = true
                self.statusText = "程序坞已隐藏，但屏幕可用区域尚未更新；请重试窗口铺满"
                return
            }

            self.pendingWindowMaximization = false
            self.statusText = "程序坞已隐藏，正在铺满当前 Space 的窗口…"
            self.windowController.maximizeVisibleWindowsOnCurrentSpace(on: screen) { [weak self] result in
                guard let self, self.generation == requestedGeneration else { return }
                self.handleWindowMaximizationResult(
                    result,
                    target: target,
                    failedDetectionStates: failedDetectionStates,
                    reason: reason,
                    attempt: attempt
                )
            }
        }
        windowMaximizeWaitTimer = timer
        timer.resume()
    }

    /// 汇总批量铺满结果并更新权限、重试和状态文案；排除名单应用只计数，从未收到窗口写入。
    private func handleWindowMaximizationResult(
        _ result: WindowMaximizationResult,
        target: DockTargetState,
        failedDetectionStates: [String],
        reason: String,
        attempt: Int
    ) {
        windowMaximizationInProgress = false
        recordWindowMaximization(result)
        if result.accessibilityPermissionMissing {
            pendingWindowMaximization = true
            needsAccessibilityPermission = true
            canRetry = true
            statusText = "程序坞已隐藏；请允许辅助功能权限后重试窗口铺满"
            return
        }
        needsAccessibilityPermission = false
        if result.cancelled {
            pendingWindowMaximization = true
            canRetry = true
            statusText = "程序坞已隐藏；窗口铺满已被新的窗口或显示器操作取消"
            return
        }
        if !failedDetectionStates.isEmpty {
            pendingWindowMaximization = result.failedCount > 0
            detectionFailed(reason: reason, attempt: attempt, states: failedDetectionStates)
            return
        }

        showSuccess(target: target)
        var details: [String] = []
        if result.adjustedCount > 0 {
            details.append("已铺满 \(result.adjustedCount) 个窗口")
        } else {
            details.append("没有需要铺满的窗口")
        }
        if result.excludedApplicationCount > 0 {
            details.append("已跳过 \(result.excludedApplicationCount) 个排除应用")
        }
        if result.failedCount > 0 {
            details.append("\(result.failedCount) 个窗口未完成")
        }
        statusText += " · " + details.joined(separator: " · ")
        pendingWindowMaximization = result.failedCount > 0
        canRetry = pendingWindowMaximization
    }

    /// 只在当前偏好已匹配或系统脚本回读成功后，组合展示本次确实验证过的状态。
    private func showSuccess(target: DockTargetState) {
        var components: [String] = []
        if let lidClosed = target.lidClosed {
            components.append(lidClosed ? "笔记本已合盖" : "笔记本已开盖")
        }
        if let count = target.externalDisplayCount {
            components.append(count == 0 ? "未检测到外接显示器" : "已连接 \(count) 台外接显示器")
        }
        if let position = target.position {
            components.append("程序坞在\(position == "left" ? "左侧" : "底部")")
        }
        if let autohide = target.autohide {
            components.append("自动隐藏已\(autohide ? "开启" : "关闭")")
        }
        let text = components.joined(separator: " · ")
        guard !text.isEmpty else { return }
        // 重复系统通知不发布相同状态，避免设置视图做无意义的刷新。
        if statusText != text { statusText = text }
        if needsAutomationPermission { needsAutomationPermission = false }
        if needsAccessibilityPermission { needsAccessibilityPermission = false }
        if canRetry { canRetry = false }
    }

    /// 将可选诊断值转换为 JSON 支持的值；未知状态必须显式记录为 null，不能伪装成 false 或空字符串。
    private func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    /// 将一次程序坞脚本请求及完整执行结果编码为单行 JSON，便于排查权限、超时与回读错误。
    private func recordScript(request: [String: Any], response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["request": request, "response": response], options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        logger.info("dock_automation_script \(json, privacy: .public)")
    }

    /// 将批量铺满汇总忠实编码为单行 JSON，记录成功、失败、跳过、权限和取消状态。
    private func recordWindowMaximization(_ result: WindowMaximizationResult) {
        let payload: [String: Any] = [
            "adjusted_count": result.adjustedCount,
            "failed_count": result.failedCount,
            "skipped_window_count": result.skippedWindowCount,
            "excluded_application_count": result.excludedApplicationCount,
            "accessibility_permission_missing": result.accessibilityPermissionMissing,
            "cancelled": result.cancelled
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return }
        logger.info("window_auto_maximize \(json, privacy: .public)")
    }
}
