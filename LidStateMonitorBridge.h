#ifndef WINDOW_EDGE_LID_STATE_MONITOR_BRIDGE_H
#define WINDOW_EDGE_LID_STATE_MONITOR_BRIDGE_H

#include <IOKit/pwr_mgt/IOPM.h>

// IOPM.h 的嵌套宏无法直接导入 Swift；通过类型明确的常量引用 SDK 定义，避免硬编码消息编号。
static const uint32_t WindowEdgeClamshellStateChangeMessage = kIOPMMessageClamshellStateChange;

#endif
