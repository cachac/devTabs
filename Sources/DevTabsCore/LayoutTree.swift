import CoreGraphics

public typealias WindowID = UInt32

/// `horizontal`: los hijos van uno al lado del otro; `vertical`: uno arriba del otro.
public enum Orientation: Sendable {
    case horizontal, vertical

    public var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: Sendable {
    case left, right, up, down

    var orientation: Orientation { (self == .left || self == .right) ? .horizontal : .vertical }
    var placesFirst: Bool { self == .left || self == .up }
}

public enum StackMode: Sendable {
    case tabs, accordion
}

public struct Config: Sendable {
    public var gap: CGFloat
    public var barHeight: CGFloat
    /// Cuánto asoma cada ventana de atrás en un acordeón mientras no se ajuste arrastrando el borde.
    public var accordionPadding: CGFloat
    /// Lo mínimo que mide cada ventana de un acordeón, por más que se arrastre el borde.
    public var minActiveWidth: CGFloat

    public init(gap: CGFloat = 8, barHeight: CGFloat = 28, accordionPadding: CGFloat = 30, minActiveWidth: CGFloat = 240) {
        self.gap = gap
        self.barHeight = barHeight
        self.accordionPadding = accordionPadding
        self.minActiveWidth = minActiveWidth
    }
}

public class Node {
    public fileprivate(set) weak var parent: SplitNode?

    init() {}
}

/// Un hueco del árbol. Con una ventana es un tile común; marcado como stack junta varias ventanas en el mismo hueco.
public final class TileNode: Node {
    public internal(set) var windows: [WindowID]
    public internal(set) var active = 0
    public internal(set) var isStack = false
    public internal(set) var mode: StackMode = .tabs
    /// Cuánto asoma cada ventana de atrás en el acordeón, si se ajustó arrastrando el borde de la de adelante.
    public internal(set) var peek: CGFloat?

    init(_ windows: [WindowID]) {
        self.windows = windows
    }

    public var activeWindow: WindowID? { windows.indices.contains(active) ? windows[active] : nil }
}

public final class SplitNode: Node {
    public internal(set) var orientation: Orientation
    public internal(set) var ratio: CGFloat
    public fileprivate(set) var first: Node
    public fileprivate(set) var second: Node

    init(_ orientation: Orientation, ratio: CGFloat = 0.5, first: Node, second: Node) {
        self.orientation = orientation
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init()
        first.parent = self
        second.parent = self
    }
}

public struct TileLayout {
    public let tile: TileNode
    /// El hueco entero, con la barra incluida.
    public let rect: CGRect
    /// La barra de pestañas; `nil` si el tile no es stack.
    public let barRect: CGRect?
    /// Sólo las ventanas visibles, en el orden de las pestañas.
    public let frames: [(window: WindowID, frame: CGRect)]
    public let activeWindow: WindowID?
}

public enum MoveResult: Equatable, Sendable {
    case none, swapped, joined, detached
}

/// El árbol de un Space en un monitor. Las coordenadas tienen el origen arriba a la izquierda, como la API de Accesibilidad.
public final class LayoutTree {
    public private(set) var root: Node?
    public var enabled = true
    /// Ventanas minimizadas o de apps ocultas: conservan su lugar en el árbol y no ocupan espacio hasta que vuelven.
    public private(set) var hidden: Set<WindowID> = []

    public init() {}

    public var tiles: [TileNode] {
        var out: [TileNode] = []
        collect(root, into: &out)
        return out
    }

    public var windows: [WindowID] { tiles.flatMap(\.windows) }

    public func tile(containing window: WindowID) -> TileNode? {
        tiles.first { $0.windows.contains(window) }
    }

    public func contains(_ window: WindowID) -> Bool { tile(containing: window) != nil }

    // MARK: - Layout

    public func layout(in area: CGRect, config: Config) -> [TileLayout] {
        var out: [TileLayout] = []
        place(root, in: area.insetBy(dx: config.gap, dy: config.gap), config: config, into: &out)
        return out
    }

    /// Dónde pone el layout a una ventana visible.
    public func expectedFrame(of window: WindowID, area: CGRect, config: Config) -> CGRect? {
        for layout in layout(in: area, config: config) {
            if let item = layout.frames.first(where: { $0.window == window }) { return item.frame }
        }
        return nil
    }

    // MARK: - Cambios

    /// Una ventana nueva entra al stack enfocado o parte en dos el tile enfocado, a lo ancho si es más ancho que alto.
    public func insert(_ window: WindowID, focused: WindowID?, area: CGRect, config: Config) {
        guard !contains(window) else { return }
        guard root != nil else {
            root = TileNode([window])
            return
        }
        guard let target = focused.flatMap({ tile(containing: $0) }) ?? tiles.last(where: { isVisible($0) }) ?? tiles.last else { return }
        if target.isStack {
            target.windows.append(window)
            target.active = target.windows.count - 1
            return
        }
        split(target, with: TileNode([window]), orientation: orientationFor(target, area: area, config: config), newFirst: false)
    }

    @discardableResult
    public func remove(_ window: WindowID) -> Bool {
        guard let tile = tile(containing: window), let index = tile.windows.firstIndex(of: window) else { return false }
        hidden.remove(window)
        tile.windows.remove(at: index)
        if index < tile.active { tile.active -= 1 }
        tile.active = min(tile.active, max(0, tile.windows.count - 1))
        if tile.windows.isEmpty { removeTile(tile) }
        return true
    }

    /// Oculta o vuelve a mostrar una ventana sin sacarla de su lugar. Si era la activa de un stack, pasa a serlo la más cercana.
    public func setHidden(_ window: WindowID, _ value: Bool) {
        guard let tile = tile(containing: window) else { return }
        guard value else {
            hidden.remove(window)
            return
        }
        hidden.insert(window)
        if tile.activeWindow == window {
            let candidates = tile.windows.indices.filter { !hidden.contains(tile.windows[$0]) }
            if let nearest = candidates.min(by: { abs($0 - tile.active) < abs($1 - tile.active) }) { tile.active = nearest }
        }
    }

    /// El tile más cercano en esa dirección que comparte franja con el actual.
    public func neighbor(of tile: TileNode, _ direction: Direction, area: CGRect, config: Config) -> TileNode? {
        let layouts = layout(in: area, config: config)
        guard let current = layouts.first(where: { $0.tile === tile })?.rect else { return nil }
        var best: (tile: TileNode, distance: CGFloat, overlap: CGFloat)?
        for candidate in layouts where candidate.tile !== tile {
            let r = candidate.rect
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard r.maxX <= current.minX + 1 else { continue }
                distance = current.minX - r.maxX
                overlap = min(r.maxY, current.maxY) - max(r.minY, current.minY)
            case .right:
                guard r.minX >= current.maxX - 1 else { continue }
                distance = r.minX - current.maxX
                overlap = min(r.maxY, current.maxY) - max(r.minY, current.minY)
            case .up:
                guard r.maxY <= current.minY + 1 else { continue }
                distance = current.minY - r.maxY
                overlap = min(r.maxX, current.maxX) - max(r.minX, current.minX)
            case .down:
                guard r.minY >= current.maxY - 1 else { continue }
                distance = r.minY - current.maxY
                overlap = min(r.maxX, current.maxX) - max(r.minX, current.minX)
            }
            guard overlap > 0 else { continue }
            if let b = best, distance > b.distance + 0.5 || (abs(distance - b.distance) <= 0.5 && overlap <= b.overlap) { continue }
            best = (candidate.tile, distance, overlap)
        }
        return best?.tile
    }

    /// Mover una ventana: sale de su stack hacia ese lado, entra al stack vecino o se intercambia con el tile vecino.
    @discardableResult
    public func move(_ window: WindowID, _ direction: Direction, area: CGRect, config: Config) -> MoveResult {
        guard let tile = tile(containing: window) else { return .none }
        if tile.isStack && visible(tile).windows.count > 1 {
            remove(window)
            split(tile, with: TileNode([window]), orientation: direction.orientation, newFirst: direction.placesFirst)
            return .detached
        }
        guard let other = neighbor(of: tile, direction, area: area, config: config) else { return .none }
        if other.isStack {
            remove(window)
            other.windows.append(window)
            other.active = other.windows.count - 1
            return .joined
        }
        swap(&tile.windows, &other.windows)
        swap(&tile.active, &other.active)
        swap(&tile.isStack, &other.isStack)
        swap(&tile.mode, &other.mode)
        swap(&tile.peek, &other.peek)
        return .swapped
    }

    /// Prende el stack en el tile de la ventana; si ya era stack, cada ventana vuelve a su propio tile.
    public func toggleStack(_ window: WindowID, area: CGRect, config: Config) {
        guard let tile = tile(containing: window) else { return }
        guard tile.isStack else {
            tile.isStack = true
            tile.mode = .tabs
            return
        }
        tile.isStack = false
        tile.peek = nil
        let keep = tile.activeWindow ?? window
        let others = tile.windows.filter { $0 != keep }
        tile.windows = [keep]
        tile.active = 0
        var last = tile
        for other in others {
            let next = TileNode([other])
            split(last, with: next, orientation: orientationFor(last, area: area, config: config), newFirst: false)
            last = next
        }
    }

    /// Junta en un solo stack todas las ventanas del árbol, con la de `window` como activa. Si el árbol ya es un solo stack, lo
    /// desarma; si tiene una sola ventana, la deja como stack de una pestaña para que las ventanas nuevas entren ahí.
    public func toggleStackAll(_ window: WindowID, area: CGRect, config: Config) {
        guard contains(window) else { return }
        if let only = root as? TileNode {
            if only.isStack {
                toggleStack(window, area: area, config: config)
            } else {
                only.isStack = true
                only.mode = .tabs
            }
            return
        }
        let all = windows
        let tile = TileNode(all)
        tile.isStack = true
        tile.active = all.firstIndex(of: window) ?? 0
        root = tile
        tile.parent = nil
    }

    /// Pasa a la pestaña visible vecina sin dar la vuelta; `nil` si no es stack o ya está en la primera o la última.
    @discardableResult
    public func step(_ window: WindowID, forward: Bool) -> WindowID? {
        guard let tile = tile(containing: window), tile.isStack else { return nil }
        let (list, active) = visible(tile)
        let next = active + (forward ? 1 : -1)
        guard list.count > 1, list.indices.contains(next), let index = tile.windows.firstIndex(of: list[next]) else { return nil }
        tile.active = index
        return list[next]
    }

    /// Pasa a la pestaña visible siguiente o anterior, dando la vuelta, y devuelve la ventana que quedó activa.
    @discardableResult
    public func cycle(_ window: WindowID, forward: Bool) -> WindowID? {
        guard let tile = tile(containing: window), tile.isStack else { return nil }
        let (list, active) = visible(tile)
        guard list.count > 1 else { return nil }
        let next = list[(active + (forward ? 1 : list.count - 1)) % list.count]
        tile.active = tile.windows.firstIndex(of: next) ?? tile.active
        return next
    }

    /// Marca la ventana como la activa de su tile; devuelve `true` si cambió.
    @discardableResult
    public func activate(_ window: WindowID) -> Bool {
        guard !hidden.contains(window), let tile = tile(containing: window), let index = tile.windows.firstIndex(of: window),
              tile.active != index else { return false }
        tile.active = index
        return true
    }

    public func toggleAccordion(_ window: WindowID) {
        guard let tile = tile(containing: window), tile.isStack else { return }
        tile.mode = tile.mode == .tabs ? .accordion : .tabs
    }

    public func toggleOrientation(_ window: WindowID) {
        guard let parent = tile(containing: window)?.parent else { return }
        parent.orientation = parent.orientation.flipped
    }

    /// Agranda (delta positivo) o achica el tile de la ventana dentro de su división.
    public func adjustRatio(_ window: WindowID, by delta: CGFloat) {
        guard let tile = tile(containing: window), let parent = tile.parent else { return }
        let signed = parent.first === tile ? delta : -delta
        parent.ratio = min(0.9, max(0.1, parent.ratio + signed))
    }

    /// Cuando se arrastra un borde de la ventana activa de un acordeón hacia las de atrás, la franja que asoma de cada una pasa
    /// a medir lo que quedó a la vista. Mover la ventana sin cambiar su ancho no cuenta. Devuelve la franja nueva, o `nil`.
    @discardableResult
    public func adjustPeek(_ window: WindowID, toFit frame: CGRect, area: CGRect, config: Config) -> CGFloat? {
        guard let tile = tile(containing: window), tile.isStack, tile.mode == .accordion,
              let layout = layout(in: area, config: config).first(where: { $0.tile === tile }),
              layout.activeWindow == window, layout.frames.count > 1,
              let expected = layout.frames.first(where: { $0.window == window })?.frame,
              abs(frame.width - expected.width) >= 2 else { return nil }
        let (list, active) = visible(tile)
        let raw: CGFloat
        if active > 0 && abs(frame.minX - expected.minX) >= 2 {
            raw = (frame.minX - layout.rect.minX) / CGFloat(active)
        } else if active < list.count - 1 && abs(frame.maxX - expected.maxX) >= 2 {
            raw = (layout.rect.maxX - frame.maxX) / CGFloat(list.count - 1 - active)
        } else {
            return nil
        }
        let value = min(Self.maxPeek(list.count, layout.rect.width, config), max(0, raw.rounded()))
        guard abs(value - Self.peek(tile, list.count, layout.rect.width, config)) >= 1 else { return nil }
        tile.peek = value
        return value
    }

    /// Cuando se arrastra el borde de una ventana acomodada, la división que separa ese borde de la ventana vecina se corre
    /// para que el borde quede donde se soltó, como en Pop. Mover la ventana sin cambiar su tamaño no cuenta. Devuelve `true`
    /// si cambió alguna división.
    @discardableResult
    public func resizeTile(_ window: WindowID, to frame: CGRect, area: CGRect, config: Config) -> Bool {
        guard let tile = tile(containing: window), let expected = expectedFrame(of: window, area: area, config: config),
              abs(frame.width - expected.width) >= 2 || abs(frame.height - expected.height) >= 2 else { return false }
        let rects = nodeRects(in: area, config: config)
        var changed = false
        func shift(_ orientation: Orientation, tileIsFirst: Bool, by delta: CGFloat) {
            guard abs(delta) >= 2, let split = ancestor(of: tile, orientation, tileIsFirst: tileIsFirst),
                  let rect = rects[ObjectIdentifier(split)] else { return }
            let total = (orientation == .horizontal ? rect.width : rect.height) - config.gap
            guard total > 0 else { return }
            let first = (total * split.ratio).rounded() + delta
            split.ratio = min(0.9, max(0.1, first / total))
            changed = true
        }
        shift(.horizontal, tileIsFirst: true, by: frame.maxX - expected.maxX)
        shift(.horizontal, tileIsFirst: false, by: frame.minX - expected.minX)
        shift(.vertical, tileIsFirst: true, by: frame.maxY - expected.maxY)
        shift(.vertical, tileIsFirst: false, by: frame.minY - expected.minY)
        return changed
    }

    // MARK: - Internos

    private func collect(_ node: Node?, into out: inout [TileNode]) {
        if let tile = node as? TileNode {
            out.append(tile)
        } else if let split = node as? SplitNode {
            collect(split.first, into: &out)
            collect(split.second, into: &out)
        }
    }

    private func isVisible(_ node: Node?) -> Bool {
        if let tile = node as? TileNode { return tile.windows.contains { !hidden.contains($0) } }
        if let split = node as? SplitNode { return isVisible(split.first) || isVisible(split.second) }
        return false
    }

    /// Las ventanas visibles de un tile y la posición de la activa entre ellas.
    private func visible(_ tile: TileNode) -> (windows: [WindowID], active: Int) {
        let list = tile.windows.filter { !hidden.contains($0) }
        return (list, tile.activeWindow.flatMap { list.firstIndex(of: $0) } ?? 0)
    }

    /// Una división con un lado oculto le da todo el espacio al otro.
    private func place(_ node: Node?, in rect: CGRect, config: Config, into out: inout [TileLayout]) {
        guard let node, isVisible(node) else { return }
        if let split = node as? SplitNode {
            guard isVisible(split.first), isVisible(split.second) else {
                place(isVisible(split.first) ? split.first : split.second, in: rect, config: config, into: &out)
                return
            }
            let (a, b) = Self.divide(rect, split.orientation, split.ratio, config.gap)
            place(split.first, in: a, config: config, into: &out)
            place(split.second, in: b, config: config, into: &out)
        } else if let tile = node as? TileNode {
            out.append(tileLayout(tile, rect, config))
        }
    }

    private func nodeRects(in area: CGRect, config: Config) -> [ObjectIdentifier: CGRect] {
        var out: [ObjectIdentifier: CGRect] = [:]
        func visit(_ node: Node?, _ rect: CGRect) {
            guard let node, isVisible(node) else { return }
            out[ObjectIdentifier(node)] = rect
            guard let split = node as? SplitNode else { return }
            if isVisible(split.first) && isVisible(split.second) {
                let (a, b) = Self.divide(rect, split.orientation, split.ratio, config.gap)
                visit(split.first, a)
                visit(split.second, b)
            } else {
                visit(isVisible(split.first) ? split.first : split.second, rect)
            }
        }
        visit(root, area.insetBy(dx: config.gap, dy: config.gap))
        return out
    }

    /// La división más cercana con esa orientación que tiene a `node` del lado pedido y una ventana visible del otro: el borde
    /// que las separa es el que se arrastró.
    private func ancestor(of node: Node, _ orientation: Orientation, tileIsFirst: Bool) -> SplitNode? {
        var child = node
        while let parent = child.parent {
            if parent.orientation == orientation && (tileIsFirst ? parent.first === child : parent.second === child)
                && isVisible(tileIsFirst ? parent.second : parent.first) { return parent }
            child = parent
        }
        return nil
    }

    static func divide(_ r: CGRect, _ orientation: Orientation, _ ratio: CGFloat, _ gap: CGFloat) -> (CGRect, CGRect) {
        switch orientation {
        case .horizontal:
            let w = ((r.width - gap) * ratio).rounded()
            return (CGRect(x: r.minX, y: r.minY, width: w, height: r.height),
                    CGRect(x: r.minX + w + gap, y: r.minY, width: r.width - w - gap, height: r.height))
        case .vertical:
            let h = ((r.height - gap) * ratio).rounded()
            return (CGRect(x: r.minX, y: r.minY, width: r.width, height: h),
                    CGRect(x: r.minX, y: r.minY + h + gap, width: r.width, height: r.height - h - gap))
        }
    }

    /// En pestañas todas las ventanas ocupan el mismo lugar debajo de la barra. En acordeón cada una tiene un lugar fijo,
    /// corrido una franja respecto de la anterior y con el mismo ancho: cambiar de pestaña sólo cambia cuál queda adelante, así
    /// ninguna ventana cambia de tamaño ni reacomoda su contenido.
    private func tileLayout(_ tile: TileNode, _ r: CGRect, _ config: Config) -> TileLayout {
        let (list, active) = visible(tile)
        let activeWindow = list.indices.contains(active) ? list[active] : nil
        guard tile.isStack else {
            return TileLayout(tile: tile, rect: r, barRect: nil, frames: list.map { ($0, r) }, activeWindow: activeWindow)
        }
        let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: config.barHeight)
        let content = CGRect(x: r.minX, y: r.minY + config.barHeight, width: r.width, height: max(0, r.height - config.barHeight))
        var frames: [(window: WindowID, frame: CGRect)] = list.map { ($0, content) }
        if tile.mode == .accordion && list.count > 1 {
            let peek = Self.peek(tile, list.count, content.width, config)
            let width = content.width - CGFloat(list.count - 1) * peek
            frames = list.enumerated().map { index, window in
                (window, CGRect(x: content.minX + CGFloat(index) * peek, y: content.minY, width: width, height: content.height))
            }
        }
        return TileLayout(tile: tile, rect: r, barRect: bar, frames: frames, activeWindow: activeWindow)
    }

    /// Cada franja deja a cada ventana al menos `minActiveWidth` y no puede superar el ancho de las ventanas, porque si no
    /// quedaría un hueco sin cubrir entre ellas.
    static func maxPeek(_ count: Int, _ width: CGFloat, _ config: Config) -> CGFloat {
        guard count > 1 else { return 0 }
        let byMinimum = (width - config.minActiveWidth) / CGFloat(count - 1)
        let byCoverage = width / CGFloat(count)
        return max(0, min(byMinimum, byCoverage).rounded(.down))
    }

    static func peek(_ tile: TileNode, _ count: Int, _ width: CGFloat, _ config: Config) -> CGFloat {
        min(maxPeek(count, width, config), max(0, tile.peek ?? config.accordionPadding))
    }

    private func orientationFor(_ tile: TileNode, area: CGRect, config: Config) -> Orientation {
        let rect = layout(in: area, config: config).first { $0.tile === tile }?.rect ?? area
        return rect.width >= rect.height ? .horizontal : .vertical
    }

    private func split(_ target: TileNode, with new: TileNode, orientation: Orientation, newFirst: Bool) {
        let parent = target.parent
        let node = newFirst
            ? SplitNode(orientation, first: new, second: target)
            : SplitNode(orientation, first: target, second: new)
        replace(target, with: node, in: parent)
    }

    private func replace(_ old: Node, with new: Node, in parent: SplitNode?) {
        if let parent {
            if parent.first === old { parent.first = new } else { parent.second = new }
            new.parent = parent
        } else {
            root = new
            new.parent = nil
        }
    }

    private func removeTile(_ tile: TileNode) {
        guard let parent = tile.parent else {
            root = nil
            return
        }
        let sibling = parent.first === tile ? parent.second : parent.first
        replace(parent, with: sibling, in: parent.parent)
    }
}
