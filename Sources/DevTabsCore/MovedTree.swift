/// macOS renumera los Spaces al despertar o al reconectar un monitor. De los árboles cuyo Space ya no existe, el que tiene más de
/// las ventanas que aparecieron en un Space es el que se mudó ahí. Las claves son "<monitor>#<Space>".
public func movedTree(showing windows: Set<WindowID>, trees: [String: LayoutTree], liveSpaces: Set<Int>) -> String? {
    guard !liveSpaces.isEmpty, !windows.isEmpty else { return nil }
    let candidates = trees.compactMap { key, tree -> (key: String, count: Int)? in
        guard let space = key.split(separator: "#").last.flatMap({ Int($0) }), !liveSpaces.contains(space) else { return nil }
        let count = windows.intersection(tree.windows).count
        return count > 0 ? (key, count) : nil
    }
    return candidates.max { ($0.count, $1.key) < ($1.count, $0.key) }?.key
}
