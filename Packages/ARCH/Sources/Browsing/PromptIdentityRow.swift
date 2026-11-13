// The first row of a prompt card, which says who asks: the site's icon or a symbol, its name, a lock for an encrypted connection, a tag such as "Proxy", and where the asker is. For a page's own dialog, which has no title of Arch's, the row heads the card in the title's weight.
import AppKit
import SwiftUI

struct PromptIdentityRow: View {
    let identity: PromptIdentity
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(identity.name)
                .font(.system(size: isHeader ? 13 : 12, weight: isHeader ? .semibold : .medium))
                .foregroundStyle(isHeader ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if identity.isSecure {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Secure connection")
            }
            if let tag = identity.tag {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .lineLimit(1)
            }
            if let context = identity.context {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    @ViewBuilder private var icon: some View {
        switch identity.icon {
        case let .image(image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
