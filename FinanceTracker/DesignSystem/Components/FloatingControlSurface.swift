import SwiftUI

/// Availability-safe Liquid Glass layer for floating controls only.
/// Falls back to a system material on older OS versions; never fake
/// glass, and never applied to finance content surfaces.
extension View {
    @ViewBuilder
    func floatingControlSurface(cornerRadius: CGFloat = AppSpacing.cardCornerRadius) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self
                .glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                )
        }
    }
}
