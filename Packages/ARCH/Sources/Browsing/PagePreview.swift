// Peek reuses the preview panel for links and favorites. Its page belongs to no tab until promoted.
// Open as Tab and Open in New Window transfer the live page, including its navigation and form state.
import AppKit
import ARCHEngine
import QuartzCore
import SwiftUI

/// Automatic Peek applies to confirmed links leaving a pinned tab or favorite, and links opening another tab. Explicit Peek does not depend on the setting.
enum PeekPolicy {
    static let automaticPeekKey = "ARCHAutomaticPeek"
    static let automaticPeekByDefault = true
    static var automaticallyPeeks: Bool {
        UserDefaults.standard.object(forKey: automaticPeekKey) as? Bool ?? automaticPeekByDefault
    }

    static func shouldPeek(from source: URL?, to destination: URL?, isPinnedOrFavorite: Bool,
                           disposition: EngineNavigationDisposition, isUserInitiatedLink: Bool, enabled: Bool) -> Bool {
        guard enabled, isPinnedOrFavorite, isUserInitiatedLink,
              disposition == .currentTab || disposition == .newForegroundTab || disposition == .newBackgroundTab,
              let source, let destination, let sourceHost = host(of: source), let destinationHost = host(of: destination) else { return false }
        return disposition != .currentTab || sourceHost != destinationHost
    }

    private static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")), !host.isEmpty else { return nil }
        return host
    }
}

/// A page in the preview panel. It reports the page's title, address, and loading state to the panel and passes the page's requests to open a tab, to use a permission, or to close on to its window. Dialogs and sign-in requests get the engine protocol's safe answers, so a preview asks the user nothing, and downloads are refused.
final class PagePreview: ObservableObject {
    let webContents: any EngineWebContents
    /// The Persona whose profile the page uses, as the tab or favorite it came from does.
    let personaID: Persona.ID
    /// The engine to request when the preview opens as a tab, even if its Persona is using a fallback.
    let requestedEngine: EngineKind
    /// The address the preview opened with, which it keeps across navigation.
    let openedURL: URL
    /// A native link opening keeps its opener when the user promotes it to a tab.
    weak var opener: (any EngineWebContents)?
    /// Captured at the opening request, in the window's coordinates; presentation converts it into its own view.
    var presentationSourceRectInWindow: CGRect?
    private(set) var presentationSourceImage: NSImage?
    @Published private(set) var isPresentationReady = true
    var presentationDidBecomeReady: (() -> Void)?
    private var presentationPreparationID: UUID?
    private var presentationPreparationDeadline: DispatchWorkItem?
    @Published private(set) var title = ""
    /// The page's address, which follows the page as the user moves around in it.
    @Published private(set) var url: URL
    @Published private(set) var isLoading: Bool
    /// The window that shows the preview sets this callback to open a page that the previewed page opens, such as a link to a new window, as a tab. The previewed page becomes a tab as well, which then reports to the tab instead.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// The window that shows the preview sets this callback to answer the page's permission requests. Without it every request is denied.
    var requestPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// The window that shows the preview sets this callback to close the panel when the page closes itself.
    var didClose: (() -> Void)?

    init(webContents: any EngineWebContents, personaID: Persona.ID, requestedEngine: EngineKind, openedURL: URL) {
        self.webContents = webContents
        self.personaID = personaID
        self.requestedEngine = requestedEngine
        self.openedURL = openedURL
        title = webContents.title
        url = webContents.url ?? openedURL
        isLoading = webContents.isLoading
        webContents.uiDelegate = self
    }

    /// The site as the address pill names it.
    var host: String { AddressPillView.siteName(of: url) }
}

extension PagePreview {
    /// Immutable geometry from the opening request. The source page is borrowed only for a read-only image.
    @MainActor struct PresentationSource {
        weak var tab: Tab?
        weak var page: (any EngineWebContents)?
        weak var window: NSWindow?
        let documentID: UUID
        let sourceURL: URL
        let bounds: CGRect
        let frameInWindow: CGRect
        let pointFromTopLeft: CGPoint
        let zoom: Double

        init?(tab: Tab, window: NSWindow, point: CGPoint) {
            let page = tab.webContents
            let view = page.view
            let local = view.convert(point, from: nil)
            guard !tab.isPrivate, view.window === window, !view.bounds.isEmpty,
                  view.bounds.contains(local), let url = page.url,
                  page.zoomFactor.isFinite, page.zoomFactor > 0 else { return nil }
            self.tab = tab
            self.page = page
            self.window = window
            documentID = tab.documentID
            sourceURL = url
            bounds = view.bounds
            frameInWindow = view.convert(view.bounds, to: nil)
            pointFromTopLeft = CGPoint(x: local.x - view.bounds.minX,
                                      y: view.isFlipped ? local.y - view.bounds.minY : view.bounds.maxY - local.y)
            zoom = page.zoomFactor
        }

        var isCurrent: Bool {
            guard let tab, let page, let window else { return false }
            return tab.documentID == documentID && tab.webContents === page && page.url == sourceURL
                && page.view.window === window && page.view.bounds == bounds && page.zoomFactor == zoom
                && page.view.convert(bounds, to: nil) == frameInWindow
        }
    }

    /// The page loads immediately; only its opening presentation waits for an eligible link image.
    @MainActor func preparePresentation(from source: PresentationSource, whileValid: @escaping () -> Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let page = source.page, source.isCurrent,
              let encoded = try? JSONSerialization.data(withJSONObject: [openedURL.absoluteString, source.sourceURL.absoluteString]),
              let addresses = String(data: encoded, encoding: .utf8) else { return }
        let id = UUID()
        presentationPreparationID = id
        isPresentationReady = false
        // An unresponsive renderer must not hold the UI indefinitely. This is an app preparation budget.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.presentationPreparationID == id else { return }
            self.finishPresentationPreparation(id: id)
        }
        presentationPreparationDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: deadline)
        let script = """
        () => {
          const addresses = \(addresses);
          if (new URL(location.href).href !== new URL(addresses[1]).href) return null;
          const viewport = window.visualViewport;
          const scale = \(source.zoom) * (viewport ? viewport.scale : 1);
          const left = viewport ? viewport.offsetLeft : 0, top = viewport ? viewport.offsetTop : 0;
          const x = \(source.pointFromTopLeft.x) / scale + left;
          const y = \(source.pointFromTopLeft.y) / scale + top;
          const hit = document.elementFromPoint(x, y);
          const link = hit && hit.closest('a[href]');
          if (!link || new URL(link.href, document.baseURI).href !== new URL(addresses[0]).href) return null;
          const rect = Array.from(link.getClientRects()).find(r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom);
          if (!rect || rect.width <= 0 || rect.height <= 0) return null;
          return JSON.stringify({ x: (rect.left - left) * scale, y: (rect.top - top) * scale,
                                  width: rect.width * scale, height: rect.height * scale });
        }
        """
        page.executeJavaScriptWithoutUserGesture(script, inWorld: "ARCHPeekPresentation") { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.presentationPreparationID == id else { return }
                guard whileValid(), source.isCurrent, case .success(let json?) = result,
                      let data = json.data(using: .utf8), let rect = try? JSONDecoder().decode(SourceRect.self, from: data),
                      let clipped = rect.visible(in: source.bounds.size), let page = source.page else {
                    self.finishPresentationPreparation(id: id)
                    return
                }
                WindowSnapshot.capture(page.view) { [weak self] image in
                    DispatchQueue.main.async {
                        guard let self, self.presentationPreparationID == id else { return }
                        guard whileValid(), source.isCurrent, let image,
                              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                            self.finishPresentationPreparation(id: id)
                            return
                        }
                        let pixelRect = CGRect(x: clipped.minX * CGFloat(pixels.width) / source.bounds.width,
                                               y: clipped.minY * CGFloat(pixels.height) / source.bounds.height,
                                               width: clipped.width * CGFloat(pixels.width) / source.bounds.width,
                                               height: clipped.height * CGFloat(pixels.height) / source.bounds.height)
                        guard let crop = pixels.cropping(to: pixelRect) else {
                            self.finishPresentationPreparation(id: id)
                            return
                        }
                        let frame = source.frameInWindow
                        self.presentationSourceRectInWindow = CGRect(x: frame.minX + clipped.minX * frame.width / source.bounds.width,
                                                                     y: frame.maxY - clipped.maxY * frame.height / source.bounds.height,
                                                                     width: clipped.width * frame.width / source.bounds.width,
                                                                     height: clipped.height * frame.height / source.bounds.height)
                        self.presentationSourceImage = NSImage(cgImage: crop, size: clipped.size)
                        self.finishPresentationPreparation(id: id)
                    }
                }
            }
        }
    }

    @MainActor private func finishPresentationPreparation(id: UUID) {
        guard presentationPreparationID == id else { return }
        cancelPresentationPreparation()
        isPresentationReady = true
        presentationDidBecomeReady?()
    }

    @MainActor func cancelPresentationPreparation() {
        presentationPreparationDeadline?.cancel()
        presentationPreparationDeadline = nil
        presentationPreparationID = nil
    }

    private struct SourceRect: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        func visible(in size: CGSize) -> CGRect? {
            guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
            let result = CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(origin: .zero, size: size))
            return result.isNull || result.isEmpty ? nil : result
        }
    }
}

extension PagePreview: EngineWebContentsUIDelegate {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents) { title = webContents.title }
    func webContentsDidChangeURL(_ webContents: any EngineWebContents) {
        if let url = webContents.url { self.url = url }
    }
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) { isLoading = webContents.isLoading }
    func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition, isUserInitiatedLink: Bool = false) {
        openNewTab?(newWebContents)
    }
    func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) {
        guard let requestPermission else { return completion(false) }
        requestPermission(request, completion)
    }
    /// A preview's page does not download. Dismissal closes it after the panel fades; once a tab takes the page, the tab decides.
    func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool { false }
    /// Places the items the engine hands as a tab's menu places them, in the order of WebKit's own menu. The tab's own items, which open tabs, ask about the selection, or move in the tab's history, and the plugins' items, stay out, as a preview belongs to no tab.
    func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
        let handed = PageContextMenuSections(takingItemsOf: menu, for: element)
        PageContextMenuSections.show([handed.suggestions, handed.spelling, handed.media, handed.lookUp, handed.editing, handed.fieldSubmenus, handed.share], in: menu)
    }
}

// MARK: Panel

/// Presentation stays separate from the page's lifetime so a closing page remains visible through its fade.
struct PagePreviewOverlay: View {
    static let fadeDuration = 0.3
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let preview: PagePreview

    var body: some View {
        ZStack {
            PageFrameShape().fill(Color.clear)
                .contentShape(PageFrameShape())
                .onTapGesture { windowModel.dismissPreview() }
            PagePreviewPanel(preview: preview)
        }
    }
}

/// A page card with its controls outside the page, leaving the page's viewport uninterrupted.
struct PagePreviewPanel: View {
    static let widthFraction: CGFloat = 0.8
    static let verticalInset: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    private static let controlSize: CGFloat = 33
    private static let controlGap: CGFloat = 13
    private static let closingResponse = 0.225
    private static let closingDamping = 0.895
    /// Retain the live page until its presentation has settled.
    static let dismissalDuration: TimeInterval = {
        let spring = CASpringAnimation(keyPath: "transform")
        let frequency = 2 * Double.pi / closingResponse
        spring.mass = 1
        spring.stiffness = frequency * frequency
        spring.damping = 2 * closingDamping * frequency
        return max(PagePreviewOverlay.fadeDuration, spring.settlingDuration)
    }()

    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spaceTheme) private var theme
    @ObservedObject var preview: PagePreview
    @State private var sourceRectInPanel: CGRect?
    @State private var appeared = false
    @State private var menuAnchor = PreviewMenuAnchor()

    private var isExpanded: Bool { appeared && !windowModel.isPreviewDismissing }

    private var motion: Animation? {
        guard !reduceMotion else { return nil }
        guard preview.presentationSourceRectInWindow != nil else { return .easeOut(duration: PagePreviewOverlay.fadeDuration) }
        return .spring(response: windowModel.isPreviewDismissing ? Self.closingResponse : 0.245,
                       dampingFraction: windowModel.isPreviewDismissing ? Self.closingDamping : 0.865,
                       blendDuration: 0)
    }

    private var snapshotMotion: Animation? {
        guard !reduceMotion else { return nil }
        let closing = windowModel.isPreviewDismissing
        return .spring(response: closing ? Self.closingResponse * 0.65 : 0.245 * 0.5,
                       dampingFraction: 0.95, blendDuration: 0)
            .delay(closing ? Self.closingResponse * 0.35 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the card centered and the close control reachable even in a narrow small window.
            let railWidth = Self.controlSize + Self.controlGap
            let cardWidth = max(0, min(geometry.size.width * Self.widthFraction, geometry.size.width - railWidth * 2))
            let cardHeight = max(0, geometry.size.height - Self.verticalInset * 2)
            // A fallback opens from the pointer, then closes into the center of the page area.
            // A captured link keeps its original rectangle for the reverse image transition.
            let centersFallback = windowModel.isPreviewDismissing && preview.presentationSourceImage == nil && sourceRectInPanel != nil
            let source = centersFallback
                ? CGRect(x: cardWidth / 2 - 40, y: cardHeight / 2 - 20, width: 80, height: 40)
                : sourceRectInPanel
            let scale = isExpanded || reduceMotion ? 1 : (source?.width ?? cardWidth) / max(1, cardWidth)
            let presentationHeight = isExpanded || reduceMotion ? cardHeight : cardWidth * (source.map { $0.height / max(1, $0.width) } ?? cardHeight / max(1, cardWidth))
            let radius = isExpanded || reduceMotion ? Self.cornerRadius : 0
            let offset = isExpanded || reduceMotion ? CGSize.zero : CGSize(width: (source?.midX ?? cardWidth / 2) - cardWidth / 2,
                                                                          height: (source?.midY ?? presentationHeight / 2) - presentationHeight / 2)
            HStack(alignment: .top, spacing: Self.controlGap) {
                WebContentsHostView(contentView: preview.webContents.view, cornerRadius: 0,
                                    hidesPageFromAccessibility: !preview.isPresentationReady || windowModel.isPreviewDismissing)
                    .frame(width: cardWidth, height: cardHeight)
                    .overlay(alignment: .topLeading) {
                        if let image = preview.presentationSourceImage {
                            PreviewSourceSnapshot(image: image)
                                .opacity(isExpanded || reduceMotion ? 0 : 1)
                                .animation(snapshotMotion, value: isExpanded)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: presentationHeight, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.black.opacity(isExpanded ? 0.25 : 0), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(isExpanded ? 0.3 : 0), radius: 4, y: 1)
                    .allowsHitTesting(preview.isPresentationReady && !windowModel.isPreviewDismissing)
                controls
                    .frame(width: Self.controlSize)
            }
            .frame(width: cardWidth + railWidth, height: presentationHeight, alignment: .top)
            // Transform the presentation without resizing the live page's viewport.
            .scaleEffect(scale, anchor: UnitPoint(x: cardWidth / max(1, (cardWidth + railWidth) * 2), y: 0.5))
            .offset(offset)
            .frame(width: cardWidth + railWidth, height: cardHeight, alignment: .top)
            .overlay(alignment: .topLeading) {
                PeekLoadingIndicator(isLoading: preview.isLoading)
                    .frame(width: 128, height: 4)
                    .offset(x: cardWidth / 2 - 64, y: -(Self.verticalInset + 4) / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(preview.isPresentationReady && (sourceRectInPanel != nil || preview.presentationSourceRectInWindow == nil)
                     && (isExpanded || preview.presentationSourceImage != nil) ? 1 : 0)
            .animation(motion, value: isExpanded)
            // The dismissal boundary includes the rail, so its buttons do not count as outside clicks.
            .background(PreviewDismissal(close: windowModel.dismissPreview,
                                         ignoresEscape: { windowModel.isTabSwitcherVisible },
                                         cardTrailingInset: railWidth,
                                         controlsSize: CGSize(width: Self.controlSize, height: Self.controlSize * 3 + 20),
                                         blocksContent: { !preview.isPresentationReady || windowModel.isPreviewDismissing },
                                         sourceRectInWindow: preview.presentationSourceRectInWindow,
                                         sourceGeometryReady: preview.isPresentationReady,
                                         sourceGeometryChanged: receiveSourceRect))
            .position(x: (geometry.size.width + railWidth) / 2, y: geometry.size.height / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Peek"))
        .accessibilityHidden(!preview.isPresentationReady || windowModel.isPreviewDismissing)
        .onAppear {
            if preview.isPresentationReady && preview.presentationSourceRectInWindow == nil { appeared = true }
            windowModel.focusPage()
        }
    }

    private func receiveSourceRect(_ rect: CGRect) {
        guard preview.isPresentationReady else { return }
        sourceRectInPanel = rect
        if !appeared {
            DispatchQueue.main.async {
                guard preview.isPresentationReady else { return }
                appeared = true
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            control(symbol: "xmark", label: localized("Close Preview"), action: windowModel.dismissPreview)
            control(symbol: "arrow.up.left.and.arrow.down.right", label: localized("Open as Tab"), action: windowModel.openPreviewInTab)
            Button {
                guard windowModel.preview === preview, preview.isPresentationReady, !windowModel.isPreviewDismissing else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(EngineActionMenuItem(localized("Open in New Window")) {
                    guard windowModel.preview === preview, !windowModel.isPreviewDismissing else { return }
                    windowModel.openPreviewInNewWindow()
                })
                menu.addItem(EngineActionMenuItem(localized("Copy Link")) {
                    guard windowModel.preview === preview, !windowModel.isPreviewDismissing else { return }
                    Tab.copyToPasteboard(preview.url)
                })
                menuAnchor.show(menu)
            } label: {
                controlSymbol("ellipsis")
            }
            .buttonStyle(PreviewControlStyle())
            .background(PreviewMenuAnchorView(anchor: menuAnchor))
            .help(localized("Peek Actions"))
            .accessibilityLabel(localized("Peek Actions"))
        }
        .disabled(!preview.isPresentationReady || windowModel.isPreviewDismissing)
    }

    private func control(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlSymbol(symbol) }
            .buttonStyle(PreviewControlStyle())
            .help(label)
            .accessibilityLabel(label)
    }

    @ViewBuilder private func controlSymbol(_ symbol: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 17, height: 17)
            .padding(8)
        if symbol == "xmark" {
            if #available(macOS 26.0, *) {
                image.glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            } else {
                image.background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
        } else {
            image
                .background(Capsule(style: .continuous).fill(controlFill))
                .contentShape(Capsule(style: .continuous))
        }
    }

    /// Keep the hue of the space while deriving an opaque, contrasting control surface.
    private var controlFill: Color {
        var color = SRGBColor(NSColor(theme.tint), in: theme.colorScheme)
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        var lightness = (maximum + minimum) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue: Double = 0
        if delta > 0 {
            if maximum == color.red { hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == color.green { hue = (color.blue - color.red) / delta + 2 }
            else { hue = (color.red - color.green) / delta + 4 }
            if hue < 0 { hue += 6 }
        }
        func luminance(_ value: SRGBColor) -> Double {
            func linear(_ component: Double) -> Double {
                component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
        }
        for _ in 0..<100 where luminance(color) > 0.1 {
            lightness = max(0, lightness - 0.01)
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let component = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
            let base = lightness - chroma / 2
            let channels: (Double, Double, Double)
            switch Int(hue) {
            case 0: channels = (chroma, component, 0)
            case 1: channels = (component, chroma, 0)
            case 2: channels = (0, chroma, component)
            case 3: channels = (0, component, chroma)
            case 4: channels = (component, 0, chroma)
            default: channels = (chroma, 0, component)
            }
            color = SRGBColor(red: channels.0 + base, green: channels.1 + base, blue: channels.2 + base, alpha: color.alpha)
        }
        return color.over(theme.colorScheme == .dark ? .black : .white,
                          opacity: theme.colorScheme == .dark ? 0.15 : 0.01).color
    }
}

/// Hover and press feedback belongs to the control; it never changes the page's layout.
private struct PreviewControlStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PreviewControlFeedback(isHovered: isHovered, isPressed: configuration.isPressed))
            .onHover { isHovered = $0 }
    }
}

private struct PreviewControlFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isHovered: Bool
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.2),
                    radius: isHovered && !isPressed ? 6 : 4, y: 1)
            .offset(y: isHovered && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.15, dampingFraction: 0.95, blendDuration: 0), value: isHovered)
            .scaleEffect(isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.63, blendDuration: 0), value: isPressed)
    }
}

/// The whole control opens the native menu, independent of a popup button's intrinsic height.
@MainActor private final class PreviewMenuAnchor {
    weak var view: NSView?

    func show(_ menu: NSMenu) {
        guard let view, view.window != nil else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: view.bounds.minX, y: view.bounds.minY), in: view)
    }
}

private struct PreviewMenuAnchorView: NSViewRepresentable {
    let anchor: PreviewMenuAnchor

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { anchor.view = view }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Preserve the source image's aspect while its lower edge fills the expanding card.
private struct PreviewSourceSnapshot: View {
    let image: NSImage
    private let bottomMargin: CGFloat
    private let repeatedStrip: NSImage?
    private let bottomEdge: NSImage?

    init(image: NSImage) {
        self.image = image
        let height = image.size.height
        let margin: CGFloat = height < 40 ? 0 : height < 100 ? 2 : height < 200 ? 6 : height < 300 ? 10 : 12
        bottomMargin = margin
        guard margin > 0, let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            repeatedStrip = nil
            bottomEdge = nil
            return
        }
        let pixelScale = CGFloat(pixels.height) / max(1, height)
        let strip = pixels.cropping(to: CGRect(x: 0, y: (height - margin - 1) * pixelScale,
                                               width: CGFloat(pixels.width), height: pixelScale))
        let edge = pixels.cropping(to: CGRect(x: 0, y: (height - margin - 1) * pixelScale,
                                              width: CGFloat(pixels.width), height: (margin + 1) * pixelScale))
        repeatedStrip = strip.map { NSImage(cgImage: $0, size: CGSize(width: image.size.width, height: 1)) }
        bottomEdge = edge.map { NSImage(cgImage: $0, size: CGSize(width: image.size.width, height: margin + 1)) }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(1, image.size.width)
            let naturalHeight = image.size.height * scale
            ZStack(alignment: .topLeading) {
                if bottomMargin == 0 {
                    Color.white
                }
                if let bottomEdge {
                    Image(nsImage: bottomEdge).resizable()
                        .frame(width: geometry.size.width, height: bottomEdge.size.height * scale)
                        .offset(y: geometry.size.height - bottomEdge.size.height * scale)
                }
                if let repeatedStrip {
                    Image(nsImage: repeatedStrip).resizable()
                        .frame(width: geometry.size.width, height: max(0, geometry.size.height - naturalHeight))
                        .offset(y: naturalHeight - bottomMargin * scale)
                }
                Image(nsImage: image).resizable()
                    .frame(width: geometry.size.width, height: naturalHeight)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

/// Closes the preview on Escape or a click outside the panel. The dismissal click is consumed so the covered page cannot act on it. App fields retain Escape, and clicks in other windows leave the panel open.
struct PreviewDismissal: NSViewRepresentable {
    let close: () -> Void
    /// Whether something above the panel that has no field, such as the tab switcher, takes Escape first.
    let ignoresEscape: () -> Bool
    /// A detached control rail leaves backdrop between and below its controls.
    var cardTrailingInset: CGFloat = 0
    var controlsSize: CGSize = .zero
    var blocksContent: () -> Bool = { false }
    var sourceRectInWindow: CGRect?
    var sourceGeometryReady = true
    var sourceGeometryChanged: ((CGRect) -> Void)?

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.close = close
        view.ignoresEscape = ignoresEscape
        view.cardTrailingInset = cardTrailingInset
        view.controlsSize = controlsSize
        view.blocksContent = blocksContent
        view.sourceRectInWindow = sourceRectInWindow
        view.sourceGeometryReady = sourceGeometryReady
        view.sourceGeometryChanged = sourceGeometryChanged
        view.reportSourceGeometry()
    }

    /// Watches the app's keys and clicks while the panel is in a window. It lies behind the panel with the panel's frame and takes no clicks itself.
    final class MonitorView: NSView {
        var close: (() -> Void)?
        var ignoresEscape: (() -> Bool)?
        var cardTrailingInset: CGFloat = 0
        var controlsSize: CGSize = .zero
        var blocksContent: () -> Bool = { false }
        var sourceRectInWindow: CGRect?
        var sourceGeometryReady = true
        var sourceGeometryChanged: ((CGRect) -> Void)?
        private var reportedSourceRect: CGRect?
        private var reportedSourceReady: Bool?
        override var isFlipped: Bool { true }
        private var monitors: [Any] = []

        // A window that closes releases its views without moving them out of it first.
        deinit {
            monitors.forEach(NSEvent.removeMonitor)
        }

        // The monitors run before the focused view, so Escape closes the panel even while the previewed page has focus.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportSourceGeometry()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            guard window != nil else { return }
            let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.closesOnEscape(event) else { return event }
                self.close?()
                return nil
            }
            let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                if let self, self.closesOnClick(event) {
                    self.close?()
                    return nil
                }
                return event
            }
            monitors = [escape, click].compactMap { $0 }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            reportSourceGeometry()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportSourceGeometry()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            reportSourceGeometry()
        }

        func reportSourceGeometry() {
            guard window != nil, !bounds.isEmpty, let sourceRectInWindow else { return }
            let rect = convert(sourceRectInWindow, from: nil)
            let ready = sourceGeometryReady
            guard rect != reportedSourceRect || ready != reportedSourceReady else { return }
            reportedSourceRect = rect
            reportedSourceReady = ready
            // Layout can occur inside SwiftUI's update; deliver the converted coordinates afterward.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.reportedSourceRect == rect, self.reportedSourceReady == ready else { return }
                self.sourceGeometryChanged?(rect)
            }
        }

        func closesOnEscape(_ event: NSEvent) -> Bool {
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let window, event.window === window else { return false }
            let responder = window.firstResponder
            return !(responder is NSText) && (responder as? NSTextInputClient)?.hasMarkedText() != true && ignoresEscape?() != true
        }

        func closesOnClick(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if blocksContent() { return true }
            let point = convert(event.locationInWindow, from: nil)
            let card = CGRect(x: 0, y: 0, width: max(0, bounds.width - cardTrailingInset), height: bounds.height)
            let controls = CGRect(x: bounds.width - controlsSize.width, y: 0, width: controlsSize.width, height: controlsSize.height)
            return !card.contains(point) && !controls.contains(point)
        }
    }
}

// MARK: Shift and hover

/// Runs `preview` once the pointer has rested on the view for a moment with Shift alone held, whichever began first.
struct ShiftHoverPreview: ViewModifier {
    let preview: () -> Void
    @StateObject private var shiftKey = ShiftHoverMonitor()

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isHovering { shiftKey.start(preview) } else { shiftKey.stop() }
            }
            // Hiding the sidebar or the card removes the view without ending its hover.
            .onDisappear { shiftKey.stop() }
    }
}

/// Watches the keys while the pointer is over one view and runs its preview once Shift alone has stayed down for `restDuration` with no other key pressed. The app sees key changes only while it is active.
final class ShiftHoverMonitor: ObservableObject {
    /// Passing over a view with Shift held, or pressing a shortcut that starts with Shift, opens no preview.
    static let restDuration = 0.25
    private var monitor: Any?
    private var preview: (() -> Void)?
    private var pendingPreview: DispatchWorkItem?

    func start(_ preview: @escaping () -> Void) {
        stop()
        self.preview = preview
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // A key typed with Shift down, as for a capital letter, ends the wait until Shift is pressed again.
            if event.type == .keyDown { self?.cancelPendingPreview() } else { self?.modifiersDidChange(event.modifierFlags) }
            return event
        }
        modifiersDidChange(NSEvent.modifierFlags)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        preview = nil
        cancelPendingPreview()
    }

    deinit {
        stop()
    }

    private func cancelPendingPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
    }

    /// Each change starts the wait again; any other modifier ends it.
    private func modifiersDidChange(_ flags: NSEvent.ModifierFlags) {
        cancelPendingPreview()
        guard Self.isShiftAlone(flags), let preview else { return }
        let work = DispatchWorkItem {
            guard NSApp.isActive, Self.isShiftAlone(NSEvent.modifierFlags) else { return }
            preview()
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDuration, execute: work)
    }

    /// Caps Lock and the like do not count.
    private static func isShiftAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control, .function]) == .shift
    }
}
