// The address pill below the sidebar's top row: the page's site, which opens the command palette, the Low Power Mode symbol while the mode is on, and the buttons that share the page and open the site settings popover.
import AppKit
import ARCHEngine
import SwiftUI

/// Shows the site's host. Clicking it opens the command palette with the full address, or for a new tab when no tab is open. The buttons at its end share the page and open the site settings. While the palette it opened is visible, the whole pill moves toward it and fades out.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// `nil` when no tab is open.
    let tab: Tab?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spaceTheme) private var theme
    @Environment(\.addressPillPull) private var pull
    @State private var isShowingSiteSettings = false

    private var url: URL? { tab?.url }

    /// The name of the web extension whose page the tab shows (`extensionName(ofPageAt:in:session:)`), unless an internal page covers it.
    private var extensionName: String? {
        guard windowModel.internalPage == nil, let tab, let url else { return nil }
        return Self.extensionName(ofPageAt: url, in: tab, session: session)
    }

    /// The internal page's address, the page's site, the name of the extension whose page it is, or the placeholder with no tab open.
    private func host(extensionName: String?) -> String {
        if let page = windowModel.internalPage { return page.address }
        guard let url else { return "Search or enter address" }
        return extensionName ?? Self.siteName(of: url)
    }

    /// The name of the web extension in the tab's Persona whose page is at `url` (`BrowserSession.extensionName(ofPageAt:in:)`), which the address pill, the small window, and the tab switcher show in place of the identifier that the page's address has as its host; nil for another page. The pill and the small window put the extension symbol before it in place of the globe (`symbol(for:internalPage:isExtensionPage:)`), and VoiceOver reads it as an extension's page (`accessibilityLabel(ofExtensionPage:)`), so that an extension cannot pass its page off as a website by the name it gives itself. The pill's help and the palette keep the whole address.
    static func extensionName(ofPageAt url: URL, in tab: Tab, session: BrowserSession) -> String? {
        session.extensionName(ofPageAt: url, in: tab.personaID)
    }

    /// What VoiceOver reads for the site of an extension's page.
    static func accessibilityLabel(ofExtensionPage name: String) -> String {
        "\(name), extension page"
    }

    /// The page's site as the address pill and the small window show it: its host without `www.`, a local file's name, or the whole address of a page without a host, such as `about:blank`.
    static func siteName(of url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The symbol before a page's site, in the address pill and the small window: the internal page's, a search with no page, a file, a web extension's page, whose site is the extension's name (`extensionName(ofPageAt:in:session:)`), or the connection, secure or not.
    static func symbol(for url: URL?, internalPage: InternalPage?, isExtensionPage: Bool = false) -> String {
        if internalPage != nil { return "flag" }
        guard let url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        if isExtensionPage { return "puzzlepiece.extension" }
        return url.scheme == "https" ? "lock.fill" : "globe"
    }

    var body: some View {
        let extensionName = self.extensionName
        let host = self.host(extensionName: extensionName)
        HStack(spacing: 0) {
            Button(action: { windowModel.focusCommandBar(from: .addressPill) }) {
                // The symbol takes the tab rows' icon column, so the host starts where their titles do, whichever symbol shows.
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(for: url, internalPage: windowModel.internalPage, isExtensionPage: extensionName != nil))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                    Text(host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(url == nil && windowModel.internalPage == nil ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(windowModel.internalPage?.address ?? url?.absoluteString ?? "")
            .accessibilityLabel(extensionName.map(Self.accessibilityLabel(ofExtensionPage:)) ?? host)
            if let tab, !windowModel.isSelectedPageCovered {
                TemporaryEngineLabel(tab: tab)
            }
            LowPowerModeIndicator()
            SidebarIconButton(symbol: "square.and.arrow.up", label: "Share", action: windowModel.shareSelectedPage)
                .disabled(!windowModel.canShareSelectedPage)
                .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
            SidebarIconButton(symbol: "slider.horizontal.3", label: "Site Settings") { isShowingSiteSettings.toggle() }
                .background(SiteControlAnchor(windowModel: windowModel, button: \.siteSettingsButtonView))
                .padding(.trailing, 4)
                // The popover has its own background, so it draws in the window's appearance, not the one the sidebar may take for a strong tint, which a popover on the button itself would inherit.
                .background(Color.clear
                    .popover(isPresented: $isShowingSiteSettings, arrowEdge: .bottom) {
                        SiteSettingsView(session: session, tab: tab) { isShowingSiteSettings = false }
                    }
                    .environment(\.colorScheme, theme.colorScheme))
        }
        .font(.system(size: 14))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SidebarFill.field.color(in: colorScheme)))
        .offset(pull)
        .opacity(pull == .zero ? 1 : 0)
        // Outside the motion, so the frame stays where the pill rests.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AddressPillFrameKey.self, value: proxy.frame(in: .named(BrowserWindowView.coordinateSpace)))
        })
    }
}

/// The address bar names the current renderer while the tab's saved engine is unavailable.
struct TemporaryEngineLabel: View {
    @ObservedObject var tab: Tab

    static func explanation(for tab: Tab) -> String? {
        guard tab.isLoaded, tab.engineKind != tab.preferredEngine else { return nil }
        return "This tab is temporarily using \(tab.engineKind.displayName) because its saved engine, \(tab.preferredEngine.displayName), was unavailable."
    }

    var body: some View {
        if let explanation = Self.explanation(for: tab) {
            Text(tab.engineKind.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(explanation)
                .accessibilityLabel(explanation)
        }
    }
}

/// Marks one of the address pill's buttons for what points at it: the share button for the share picker, and the site settings button for web extensions' popups. The docked sidebar and the floating card each have one of each; the one that joined the window last is the one on screen.
struct SiteControlAnchor: NSViewRepresentable {
    let windowModel: BrowserWindowModel
    /// Where the window keeps the button.
    let button: ReferenceWritableKeyPath<BrowserWindowModel, NSView?>

    func makeNSView(context: Context) -> AnchorView { AnchorView(button: button) }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.windowModel = windowModel
    }

    final class AnchorView: NSView {
        private let button: ReferenceWritableKeyPath<BrowserWindowModel, NSView?>

        init(button: ReferenceWritableKeyPath<BrowserWindowModel, NSView?>) {
            self.button = button
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            return nil
        }

        // Only joining the window registers the view, so an update of the other anchor does not take over.
        weak var windowModel: BrowserWindowModel? {
            didSet { if oldValue == nil, window != nil { windowModel?[keyPath: button] = self } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { windowModel?[keyPath: button] = self }
        }

        // Clicks go to the button above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The system share picker for one page. Its preview shows the page's title and icon, and services that take a subject, such as Mail, get the title.
final class PageSharePicker: NSObject, NSSharingServicePickerDelegate {
    private let picker: NSSharingServicePicker
    private let title: String

    init(url: URL, title: String, icon: NSImage?) {
        self.title = title
        picker = NSSharingServicePicker(items: [NSPreviewRepresentingActivityItem(item: url as NSURL, title: title, image: nil, icon: icon)])
        super.init()
        picker.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        picker.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        service?.subject = title
    }
}

/// The address pill's frame in the window, from which `BrowserWindowView` sends out the palette the pill opens.
struct AddressPillFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The site settings popover: a header that names the tab's site, then in boxes of rows the current tab's engine with whether AI features may send its pages, the actions of its Persona's web extensions, clearing its site's data, and the engine for new tabs (`SiteSettingsParts.swift`). While an internal page or the preview panel covers the tab, it shows only the engine for new tabs, without a header, as in a window without a tab. A click closes the preview before it reaches the button, but a press through VoiceOver leaves the preview open.
struct SiteSettingsView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let tab: Tab?
    /// Closes the popover, so that it does not stay over the card it opens.
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tab, !windowModel.isSelectedPageCovered {
                SiteSettingsHeader(tab: tab)
                TabEngineSection(session: session, tab: tab)
                if let webExtensions = session.webExtensions(in: tab.personaID) {
                    WebExtensionActionsSection(session: session, webExtensions: webExtensions, tab: tab, close: close)
                }
                // The card that the row opens says what goes, so this sentence is only the row's help.
                SiteSettingsGroup("Site Data") {
                    SiteSettingsRow(symbol: "trash", title: "Clear Site Data\u{2026}", help: "Removes the site\u{2019}s cookies and stored data from both engines and signs you out of it.", role: .destructive, action: {
                        close()
                        windowModel.confirmClearSiteData()
                    })
                    .disabled(!windowModel.canClearSiteData)
                }
            }
            SiteSettingsGroup("New Tabs", footnote: "Tabs that a page opens use that page\u{2019}s engine.") {
                // The group's title says which tabs. “Engine for New Tabs” would leave the picker no room, so only VoiceOver reads it.
                SiteSettingsRow(symbol: "plus.square.on.square", title: "Engine") {
                    Picker("Engine for New Tabs", selection: Binding(get: { session.defaultEngine }, set: { session.defaultEngine = $0 })) {
                        ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        // The address pill's 14-point font reaches the popover. The rows set their own sizes, and the controls take their control size's.
        .font(nil)
        .padding(12)
        .frame(width: 300)
    }
}

/// The This Tab group. It observes the tab so the picker follows the switch.
struct TabEngineSection: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab

    /// What switching does, or why the tab uses a temporary engine. WebKit gives the app no public way to let a page show notifications: a page's request is refused without asking the app, so Arch cannot tell whether a page asked, and a WebKit tab's note always says so.
    private var note: String {
        let switching = TemporaryEngineLabel.explanation(for: tab) ?? "Switching loads the page again in the other engine."
        return tab.engineKind == .webKit ? switching + " Websites can\u{2019}t show notifications in WebKit tabs." : switching
    }

    var body: some View {
        SiteSettingsGroup("This Tab", footnote: note) {
            SiteSettingsRow(symbol: "gearshape.2", title: "Engine") {
                Picker("Engine for This Tab", selection: Binding(get: { tab.engineKind }, set: { session.switchEngine(of: tab, to: $0) })) {
                    ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if tab.preferredEngine != tab.engineKind {
                SiteSettingsDivider()
                SiteSettingsRow(symbol: "checkmark.circle", title: "Keep Using \(tab.engineKind.displayName)", action: {
                    session.switchEngine(of: tab, to: tab.engineKind)
                })
            }
            PageAISiteRow(tab: tab)
        }
    }
}
