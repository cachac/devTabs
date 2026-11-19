import Carbon
import DevTabsCore

/// Atajos globales con Carbon: no piden el permiso de Monitoreo de entrada.
final class Hotkeys {
    static let shared = Hotkeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6454_6273), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        } else {
            Log.write("no pude registrar el atajo \(keyCode) con modificadores \(modifiers): \(status)")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Hotkeys.shared.fire(hotKeyID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum Keys {
    /// Control + Comando en todos los atajos: ⌘ solo lo usan todas las apps (guardar, inicio de línea) y macOS sólo toma
    /// ⌃⌘F, ⌃⌘Q, ⌃⌘D y ⌃⌘Espacio, que devTabs no usa.
    static let base = controlKey | cmdKey

    /// Los atajos con caracteres se registran por lo que escribe la tecla en la distribución activa, no por su posición en un
    /// teclado estadounidense: en el latinoamericano la tecla del `=` de ese teclado escribe `¿`.
    static func register(_ wm: WindowManager) {
        let hotkeys = Hotkeys.shared
        func bind(_ character: String, _ action: @escaping () -> Void) {
            guard let key = key(for: character) else {
                Log.write("no encontré la tecla de «\(character)» en el teclado actual")
                return
            }
            hotkeys.register(keyCode: key.code, modifiers: base | (key.shift ? shiftKey : 0), action)
        }
        let arrows: [(Int, Direction)] = [(kVK_LeftArrow, .left), (kVK_DownArrow, .down), (kVK_UpArrow, .up), (kVK_RightArrow, .right)]
        for (code, direction) in arrows {
            hotkeys.register(keyCode: code, modifiers: base) { wm.focus(direction) }
            hotkeys.register(keyCode: code, modifiers: base | shiftKey) { wm.move(direction) }
        }
        bind("s") { wm.toggleStack() }
        bind("a") { wm.toggleAccordion() }
        bind("o") { wm.toggleOrientation() }
        bind("g") { wm.toggleFloat() }
        bind("z") { wm.toggleZoom() }
        bind("y") { wm.toggleTiling() }
        bind("+") { wm.resize(by: 0.05) }
        bind("-") { wm.resize(by: -0.05) }
    }

    /// Las teclas del teclado numérico no cuentan: `+` y `-` tienen que ser los de la parte principal.
    private static let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// La tecla que escribe ese carácter en la distribución activa: primero sin shift y, si no hay, con shift.
    static func key(for character: String) -> (code: Int, shift: Bool)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> (code: Int, shift: Bool)? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for shift in [false, true] {
                for code in 0..<128 where !keypad.contains(code) {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) : 0,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &deadKeys, chars.count, &length, &chars)
                    if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == character {
                        return (code, shift)
                    }
                }
            }
            return nil
        }
    }
}
