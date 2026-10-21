#!/bin/bash
set -euo pipefail

# 固定本机已有证书的指纹，避免同名证书被替换后悄悄改变应用身份。
# 对应钥匙串名称：InputHoldSwitcher Local Code Signing。证书缺失时停止，不生成新证书或降级为 ad-hoc。
SIGNING_IDENTITY="659A2CD838DF7ADCB88F313BDE6572A223C4923C"
# 保持 Bundle ID 与辅助功能授权、用户配置及开机启动登记使用的身份一致。
BUNDLE_ID="com.local.WindowEdgeHotkeys"
# 从脚本位置定位源码，允许从任意工作目录调用。
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# dist 仅保存交付的签名应用；中间构建文件全部放到仓库外并在退出时清理。
APP_TARGET="$PROJECT_DIR/dist/WindowEdgeHotkeys.app"

if ! /usr/bin/security find-identity -p codesigning -v | /usr/bin/grep -Fq "$SIGNING_IDENTITY"; then
    echo "缺少固定签名证书 InputHoldSwitcher Local Code Signing ($SIGNING_IDENTITY)。" >&2
    echo "请恢复原证书及私钥；为保持授权身份，本脚本不会生成新证书或使用临时签名。" >&2
    exit 1
fi

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_DIR/Info.plist")" != "$BUNDLE_ID" ]]; then
    echo "Info.plist 的 Bundle ID 已改变，停止构建以避免改变应用授权身份。" >&2
    exit 1
fi

# 只有完整编译、签名和验证成功后才更新交付包。
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/windowedge-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
APP_DIR="$WORK_DIR/WindowEdgeHotkeys.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

cd "$PROJECT_DIR"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon -framework IOKit \
    -import-objc-header LidStateMonitorBridge.h \
    WindowEdgeHotkeysApp.swift AppDelegate.swift HotKeyManager.swift AccessibilityPermission.swift \
    ScreenDetector.swift LidStateMonitor.swift DockPositionController.swift WindowEdgeController.swift SettingsView.swift HotKeyPreferences.swift LoginItemManager.swift \
    -o "$APP_DIR/Contents/MacOS/WindowEdgeHotkeys"

/usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"
# 校验代码完整性、Bundle ID 和证书锚点；源码变化可改变代码哈希，但不能改变这个身份要求。
/usr/bin/codesign --verify --deep --strict \
    -R "=identifier \"$BUNDLE_ID\" and certificate root = H\"$SIGNING_IDENTITY\"" "$APP_DIR"

mkdir -p "$(dirname "$APP_TARGET")"
rm -rf "$APP_TARGET"
/usr/bin/ditto "$APP_DIR" "$APP_TARGET"
/usr/bin/codesign --verify --deep --strict "$APP_TARGET"
/usr/bin/codesign -d -r- "$APP_TARGET"
echo "已构建并验证：$APP_TARGET"
echo "日常运行请使用固定路径 /Applications/WindowEdgeHotkeys.app。"
