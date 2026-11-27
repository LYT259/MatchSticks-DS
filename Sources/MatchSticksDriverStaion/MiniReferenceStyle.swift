enum MiniReferenceStyle: String, CaseIterable {
    case niClassic
    case firstModern

    var displayName: String {
        switch self {
        case .niClassic: return "NI Classic"
        case .firstModern: return "FIRST Modern"
        }
    }
}
