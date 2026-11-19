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
    /// La franja que asoma de cada lado en un accordion mientras no se ajuste arrastrando el borde.
    public var accordionPadding: CGFloat
    /// Lo mínimo que queda a la vista de la ventana activa de un accordion, por más que se arrastre el borde.
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
    /// Las franjas del accordion a la izquierda y a la derecha de la activa, si se ajustaron arrastrando su borde.
    public internal(set) var peekBefore: CGFloat?
    public internal(set) var peekAfter: CGFloat?

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
    public let frames: [(window: WindowID, frame: CGRect)]
}

public enum MoveResult: Equatable, Sendable {
    case none, swapped, joined, detached
}

/// El árbol de un Space en un monitor. Las coordenadas tienen el origen arriba a la izquierda, como la API de Accesibilidad.
public final class LayoutTree {
    public private(set) var root: Node?
    public var enabled = true

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
        guard let root else { return [] }
        var out: [TileLayout] = []
        place(root, in: area.insetBy(dx: config.gap, dy: config.gap), config: config, into: &out)
        return out
    }

    // MARK: - Cambios

    /// Una ventana nueva entra al stack enfocado o parte en dos el tile enfocado, a lo ancho si es más ancho que alto.
    public func insert(_ window: WindowID, focused: WindowID?, area: CGRect, config: Config) {
        guard !contains(window) else { return }
        guard root != nil else {
            root = TileNode([window])
            return
        }
        guard let target = focused.flatMap({ tile(containing: $0) }) ?? tiles.last else { return }
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
        tile.windows.remove(at: index)
        if index < tile.active { tile.active -= 1 }
        tile.active = min(tile.active, max(0, tile.windows.count - 1))
        if tile.windows.isEmpty { removeTile(tile) }
        return true
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
        if tile.isStack && tile.windows.count > 1 {
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

    /// Pasa a la pestaña vecina del stack sin dar la vuelta; `nil` si no es stack o ya está en la primera o la última.
    @discardableResult
    public func step(_ window: WindowID, forward: Bool) -> WindowID? {
        guard let tile = tile(containing: window), tile.isStack, tile.windows.count > 1 else { return nil }
        let next = tile.active + (forward ? 1 : -1)
        guard tile.windows.indices.contains(next) else { return nil }
        tile.active = next
        return tile.activeWindow
    }

    /// Pasa a la pestaña siguiente o anterior del stack y devuelve la ventana que quedó activa.
    @discardableResult
    public func cycle(_ window: WindowID, forward: Bool) -> WindowID? {
        guard let tile = tile(containing: window), tile.isStack, tile.windows.count > 1 else { return nil }
        let count = tile.windows.count
        tile.active = (tile.active + (forward ? 1 : count - 1)) % count
        return tile.activeWindow
    }

    /// Marca la ventana como la activa de su tile; devuelve `true` si cambió.
    @discardableResult
    public func activate(_ window: WindowID) -> Bool {
        guard let tile = tile(containing: window), let index = tile.windows.firstIndex(of: window), tile.active != index else { return false }
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

    // MARK: - Internos

    private func collect(_ node: Node?, into out: inout [TileNode]) {
        if let tile = node as? TileNode {
            out.append(tile)
        } else if let split = node as? SplitNode {
            collect(split.first, into: &out)
            collect(split.second, into: &out)
        }
    }

    private func place(_ node: Node, in rect: CGRect, config: Config, into out: inout [TileLayout]) {
        if let split = node as? SplitNode {
            let (a, b) = Self.divide(rect, split.orientation, split.ratio, config.gap)
            place(split.first, in: a, config: config, into: &out)
            place(split.second, in: b, config: config, into: &out)
        } else if let tile = node as? TileNode {
            out.append(Self.tileLayout(tile, rect, config))
        }
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

    /// En pestañas todas las ventanas ocupan el mismo lugar debajo de la barra. En accordion la activa deja una franja
    /// de cada lado donde hay otras: las de antes asoman a la izquierda y las de después a la derecha.
    static func tileLayout(_ tile: TileNode, _ r: CGRect, _ config: Config) -> TileLayout {
        guard tile.isStack else {
            return TileLayout(tile: tile, rect: r, barRect: nil, frames: tile.windows.map { ($0, r) })
        }
        let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: config.barHeight)
        let content = CGRect(x: r.minX, y: r.minY + config.barHeight, width: r.width, height: max(0, r.height - config.barHeight))
        let count = tile.windows.count
        var frames: [(window: WindowID, frame: CGRect)] = []
        let (before, after) = peeks(tile, content.width, config)
        for (index, window) in tile.windows.enumerated() {
            var frame = content
            if tile.mode == .accordion && count > 1 {
                if index == tile.active {
                    frame = CGRect(x: content.minX + before, y: content.minY, width: content.width - before - after, height: content.height)
                } else if index < tile.active {
                    frame = CGRect(x: content.minX, y: content.minY, width: content.width - after, height: content.height)
                } else {
                    frame = CGRect(x: content.minX + before, y: content.minY, width: content.width - before, height: content.height)
                }
            }
            frames.append((window, frame))
        }
        return TileLayout(tile: tile, rect: r, barRect: bar, frames: frames)
    }

    /// Las franjas de cada lado de la activa: sólo donde hay otras pestañas, y achicadas si no dejan `minActiveWidth` a la vista.
    static func peeks(_ tile: TileNode, _ width: CGFloat, _ config: Config) -> (before: CGFloat, after: CGFloat) {
        var before: CGFloat = tile.active > 0 ? max(0, tile.peekBefore ?? config.accordionPadding) : 0
        var after: CGFloat = tile.active < tile.windows.count - 1 ? max(0, tile.peekAfter ?? config.accordionPadding) : 0
        let room = max(0, width - config.minActiveWidth)
        if before + after > room {
            let scale = room / (before + after)
            before = (before * scale).rounded(.down)
            after = (after * scale).rounded(.down)
        }
        return (before, after)
    }

    /// Cuando se arrastra un borde de la ventana activa de un accordion, la franja de ese lado pasa a medir lo que quedó a la
    /// vista de las de atrás. Sólo cuentan los bordes que tienen pestañas de ese lado. Devuelve `true` si cambió alguna franja.
    @discardableResult
    public func adjustPeek(_ window: WindowID, toFit frame: CGRect, area: CGRect, config: Config) -> Bool {
        guard let tile = tile(containing: window), tile.isStack, tile.mode == .accordion, tile.windows.count > 1,
              tile.activeWindow == window,
              let rect = layout(in: area, config: config).first(where: { $0.tile === tile })?.rect else { return false }
        let left = rect.minX
        let right = rect.maxX
        let room = max(0, rect.width - config.minActiveWidth)
        let current = Self.peeks(tile, rect.width, config)
        var changed = false
        if tile.active > 0 {
            let value = min(room, max(0, (frame.minX - left).rounded()))
            if abs(value - current.before) >= 1 {
                tile.peekBefore = value
                changed = true
            }
        }
        if tile.active < tile.windows.count - 1 {
            let value = min(room, max(0, (right - frame.maxX).rounded()))
            if abs(value - current.after) >= 1 {
                tile.peekAfter = value
                changed = true
            }
        }
        return changed
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
