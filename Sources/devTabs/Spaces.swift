import AppKit

/// El Space visible de un monitor. `frame` y `area` usan las coordenadas de Accesibilidad: origen arriba a la izquierda del monitor principal.
struct DisplaySpace {
    let uuid: String
    let spaceID: Int
    let isFullscreen: Bool
    let frame: CGRect
    let area: CGRect

    var key: String { "\(uuid)#\(spaceID)" }
}

private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

/// Funciones privadas del servidor de ventanas: la API pública no dice qué Space muestra cada monitor.
private let mainConnection: MainConnectionFn? = dlsym(rtldDefault, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionFn.self) }
private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = dlsym(rtldDefault, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) }

enum Spaces {
    static func current() -> [DisplaySpace] {
        var byDisplay: [String: (id: Int, fullscreen: Bool)] = [:]
        if let mainConnection, let copyManagedDisplaySpaces,
           let list = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] {
            for display in list {
                guard let ident = display["Display Identifier"] as? String,
                      let space = display["Current Space"] as? [String: Any] else { continue }
                let id = (space["ManagedSpaceID"] as? Int) ?? (space["id64"] as? Int) ?? 0
                byDisplay[ident.uppercased()] = (id, (space["type"] as? Int) == 4)
            }
        }
        return NSScreen.screens.map { screen in
            let uuid = uuidString(screen) ?? "MAIN"
            let entry = byDisplay[uuid.uppercased()] ?? byDisplay["MAIN"] ?? (0, false)
            return DisplaySpace(uuid: uuid, spaceID: entry.id, isFullscreen: entry.fullscreen,
                                frame: flip(screen.frame), area: flip(screen.visibleFrame))
        }
    }

    /// Pasa de las coordenadas de AppKit (origen abajo a la izquierda) a las de Accesibilidad, y viceversa: la cuenta es la misma.
    static func flip(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func uuidString(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
