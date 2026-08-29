import AppStoreDirectKit
import SwiftUI

/// A small tinted capsule: install state, ownership, connection, and similar.
///
/// One component for every status pill in the app, so they cannot drift apart.
struct StatusBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var isWorking = false
    var prominence: Prominence = .tinted

    enum Prominence {
        /// Filled tint — for the one status that matters most in a row.
        case tinted
        /// Outline only — for secondary facts like the connection type.
        case subtle
    }

    var body: some View {
        HStack(spacing: 4) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 9, height: 9)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(prominence == .tinted ? tint : .secondary)
        .background {
            Capsule().fill(
                prominence == .tinted
                    ? AnyShapeStyle(tint.opacity(0.14))
                    : AnyShapeStyle(Color.primary.opacity(0.06))
            )
        }
        .contentTransition(.interpolate)
    }
}

extension StatusBadge {
    /// Badge for an install state, using the shared palette and glyphs.
    init(state: DeviceInstallState) {
        self.init(
            text: state.shortLabel,
            symbol: state.symbol,
            tint: state.tint,
            isWorking: state.isWorking
        )
    }

    /// Badge for ownership; free apps get no badge at all.
    init?(ownership: AppOwnershipState) {
        guard let text = ownership.badge else { return nil }
        self.init(text: text, symbol: ownership.symbol, tint: ownership.tint)
    }
}
