import AppKit
import ApplicationServices
import DevTabsCore

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    WindowManager.shared?.handle(notification as String, element: element)
}

/// Un árbol por Space de cada monitor. Sólo toca las ventanas del Space visible y nunca las saca de la pantalla.
final class WindowManager {
    static var shared: WindowManager?

    /// La separación entre ventanas y la franja del accordion se guardan en las preferencias de la app (`dev.devtabs`).
    private(set) var config: Config = {
        let defaults = UserDefaults.standard
        var config = Config(gap: 8, barHeight: 28, accordionPadding: 30)
        if defaults.object(forKey: "gap") != nil { config.gap = CGFloat(defaults.double(forKey: "gap")) }
        if defaults.object(forKey: "accordionPadding") != nil { config.accordionPadding = CGFloat(defaults.double(forKey: "accordionPadding")) }
        return config
    }()

    func setGap(_ value: CGFloat) {
        config.gap = value
        UserDefaults.standard.set(Double(value), forKey: "gap")
        apply()
    }

    private var trees: [String: LayoutTree] = [:]
    private var windowSpace: [WindowID: String] = [:]
    private var known: [WindowID: AXWindow] = [:]
    private var floating: Set<WindowID> = []
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: Set<WindowID> = []
    private var bars: [ObjectIdentifier: TabBarPanel] = [:]
    private var displays: [DisplaySpace] = []
    private var lastFocused: WindowID?
    private var refreshPending = false
    private var barsPending = false
    private var timer: Timer?
    /// Cuándo devTabs movió cada ventana por última vez: sus propios movimientos también llegan como avisos y no son del usuario.
    private var placedAt: [WindowID: Date] = [:]
    /// La ventana que el usuario está moviendo o redimensionando; mientras tanto no se acomoda ninguna.
    private var dragging: WindowID?
    /// Lo último que se guardó en disco, para no escribir si nada cambió.
    private var lastSaved: Data?

    /// Una ventana que no está en pantalla pero sigue viva: minimizada, o de una app oculta con ⌘H.
    private static func isDormant(_ window: AXWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return false }
        return app.isHidden || AX.bool(window.element, kAXMinimizedAttribute)
    }

    // MARK: - Guardar y recuperar

    /// Los árboles con sus stacks y acordeones, y las ventanas flotantes. Los identificadores de ventana duran lo que dura la
    /// ventana, así que al reabrir devTabs se recupera todo lo que siga abierto; lo que se cerró se descarta.
    private struct SavedState: Codable {
        var trees: [String: TreeSnapshot]
        var floating: [WindowID]
    }

    private static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/devTabs/layout.json")

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        let existing = Self.existingWindowIDs()
        for (key, snapshot) in state.trees {
            let tree = LayoutTree(snapshot: snapshot)
            tree.prune(keeping: existing)
            guard !tree.windows.isEmpty else { continue }
            trees[key] = tree
            for window in tree.windows { windowSpace[window] = key }
        }
        floating = Set(state.floating).intersection(existing)
        lastSaved = data
        Log.write("recuperados \(trees.count) workspaces con \(windowSpace.count) ventanas")
    }

    private func save() {
        let state = SavedState(trees: trees.filter { !$0.value.windows.isEmpty }.mapValues(\.snapshot), floating: floating.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state), data != lastSaved else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: Self.stateURL, options: .atomic)) != nil { lastSaved = data }
    }

    /// Todas las ventanas que existen, en cualquier Space: las que no están acá se cerraron.
    private static func existingWindowIDs() -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    // MARK: - Arranque

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let refreshing: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in refreshing {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() }
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observers[app.processIdentifier] = nil
            }
            self?.scheduleRefresh()
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleFocus()
            self?.scheduleRefresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        restore()
        refresh()
        Log.write("devTabs iniciado con \(known.count) ventanas en \(displays.count) monitores")
    }

    func stop() {
        timer?.invalidate()
        save()
        bars.values.forEach { $0.orderOut(nil) }
        bars.removeAll()
    }

    // MARK: - Eventos

    func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            handleFocus()
            scheduleRefresh()
        case kAXTitleChangedNotification:
            scheduleBars()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            userMoved(element)
        default:
            scheduleRefresh()
        }
    }

    /// Un movimiento que no hizo devTabs es del usuario: se espera a que suelte el mouse antes de acomodar nada.
    private func userMoved(_ element: AXUIElement) {
        guard let window = AX.windowID(element) else { return }
        if let placed = placedAt[window], Date().timeIntervalSince(placed) < 0.5 { return }
        let first = dragging == nil
        dragging = window
        if first { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.finishDrag() } }
    }

    /// Al soltar: el borde de la ventana activa de un accordion fija cuánto asoman las de atrás (y queda como franja por
    /// omisión); el borde compartido con otra ventana corre la división. Si sólo se movió, vuelve a su lugar.
    private func finishDrag() {
        guard let window = dragging else { return }
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.finishDrag() }
            return
        }
        dragging = nil
        if let key = windowSpace[window], let tree = trees[key], let display = displays.first(where: { $0.key == key }),
           let ax = known[window], let frame = AX.frame(ax.element) {
            if let peek = tree.adjustPeek(window, toFit: frame, area: display.area, config: config) {
                config.accordionPadding = peek
                UserDefaults.standard.set(Double(peek), forKey: "accordionPadding")
            }
            tree.resizeTile(window, to: frame, area: display.area, config: config)
        }
        refresh()
    }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func scheduleBars() {
        guard !barsPending else { return }
        barsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.barsPending = false
            self?.apply(frames: false)
        }
    }

    /// Si el foco cae en una pestaña de atrás (⌘Tab, clic), esa pasa a ser la activa de su stack.
    private func handleFocus() {
        guard let window = focusedWindowID(), let key = windowSpace[window], let tree = trees[key] else { return }
        lastFocused = window
        if tree.activate(window) {
            apply()
            restack(window)
            if let ax = known[window] { AX.perform(ax.element, kAXRaiseAction) }
        }
    }

    // MARK: - Lectura de ventanas

    func refresh() {
        displays = Spaces.current()
        let onScreen = Self.onScreenWindowIDs()
        var seen: [WindowID: AXWindow] = [:]
        var alive: [WindowID: AXWindow] = [:]   // también las minimizadas y las de apps ocultas
        var visible: [String: [WindowID]] = [:]
        let me = getpid()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.3)
            observe(pid: pid, app: appElement)
            for element in AX.windows(of: appElement) {
                guard let id = AX.windowID(element) else { continue }
                let window = AXWindow(element: element, pid: pid, id: id)
                alive[id] = window
                guard !app.isHidden, onScreen.contains(id), AX.isManageable(element),
                      let frame = AX.frame(element), let display = display(containing: frame), !display.isFullscreen else { continue }
                seen[id] = window
                observe(window)
                visible[display.key, default: []].append(id)
            }
        }
        known = seen
        observedWindows.formIntersection(seen.keys)
        placedAt = placedAt.filter { seen[$0.key] != nil }

        let focused = focusedWindowID()
        for display in displays where !display.isFullscreen {
            let tree = trees[display.key] ?? newTree(display.key)
            let here = visible[display.key] ?? []
            let hereSet = Set(here)
            for window in tree.windows where !hereSet.contains(window) {
                if let ax = alive[window], Self.isDormant(ax) {
                    tree.setHidden(window, true)   // minimizada o de una app oculta: conserva su lugar
                } else {
                    tree.remove(window)
                    floating.remove(window)
                    if windowSpace[window] == display.key { windowSpace[window] = nil }
                }
            }
            for window in here where tree.hidden.contains(window) && !floating.contains(window) {
                tree.setHidden(window, false)
            }
            for window in here where !floating.contains(window) && !tree.contains(window) {
                if let old = windowSpace[window], old != display.key {
                    trees[old]?.remove(window)
                }
                guard let ax = seen[window], AX.isSettable(ax.element, kAXSizeAttribute) else {
                    floating.insert(window)   // una ventana que no deja cambiar su tamaño queda flotando
                    continue
                }
                let anchor = [focused, lastFocused].compactMap { $0 }.first { tree.contains($0) }
                tree.insert(window, focused: anchor, area: display.area, config: config)
                windowSpace[window] = display.key
            }
        }
        apply()
    }

    // MARK: - Aplicar el layout

    func apply(frames: Bool = true) {
        let moveWindows = frames && dragging == nil
        var live = Set<ObjectIdentifier>()
        for display in displays where !display.isFullscreen {
            guard let tree = trees[display.key], tree.enabled else { continue }
            for layout in tree.layout(in: display.area, config: config) {
                if moveWindows {
                    for item in layout.frames {
                        if let ax = known[item.window] { setFrameIfNeeded(ax, item.frame) }
                    }
                }
                guard let barRect = layout.barRect else { continue }
                let id = ObjectIdentifier(layout.tile)
                live.insert(id)
                let panel = bars[id] ?? makeBar(id)
                panel.bar.tabs = layout.frames.map { item in
                    TabItem(id: item.window, title: title(of: item.window), pid: known[item.window]?.pid ?? 0,
                            active: item.window == layout.activeWindow)
                }
                let frame = Spaces.flip(barRect)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                if !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
        for (id, panel) in bars where !live.contains(id) {
            panel.orderOut(nil)
            bars[id] = nil
        }
        save()
    }

    private func setFrameIfNeeded(_ window: AXWindow, _ frame: CGRect) {
        if let current = AX.frame(window.element),
           abs(current.minX - frame.minX) < 2, abs(current.minY - frame.minY) < 2,
           abs(current.width - frame.width) < 2, abs(current.height - frame.height) < 2 { return }
        placedAt[window.id] = Date()
        AX.setFrame(window.element, frame)
    }

    private func makeBar(_ id: ObjectIdentifier) -> TabBarPanel {
        let panel = TabBarPanel()
        panel.bar.onClick = { [weak self] window in self?.selectTab(window) }
        bars[id] = panel
        return panel
    }

    private func title(of window: WindowID) -> String {
        guard let ax = known[window] else { return "" }
        if let title = AX.string(ax.element, kAXTitleAttribute), !title.isEmpty { return title }
        return NSRunningApplication(processIdentifier: ax.pid)?.localizedName ?? ""
    }

    // MARK: - Comandos

    /// En un stack, ← y → pasan de pestaña; desde la primera o la última, el foco sigue a la ventana vecina.
    func focus(_ direction: Direction) {
        guard let context = focusedContext() else { return }
        // Desde una ventana flotante, el foco va a la ventana acomodada más cercana de ese lado.
        if floating.contains(context.window), let frame = known[context.window].flatMap({ AX.frame($0.element) }) {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let ahead = context.tree.layout(in: context.display.area, config: config).filter { layout in
                switch direction {
                case .left: return layout.rect.midX < center.x
                case .right: return layout.rect.midX > center.x
                case .up: return layout.rect.midY < center.y
                case .down: return layout.rect.midY > center.y
                }
            }
            func distance(_ layout: TileLayout) -> CGFloat { hypot(layout.rect.midX - center.x, layout.rect.midY - center.y) }
            if let target = ahead.min(by: { distance($0) < distance($1) })?.activeWindow { focusWindow(target) }
            return
        }
        if direction == .left || direction == .right,
           let next = context.tree.step(context.window, forward: direction == .right) {
            apply()
            restack(next)
            focusWindow(next)
            return
        }
        if let tile = context.tree.tile(containing: context.window),
           let other = context.tree.neighbor(of: tile, direction, area: context.display.area, config: config),
           let target = other.activeWindow {
            focusWindow(target)
        } else if let display = display(beside: context.display, direction),
                  let target = trees[display.key]?.tiles.first?.activeWindow {
            focusWindow(target)
        }
    }

    func move(_ direction: Direction) {
        guard let context = focusedContext(), !floating.contains(context.window) else { return }
        let result = context.tree.move(context.window, direction, area: context.display.area, config: config)
        if result == .none, let display = display(beside: context.display, direction) {
            context.tree.remove(context.window)
            let tree = trees[display.key] ?? newTree(display.key)
            tree.insert(context.window, focused: tree.tiles.last?.activeWindow, area: display.area, config: config)
            windowSpace[context.window] = display.key
        }
        apply()
        focusWindow(context.window)
    }

    /// Junta en un stack todas las ventanas del monitor y Space de la ventana enfocada; si ya están juntas, las separa.
    func toggleStack() {
        guard let context = focusedContext() else { return }
        context.tree.toggleStackAll(context.window, area: context.display.area, config: config)
        apply()
        focusWindow(context.window)
    }

    func selectTab(_ window: WindowID) {
        guard let key = windowSpace[window], let tree = trees[key] else { return }
        tree.activate(window)
        apply()
        restack(window)
        focusWindow(window)
    }

    /// En un acordeón de tres o más pestañas, las de atrás se apilan de la más lejana a la más cercana a la activa, para que
    /// cada franja muestre su propia ventana. La activa se sube después, al enfocarla.
    private func restack(_ window: WindowID) {
        guard let key = windowSpace[window], let tree = trees[key], let display = displays.first(where: { $0.key == key }),
              let layout = tree.layout(in: display.area, config: config).first(where: { $0.frames.contains { $0.window == window } }),
              layout.tile.mode == .accordion, layout.frames.count > 2,
              let active = layout.frames.firstIndex(where: { $0.window == layout.activeWindow }) else { return }
        let behind = layout.frames.indices.filter { $0 != active }.sorted { abs($0 - active) > abs($1 - active) }
        for index in behind {
            if let ax = known[layout.frames[index].window] { AX.perform(ax.element, kAXRaiseAction) }
        }
    }

    func toggleAccordion() {
        guard let context = focusedContext() else { return }
        context.tree.toggleAccordion(context.window)
        apply()
    }

    func toggleOrientation() {
        guard let context = focusedContext() else { return }
        context.tree.toggleOrientation(context.window)
        apply()
    }

    func resize(by delta: CGFloat) {
        guard let context = focusedContext() else { return }
        context.tree.adjustRatio(context.window, by: delta)
        apply()
    }

    /// Flotar: la ventana sale del layout, queda centrada al 60 % × 70 % del monitor y adelante, y su lugar se guarda.
    /// Volver: ocupa otra vez exactamente ese lugar.
    func toggleFloat() {
        guard let window = focusedWindowID(), let ax = known[window] else { return }
        if floating.remove(window) != nil {
            refresh()
            focusWindow(window)
            return
        }
        guard let key = windowSpace[window], let tree = trees[key], let display = displays.first(where: { $0.key == key }) else { return }
        tree.setHidden(window, true)
        floating.insert(window)
        apply()
        let a = display.area
        placedAt[window] = Date()
        AX.setFrame(ax.element, CGRect(x: a.midX - a.width * 0.3, y: a.midY - a.height * 0.35,
                                       width: a.width * 0.6, height: a.height * 0.7).integral)
        focusWindow(window)
    }

    /// Prende o apaga el tiling del Space visible en el monitor de la ventana enfocada.
    func toggleTiling() {
        guard let display = focusedDisplay() else { return }
        let tree = trees[display.key] ?? newTree(display.key)
        tree.enabled.toggle()
        Log.write("tiling \(tree.enabled ? "prendido" : "apagado") en \(display.key)")
        tree.enabled ? refresh() : apply()
    }

    // MARK: - Foco

    func focusedWindowID() -> WindowID? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        guard let app = AX.element(system, kAXFocusedApplicationAttribute),
              let window = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(window)
    }

    private func focusWindow(_ window: WindowID) {
        guard let ax = known[window] else { return }
        lastFocused = window
        AX.perform(ax.element, kAXRaiseAction)
        AX.set(ax.element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(AXUIElementCreateApplication(ax.pid), kAXFrontmostAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: ax.pid)?.activate()
    }

    private func focusedContext() -> (window: WindowID, tree: LayoutTree, display: DisplaySpace)? {
        guard let window = focusedWindowID() ?? lastFocused, let key = windowSpace[window], let tree = trees[key],
              let display = displays.first(where: { $0.key == key }) else { return nil }
        return (window, tree, display)
    }

    private func focusedDisplay() -> DisplaySpace? {
        if let window = focusedWindowID(), let key = windowSpace[window], let display = displays.first(where: { $0.key == key }) {
            return display
        }
        let mouse = Spaces.flip(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return displays.first { $0.frame.contains(mouse) } ?? displays.first
    }

    // MARK: - Ayudas

    private func newTree(_ key: String) -> LayoutTree {
        let tree = LayoutTree()
        trees[key] = tree
        return tree
    }

    private func display(containing frame: CGRect) -> DisplaySpace? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let display = displays.first(where: { $0.frame.contains(center) }) { return display }
        func overlap(_ d: DisplaySpace) -> CGFloat {
            let i = d.frame.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        return displays.max { overlap($0) < overlap($1) }
    }

    private func display(beside display: DisplaySpace, _ direction: Direction) -> DisplaySpace? {
        let a = display.frame
        let candidates = displays.filter { other in
            guard other.key != display.key, !other.isFullscreen else { return false }
            let b = other.frame
            switch direction {
            case .left: return b.midX < a.minX
            case .right: return b.midX > a.maxX
            case .up: return b.midY < a.minY
            case .down: return b.midY > a.maxY
            }
        }
        func distance(_ d: DisplaySpace) -> CGFloat { hypot(d.frame.midX - a.midX, d.frame.midY - a.midY) }
        return candidates.min { distance($0) < distance($1) }
    }

    private func observe(pid: pid_t, app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func observe(_ window: AXWindow) {
        guard !observedWindows.contains(window.id), let observer = observers[window.pid] else { return }
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXTitleChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, nil)
        }
        observedWindows.insert(window.id)
    }

    private static func onScreenWindowIDs() -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }
}
