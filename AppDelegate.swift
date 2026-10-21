import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotKeyManager = HotKeyManager()
    /// 与程序坞自动策略共享窗口控制器，用户快捷键可取消尚未完成的自动批量铺满。
    private let controller = WindowEdgeController.shared
    /// 与设置页共享程序坞控制器；位置和自动隐藏策略的生命周期不依赖设置窗口是否打开。
    private let dockPositionController = DockPositionController.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItemIcon()
        statusItem?.menu = makeMenu()

        hotKeyManager.onHotKey = { [weak self] action in
            guard let self else { return }
            self.handle(action: action)
        }

        hotKeyManager.registerDefaultHotKeys()
        dockPositionController.start()
    }

    /// 退出时移除显示器监听并取消尚未执行的程序坞调整，保留系统当前设置。
    func applicationWillTerminate(_ notification: Notification) {
        dockPositionController.stop()
    }

    private func configureStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled",
                               accessibilityDescription: "WindowEdgeHotkeys")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            // 兜底：老系统取不到 SF Symbol 时，用放大的字形代替。
            button.title = "⇖"
            button.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let requestPermission = NSMenuItem(
            title: "请求辅助功能权限",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        requestPermission.target = self
        menu.addItem(requestPermission)

        let openPrivacy = NSMenuItem(
            title: "打开系统设置 → 辅助功能",
            action: #selector(openAccessibilityPrivacy),
            keyEquivalent: ""
        )
        openPrivacy.target = self
        menu.addItem(openPrivacy)

        let openSettings = NSMenuItem(
            title: "设置",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        openSettings.target = self
        menu.addItem(openSettings)

        let loginItem = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.state = LoginItemManager.shared.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let smartLayout = NSMenuItem(
            title: "智能布局（按鼠标所在屏）",
            action: #selector(applySmartLayout),
            keyEquivalent: ""
        )
        smartLayout.target = self
        menu.addItem(smartLayout)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func handle(action: HotKeyAction) {
        switch action {
        case .smartLayout:
            performSmartLayout()
        }
    }

    private func performSmartLayout() {
        let prefs = HotKeyPreferences.shared
        controller.applySmartLayout(
            designatedName: prefs.designatedDisplayName,
            marginDirection: prefs.marginDirection,
            marginPercent: prefs.marginPercent
        )
    }

    @objc private func requestAccessibilityPermission() {
        _ = AccessibilityPermission.requestIfNeeded(prompt: true)
    }

    @objc private func openAccessibilityPrivacy() {
        AccessibilityPermission.openPrivacyPane()
    }

    @objc private func openSettings() {
        presentSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let manager = LoginItemManager.shared
        manager.setEnabled(!manager.isEnabled)
        sender.state = manager.isEnabled ? .on : .off
    }

    private func presentSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置"
        window.setContentSize(NSSize(width: 520, height: 640))
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func applySmartLayout() {
        performSmartLayout()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
