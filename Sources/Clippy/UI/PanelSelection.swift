import Foundation

/// What the main pane is showing: the chronological history or one category.
enum PanelSelection: Equatable {
    case history
    case category(Int64)
}
