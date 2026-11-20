// The parts of the site settings popover: the header that names the tab's site, a group of rows in a rounded box with a title above it and a footnote below it, a row with a symbol, a label, and a control, a button's action, or a word at its end, and the hairline between two rows.
import SwiftUI

/// The measures that the popover's rows, the hairlines between them, and the text around the boxes share.
enum SiteSettingsMetrics {
    /// The space between a box's edges and its rows' content, which the group's title, its footnote, and the header take too, so that they all start where the rows' symbols do.
    static let rowPadding: CGFloat = 10
    /// The sidebar rows' icon column.
    static let iconWidth: CGFloat = 18
    static let iconSpacing: CGFloat = 8
    /// Where a row's label starts, to which the hairlines and what a row shows below its label are inset.
    static let labelInset = rowPadding + iconWidth + iconSpacing
    static let rowMinHeight: CGFloat = 32
    static let boxCornerRadius: CGFloat = 10
    /// A button row's hover fill: a rounded rectangle inset from the box's edges and the hairlines, as a menu's selection. It stays inside the box's corners, so the box needs no clip, which would cut a row's keyboard focus ring.
    static let hoverInset = EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
    static let hoverCornerRadius: CGFloat = 6
}

/// Names the site that the popover's settings are for as the tab's prompt cards name who asks (`PromptSiteIdentity.make(for:in:)`): its icon or a symbol, its name, the lock for an encrypted connection, and the Extension tag for an extension's page. Its icon takes the rows' icon column, so that its name starts where the rows' labels do. VoiceOver reads it as one heading. It follows the tab's page and shows nothing while the tab has no address.
struct SiteSettingsHeader: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.url != nil {
            PromptIdentityRow(identity: PromptSiteIdentity.make(for: tab.url, in: tab), isHeader: true,
                              iconColumnWidth: SiteSettingsMetrics.iconWidth, iconSpacing: SiteSettingsMetrics.iconSpacing)
                .padding(.horizontal, SiteSettingsMetrics.rowPadding)
        }
    }
}

/// Rows in a box on the address pill's field fill, with a title above the box and a footnote below it, as macOS groups settings. Increase Contrast adds the prompt surface's stronger edge to the box. The rows bring the hairlines between them (`SiteSettingsDivider`), since a row that shows only on a condition knows whether a row comes before it.
struct SiteSettingsGroup<Content: View>: View {
    private let title: String?
    private let footnote: String?
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        let box = RoundedRectangle(cornerRadius: SiteSettingsMetrics.boxCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SiteSettingsMetrics.rowPadding)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(box.fill(SidebarFill.field.color(in: colorScheme)))
            .overlay {
                if contrast == .increased {
                    box.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SiteSettingsMetrics.rowPadding)
            }
        }
    }
}

/// The hairline between two rows of a box, from the rows' label edge to their trailing padding.
struct SiteSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, SiteSettingsMetrics.labelInset)
            .padding(.trailing, SiteSettingsMetrics.rowPadding)
    }
}

/// One row of a box: a symbol in the sidebar rows' 18-point icon column, a label, and at the trailing edge a control or what a button row ends with, such as a badge. `help` shows as the row's tooltip and is VoiceOver's hint.
///
/// - A row with a control leaves its label to the control, so that VoiceOver reads the two as one: the caller names the control by the row's label, or more fully where the group's title adds to it, as "Engine for New Tabs".
/// - A button row is the button, which VoiceOver names by the label. Under the pointer it takes the sidebar rows' hover fill, inset from the box's edges (`SiteSettingsMetrics.hoverInset`); disabled, it dims as the sidebar's rows do and takes no fill. A destructive one looks like the others: a row whose label ends in "…" only opens what asks, whose own button is the destructive one, as the Clear Site Data card's Clear.
/// - A row without either only says something, with at most a word at its trailing edge. Its tooltip is its help, or its label, which a long name cuts short.
struct SiteSettingsRow<Icon: View, Accessory: View>: View {
    private enum Kind {
        case text, control
        case button(ButtonRole?, () -> Void)
    }

    private let title: String
    private let help: String?
    private let kind: Kind
    private let icon: Icon
    private let accessory: Accessory
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// A button row with its own icon and trailing view, as an extension's action with its icon and badge.
    init(title: String, help: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.help = help
        kind = .button(role, action)
        self.icon = icon()
        self.accessory = accessory()
    }

    private init(title: String, help: String?, kind: Kind, icon: Icon, accessory: Accessory) {
        self.title = title
        self.help = help
        self.kind = kind
        self.icon = icon
        self.accessory = accessory
    }

    private var isControl: Bool {
        if case .control = kind { return true }
        return false
    }

    var body: some View {
        switch kind {
        case let .button(role, action):
            Button(role: role, action: action) {
                content
                    .background {
                        RoundedRectangle(cornerRadius: SiteSettingsMetrics.hoverCornerRadius, style: .continuous)
                            .fill(isHovering && isEnabled ? SidebarFill.hover.color(in: colorScheme) : .clear)
                            .padding(SiteSettingsMetrics.hoverInset)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help ?? "")
            .accessibilityLabel(title)
            .accessibilityHint(help ?? "")
        case .control:
            content
                .help(help ?? "")
        case .text:
            content
                .help(help ?? title)
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(spacing: SiteSettingsMetrics.iconSpacing) {
            icon
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: SiteSettingsMetrics.iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityHidden(isControl)
            Spacer(minLength: 0)
            accessory
                .labelsHidden()
                .accessibilityLabel(title)
                .controlSize(.small)
                .fixedSize()
                .accessibilityHint(isControl ? help ?? "" : "")
        }
        .padding(.horizontal, SiteSettingsMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: SiteSettingsMetrics.rowMinHeight, alignment: .leading)
    }
}

extension SiteSettingsRow where Icon == Image {
    /// A row with a control at its trailing edge, such as a segmented picker or a switch, which the row shows at the small control size.
    init(symbol: String, title: String, help: String? = nil, @ViewBuilder control: () -> Accessory) {
        self.init(title: title, help: help, kind: .control, icon: Image(systemName: symbol), accessory: control())
    }
}

extension SiteSettingsRow where Icon == Image, Accessory == EmptyView {
    /// A row that only says something.
    init(symbol: String, title: String, help: String? = nil) {
        self.init(title: title, help: help, kind: .text, icon: Image(systemName: symbol), accessory: EmptyView())
    }

    /// A button row.
    init(symbol: String, title: String, help: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(title: title, help: help, kind: .button(role, action), icon: Image(systemName: symbol), accessory: EmptyView())
    }
}

extension SiteSettingsRow where Icon == Image, Accessory == Text {
    /// A row that only says something, with `detail` at its trailing edge in 11-point secondary text, as Installed after an extension's name.
    init(symbol: String, title: String, help: String? = nil, detail: String) {
        self.init(title: title, help: help, kind: .text, icon: Image(systemName: symbol),
                  accessory: Text(detail).font(.system(size: 11)).foregroundStyle(.secondary))
    }
}
