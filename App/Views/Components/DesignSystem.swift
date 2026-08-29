import AppStoreDirectKit
import SwiftUI

/// Shared visual constants, so spacing and radii are consistent across views
/// rather than re-invented per screen.
enum Metric {
    static let cardRadius: CGFloat = 10
    static let iconRadius: CGFloat = 12
    static let rowSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let appIcon: CGFloat = 52
    static let badgeIcon: CGFloat = 18
}

/// Maps install state onto the system palette.
///
/// Lives in the view layer as an extension: the state enum itself belongs to the
/// install pipeline and stays free of any opinion about presentation.
extension DeviceInstallState {
    var tint: Color {
        switch self {
        case .idle, .queued:      return .secondary
        case .preparing, .authorizing, .downloading, .transferring, .installing:
            return .accentColor
        case .installed:          return .green
        case .failed:             return .red
        case .cancelled:          return .secondary
        case .incompatible:       return .orange
        }
    }

    var symbol: String {
        switch self {
        case .idle:          return "circle.dashed"
        case .queued:        return "clock"
        case .preparing, .authorizing: return "hourglass"
        case .downloading:   return "arrow.down.circle"
        case .transferring:  return "arrow.right.circle"
        case .installing:    return "square.and.arrow.down"
        case .installed:     return "checkmark.circle.fill"
        case .failed:        return "exclamationmark.circle.fill"
        case .cancelled:     return "xmark.circle.fill"
        case .incompatible:  return "minus.circle.fill"
        }
    }

    /// Whether the badge should spin a progress indicator instead of a glyph.
    var isWorking: Bool {
        switch self {
        case .preparing, .authorizing, .downloading, .transferring, .installing:
            return true
        default:
            return false
        }
    }
}

extension AppOwnershipState {
    var tint: Color {
        switch self {
        case .free:         return .secondary
        case .purchased:    return .green
        case .notPurchased: return .orange
        case .unknown:      return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .purchased:    return "checkmark.seal.fill"
        case .notPurchased: return "exclamationmark.circle"
        default:            return nil
        }
    }
}

/// A card surface: the standard container for device and result rows.
struct CardBackground: ViewModifier {
    var isHighlighted = false
    var isSelected = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                          : AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            }
            // Hover is a hint, not a highlight — a whole-row tint at twenty rows
            // reads as noise.
            .overlay {
                if isHighlighted && !isSelected {
                    RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

extension View {
    func cardSurface(isHighlighted: Bool = false, isSelected: Bool = false) -> some View {
        modifier(CardBackground(isHighlighted: isHighlighted, isSelected: isSelected))
    }
}
