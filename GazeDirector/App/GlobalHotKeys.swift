import Carbon.HIToolbox

/// ⌃⌥1 … ⌃⌥9 for gifts 1–9 and ⌃⌥⇧1 … ⌃⌥⇧9 for gifts 10–18, delivered even while Teams, Meet or
/// FaceTime is in front. Uses Carbon hot keys, which need no Accessibility permission.
final class GlobalHotKeys {
    /// Called with the gift index: 0 for ⌃⌥1, …, 8 for ⌃⌥9, 9 for ⌃⌥⇧1, …
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
        for (bank, modifiers) in [controlKey | optionKey, controlKey | optionKey | shiftKey].enumerated() {
            for (index, key) in keys.enumerated() {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x475A_4452), id: UInt32(bank * keys.count + index))  // 'GZDR'
                RegisterEventHotKey(UInt32(key), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
                hotKeys.append(ref)
            }
        }
    }

    deinit {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
