import Foundation

/// What the main pane is showing: the chronological history, one category,
/// the virtual 1Password vault (secrets shared to Clippy), or the Scripts panel.
enum PanelSelection: Hashable {
    case history
    case category(Int64)
    case onePassword
    case scripts
}
