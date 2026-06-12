import Foundation

/// What the main pane is showing: the chronological history, one category, or
/// the virtual 1Password vault (secrets shared to Clippy).
enum PanelSelection: Hashable {
    case history
    case category(Int64)
    case onePassword
}
