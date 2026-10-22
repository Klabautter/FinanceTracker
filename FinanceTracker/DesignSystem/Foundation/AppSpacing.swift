import SwiftUI

enum AppSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Compatibility alias for existing screens. New components should use
    /// the semantic radius that matches their role.
    static let cardCornerRadius: CGFloat = AppRadius.large
}
