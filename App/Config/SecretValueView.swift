import SwiftUI

/// A value that is masked until the user asks for it.
///
/// Env var values and secret file contents are secrets by default — an API key on screen in a
/// standup, a screen share, or a photo of a phone is the failure this guards against. The mask is
/// per value and resets whenever the view is rebuilt, so revealing one thing never reveals the rest
/// and nothing stays revealed across a navigation.
///
/// `privacySensitive()` is applied on top: it redacts the value in a Lock Screen or Always-On
/// context, which is the one place iOS will render this view without the user present. It does
/// **not** exclude the value from screenshots — iOS has no API for that outside a secure text
/// field — so the mask, not the modifier, is what does the real work here.
struct SecretValueView: View {
    let value: String
    /// Placeholder shown when the value is empty, since a blank row reads as a rendering bug.
    var emptyPlaceholder = "(empty)"

    @State private var isRevealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if value.isEmpty {
                    Text(emptyPlaceholder).foregroundStyle(.tertiary)
                } else if isRevealed {
                    Text(value)
                        .textSelection(.enabled)
                        .privacySensitive()
                } else {
                    Text(Self.mask(for: value))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(isRevealed ? 6 : 1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !value.isEmpty {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isRevealed ? "Hide value" : "Reveal value")
            }
        }
    }

    /// A fixed-width mask rather than one dot per character: the length of a secret is itself a
    /// hint, and a 64-character token would wrap the row for no benefit.
    static func mask(for value: String) -> String {
        String(repeating: "•", count: 12)
    }
}
