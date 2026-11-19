import AppKit
import ApplicationServices
import DevTabsCore

/// `RTLD_DEFAULT` en macOS: busca el símbolo en todas las bibliotecas ya cargadas.
let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

/// `_AXUIElementGetWindow` no es pública, pero es la única forma de pasar de un elemento de Accesibilidad a su `CGWindowID`.
private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let getWindowFn: GetWindowFn? = dlsym(rtldDefault, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let id: WindowID
}

enum AX {
    static func windowID(_ element: AXUIElement) -> WindowID? {
        guard let getWindowFn else { return nil }
        var id: CGWindowID = 0
        return getWindowFn(element, &id) == .success && id != 0 ? id : nil
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    /// Ventana normal, visible y fuera de pantalla completa: las únicas que se acomodan.
    static func isManageable(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == kAXWindowRole
            && string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && !bool(element, kAXMinimizedAttribute)
            && !bool(element, "AXFullScreen")
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    /// Tamaño, posición y otra vez tamaño: algunas apps recortan el tamaño si la ventana todavía está en el monitor anterior.
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        var size = frame.size
        var origin = frame.origin
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var origin = point
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) {
        _ = AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    static func perform(_ element: AXUIElement, _ action: String) {
        _ = AXUIElementPerformAction(element, action as CFString)
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
