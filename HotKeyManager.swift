import Carbon
import Foundation

enum HotKeyAction: Hashable {
    case smartLayout
}

final class HotKeyManager {
    var onHotKey: ((HotKeyAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionByHotKeyID: [UInt32: HotKeyAction] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    init() {
        Self.shared = self
        installHandlerIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: .hotKeyPreferencesDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
    }

    func registerDefaultHotKeys() {
        reloadHotKeys()
    }

    private func register(action: HotKeyAction, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(Self.signature), id: nextHotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return }
        actionByHotKeyID[nextHotKeyID] = action
        nextHotKeyID += 1
        hotKeyRefs.append(hotKeyRef)
    }

    @objc private func preferencesChanged() {
        reloadHotKeys()
    }

    private func reloadHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionByHotKeyID.removeAll()
        nextHotKeyID = 1
        for action in HotKeyAction.allCases {
            let setting = HotKeyPreferences.shared.setting(for: action)
            register(action: action, keyCode: setting.keyCode, modifiers: setting.modifiers)
        }
    }

    private func handleHotKeyPressed(id: UInt32) {
        guard let action = actionByHotKeyID[id] else { return }
        onHotKey?(action)
    }

    private func installHandlerIfNeeded() {
        if eventHandlerRef != nil { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            eventHandlerRef = nil
        }
    }

    private static let signature: UInt32 = 0x5745484B
    private static weak var shared: HotKeyManager?

    private static let hotKeyHandler: EventHandlerUPP = { _, event, _ in
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        var actualSize: Int = 0
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &hotKeyID
        )
        guard status == noErr else { return noErr }
        guard hotKeyID.signature == OSType(signature) else { return noErr }
        shared?.handleHotKeyPressed(id: hotKeyID.id)
        return noErr
    }
}
