import Carbon.HIToolbox

/// ⌃⌥1 … ⌃⌥9, delivered even while Teams, Meet or FaceTime is in front. Uses Carbon hot keys, which
/// need no Accessibility permission.
final class GlobalHotKeys {
    /// Called on the main thread with 0 for ⌃⌥1, 1 for ⌃⌥2, …
    var onPress: ((Int) -> Void)?

    private var hotKeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue().onPress?(Int(id.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x475A_4452), id: UInt32(index))  // 'GZDR'
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    deinit {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
