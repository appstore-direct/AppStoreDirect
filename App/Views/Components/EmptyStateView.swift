import SwiftUI

/// A centred empty state: glyph, title, message, and optional actions beneath.
///
/// Used instead of `ContentUnavailableView` where the screen needs extra content
/// under the message — the Apps page puts device status and quick picks there.
struct EmptyStateView<Accessory: View>: View {
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)

            Text(title)
                .font(.title2.weight(.semibold))

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 5)
            }

            accessory
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

extension EmptyStateView where Accessory == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
