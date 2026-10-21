import Foundation
import IOKit
import IOKit.pwr_mgt

/// 通过 IOKit 读取笔记本物理盖子状态，并订阅系统合盖消息；不启动 ioreg 子进程或定时轮询。
/// 通知端口使用主队列，调用方也在主线程启动、读取和停止，避免通知与资源释放并发。
final class LidStateMonitor {
    /// 只在盖子的开合状态变化时调用；电源管理策略变化但盖子未动时不触发。
    var onChange: (() -> Void)?
    /// 持有电源根节点供原生属性读取复用，关闭功能时释放对应的 IOKit 引用。
    private var rootDomain: io_service_t = 0
    /// 接收系统推送的通知端口，没有周期性定时器或专用常驻线程。
    private var notificationPort: IONotificationPortRef?
    /// 成功注册后的兴趣通知句柄，停止监听时成对释放。
    private var interest: io_object_t = 0
    /// 用于过滤仅 AppleClamshellCausesSleep 改变的消息；实际决策仍读取最新原生属性。
    private var lastNotifiedState: Bool?

    /// IOPM.h 规定消息参数的 bit 0 表示合盖；开盖的零值参数可能表现为 nil，不能忽略。
    /// 该回调已由通知端口投递到主队列，不再额外派发任务或读取整个 IORegistry。
    private let callback: IOServiceInterestCallback = { context, _, messageType, argument in
        guard messageType == WindowEdgeClamshellStateChangeMessage, let context else { return }
        let monitor = Unmanaged<LidStateMonitor>.fromOpaque(context).takeUnretainedValue()
        let closed = UInt(bitPattern: argument) & UInt(kClamshellStateBit) != 0
        guard monitor.lastNotifiedState != closed else { return }
        monitor.lastNotifiedState = closed
        monitor.onChange?()
    }

    /// 注册一次系统通知；失败时保留可用的电源节点，屏幕或唤醒事件仍可触发状态读取。
    /// 返回 false 表示推送注册失败，调用方应记录故障，而不是增加后台轮询。
    @discardableResult
    func start() -> Bool {
        guard rootDomain == 0 else { return interest != 0 }
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        lastNotifiedState = isClosed()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, callback,
                                                     Unmanaged.passUnretained(self).toOpaque(), &interest)
        if result != KERN_SUCCESS {
            if interest != 0 { IOObjectRelease(interest); interest = 0 }
            IONotificationPortDestroy(port)
            notificationPort = nil
            return false
        }
        return true
    }

    /// 直接读取 AppleClamshellState 的布尔值：true 为合盖，false 为开盖。
    /// 属性缺失或读取失败返回 nil，不能把未知状态推断为开盖、合盖或内置屏幕被关闭。
    func isClosed() -> Bool? {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(rootDomain, kAppleClamshellStateKey as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    /// 撤销系统推送并释放全部 IOKit 句柄；重复停止安全，重新启用时可重新注册。
    func stop() {
        if interest != 0 { IOObjectRelease(interest); interest = 0 }
        if let port = notificationPort { IONotificationPortDestroy(port); notificationPort = nil }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
        lastNotifiedState = nil
        onChange = nil
    }

    /// 防止未来调整控制器生命周期时遗漏通知端口或电源节点释放。
    deinit {
        stop()
    }
}
