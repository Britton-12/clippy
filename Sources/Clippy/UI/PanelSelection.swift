import Foundation

/// What the main pane is showing: the chronological history or one category.
enum PanelSelection: Hashable {
    case history
    case category(Int64)
}
