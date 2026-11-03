enum TerminalSlots {
    static func assign(occupied: [Int], preferred: Int? = nil) -> Int {
        let used = Set(occupied)
        if let preferred, preferred >= 0, !used.contains(preferred) { return preferred }
        return (0...).first { !used.contains($0) }!
    }
}
