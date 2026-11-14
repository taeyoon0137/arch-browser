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
    @Environment(\.addressPillPull) private var pull
    @State private var isShowingSiteSettings = false

    private var url: URL? { tab?.url }

    /// The internal page's address, the page's site, or the placeholder with no tab open.
    private var host: String {
        if let page = windowModel.internalPage { return page.address }
        return url.map(Self.siteName(of:)) ?? "Search or enter address"
    }

    /// The page's site as the address pill and the small window show it: its host without `www.`, a local file's name, or the whole address of a page without a host, such as `about:blank`.
    static func siteName(of url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The symbol before a page's site, in the address pill and the small window: the internal page's, a search with no page, a file, or the connection, secure or not.
    static func symbol(for url: URL?, internalPage: InternalPage?) -> String {
        if internalPage != nil { return "flag" }
        guard let url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        return url.scheme == "https" ? "lock.fill" : "globe"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { windowModel.focusCommandBar(from: .addressPill) }) {
                // The symbol takes the tab rows' icon column, so the host starts where their titles do, whichever symbol shows.
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(for: url, internalPage: windowModel.internalPage))
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
            .accessibilityLabel(host)
            LowPowerModeIndicator()
            SidebarIconButton(symbol: "square.and.arrow.up", label: "Share", action: windowModel.shareSelectedPage)
                .disabled(!windowModel.canShareSelectedPage)
                .background(SiteControlAnchor(windowModel: windowModel, button: \.shareButtonView))
            SidebarIconButton(symbol: "slider.horizontal.3", label: "Site Settings") { isShowingSiteSettings.toggle() }
                .background(SiteControlAnchor(windowModel: windowModel, button: \.siteSettingsButtonView))
                .padding(.trailing, 4)
                .popover(isPresented: $isShowingSiteSettings, arrowEdge: .bottom) {
                    SiteSettingsView(session: session, tab: tab) { isShowingSiteSettings = false }
                }
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
            fatalError("AnchorView is created with its button")
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

/// The site settings popover: the engine of the current tab, the actions of its Persona's web extensions, clearing its site's data, whether AI features may send its pages, and the engine for new tabs. While an internal page or the preview panel covers the tab, it shows only the engine for new tabs, as in a window without a tab. A click closes the preview before it reaches the button, but a press through VoiceOver leaves the preview open.
struct SiteSettingsView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let tab: Tab?
    /// Closes the popover, so that it does not stay over the sheet it opens.
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tab, !windowModel.isSelectedPageCovered {
                TabEngineSection(session: session, tab: tab)
                if let webExtensions = session.webExtensions(in: tab.personaID) {
                    WebExtensionActionsSection(session: session, webExtensions: webExtensions, tab: tab, close: close)
                }
                SiteSettingsSection(title: "Site data", note: "Removes the site\u{2019}s cookies and stored data from both engines and signs you out of it.") {
                    Button("Clear Site Data\u{2026}") {
                        close()
                        windowModel.confirmClearSiteData()
                    }
                    .disabled(!windowModel.canClearSiteData)
                }
                PageAISiteSection(tab: tab)
            }
            SiteSettingsSection(title: "New tabs", note: "Tabs that a page opens use that page\u{2019}s engine.") {
                Picker("New tabs", selection: Binding(get: { session.defaultEngine }, set: { session.defaultEngine = $0 })) {
                    ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

// Observes the tab so the picker follows the switch.
struct TabEngineSection: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab

    /// WebKit gives the app no public way to let a page show notifications: a page's request is refused without asking the app, so Arch cannot tell whether a page asked, and a WebKit tab's note always says so.
    private var note: String {
        let switching = "Switching loads the page again in the other engine."
        return tab.engineKind == .webKit ? switching + " Websites can\u{2019}t show notifications in WebKit tabs." : switching
    }

    var body: some View {
        SiteSettingsSection(title: "This tab", note: note) {
            Picker("This tab", selection: Binding(get: { tab.engineKind }, set: { session.switchEngine(of: tab, to: $0) })) {
                ForEach(session.availableEngines, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }
}

struct SiteSettingsSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
                .pickerStyle(.segmented)
                .labelsHidden()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
