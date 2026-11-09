#ifndef WINDOW_EDGE_LID_STATE_MONITOR_BRIDGE_H
#define WINDOW_EDGE_LID_STATE_MONITOR_BRIDGE_H

#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/pwr_mgt/IOPM.h>

// IOPM.h 的嵌套宏无法直接导入 Swift；通过类型明确的常量引用 SDK 定义，避免硬编码消息编号。
static const uint32_t WindowEdgeClamshellStateChangeMessage = kIOPMMessageClamshellStateChange;

// 进程级 CGEventTap 要求 ProcessSerialNumber，但 GetProcessForPID 在 Swift 中不可直接调用。
// 通过 C 桥接调用系统仍提供的公开接口：仅在注册 Dock 监听时将 PID 转为 PSN，
// 原样返回 OSStatus 供 Swift 判断失败；不在鼠标回调中查询，也不增加轮询或后台线程。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline OSStatus WindowEdgeGetProcessForPID(pid_t pid, ProcessSerialNumber *psn) {
    return GetProcessForPID(pid, psn);
}
#pragma clang diagnostic pop

#endif
