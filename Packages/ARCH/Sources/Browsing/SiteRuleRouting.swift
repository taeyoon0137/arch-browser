import ARCHEngine
import Foundation
import SwiftUI

/// A decision made before an opening creates its first page.
struct SiteRuleDestination {
    let rule: SiteRule
    let space: Space
    let originSpaceID: UUID
    let originPersonaID: UUID
}

struct SiteRuleToast: Identifiable {
    let id = UUID()
    let tabID: UUID
    let originWindowID: UUID
    let originSpaceID: UUID
    let originPersonaID: UUID
    let message: String
    let expiresAt: Date
}

extension BrowserSession {
    public var siteRuleDestinations: [Space] { spaces.filter { $0.resolvedPersonaID != agentOnlyPersonaID } }

    public func siteRule(for url: URL) -> SiteRule? { SiteRuleSet.match(url: url, rules: siteRules.rules) }

    public func siteRuleDestination(_ rule: SiteRule) -> Space? {
        guard personas.contains(where: { $0.id == rule.personaID }), rule.personaID != agentOnlyPersonaID else { return nil }
        return spaces.first { $0.id == rule.spaceID && $0.resolvedPersonaID == rule.personaID }
            ?? preferredSpace(in: rule.personaID)
    }

    public func setSiteRule(for url: URL, destination: Space?) throws {
        guard let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let site = try SiteRuleSite(host: host, pathPrefix: "")
        let existing = siteRules.rules.first { $0.host == site.host && $0.pathPrefix.isEmpty }
        guard let destination else {
            if let matching = siteRule(for: url), !siteRules.remove(id: matching.id) { throw CocoaError(.fileWriteUnknown) }
            return
        }
        guard siteRuleDestinations.contains(where: { $0.id == destination.id }) else { return }
        try siteRules.save(SiteRule(id: existing?.id ?? UUID(), host: site.host, spaceID: destination.id,
                                   personaID: destination.resolvedPersonaID, window: existing?.window ?? .space))
    }

    func destination(forOpening origin: Space, url: URL) -> SiteRuleDestination? {
        guard origin.resolvedPersonaID != agentOnlyPersonaID, let rule = siteRule(for: url),
              let space = siteRuleDestination(rule), space.id != origin.id else { return nil }
        return SiteRuleDestination(rule: rule, space: space, originSpaceID: origin.id, originPersonaID: origin.resolvedPersonaID)
    }

    /// Only outside links use this entry point. Bookmarks, restored tabs and code keep `openTab`.
    @discardableResult public func openExternalTab(url: URL) -> Tab {
        let source = sidebarTarget()
        guard let destination = destination(forOpening: source.currentSpace, url: url) else { return openTab(url: url) }
        return openRoutedTab(url: url, destination: destination, source: source, background: false)
    }

    @discardableResult func openRoutedTab(url: URL, destination: SiteRuleDestination, source: BrowserWindowModel?, background: Bool,
                                        engine: EngineKind? = nil) -> Tab {
        let tab = openTab(url: url, in: destination.space.id, select: false, engine: engine ?? defaultEngine)
        finishSiteRuleOpening(tab, destination: destination, source: source, background: background)
        return tab
    }

    func finishSiteRuleOpening(_ tab: Tab, destination: SiteRuleDestination, source: BrowserWindowModel?, background: Bool) {
        guard !tab.isPrivate, source?.isPrivate != true else { return }
        var target: BrowserWindowModel?
        if background {
            tab.isUnread = true
        } else {
            if destination.rule.window == .newWindow {
                target = makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: destination.space.id,
                                               selectedTabID: nil, isSidebarVisible: true), kind: .main)
            } else {
                target = windows.first { $0.kind == .main && !$0.isPrivate && $0.currentSpaceID == destination.space.id }
                    ?? (source?.kind == .main && source?.isPrivate == false ? source : nil) ?? sidebarTarget()
            }
            target?.selectTab(tab.id)
            target?.nsWindow?.makeKeyAndOrderFront(nil)
            target?.focusPage()
        }
        showSiteRuleToast(for: tab, destination: destination, source: source, target: target)
    }

    func showSiteRuleToast(for tab: Tab, destination: SiteRuleDestination, source: BrowserWindowModel?, target: BrowserWindowModel? = nil) {
        guard !tab.isPrivate, let source = source ?? target, !source.isPrivate, target?.isPrivate != true else { return }
        let place = displayedPlace(ofPersona: destination.space.resolvedPersonaID, space: destination.space) ?? destination.space.name
        let toast = SiteRuleToast(tabID: tab.id, originWindowID: source.id, originSpaceID: destination.originSpaceID,
                                  originPersonaID: destination.originPersonaID, message: localized("Opened in \(place)"),
                                  expiresAt: Date().addingTimeInterval(5))
        source.showSiteRuleToast(toast)
        if let target, target !== source { target.showSiteRuleToast(toast) }
    }

    func undoSiteRuleOpening(_ toast: SiteRuleToast, from window: BrowserWindowModel, now: Date = Date()) {
        guard !window.isPrivate else { return }
        for other in windows where other.siteRuleToast?.id == toast.id { other.siteRuleToast = nil }
        guard now < toast.expiresAt,
              let origin = spaces.first(where: { $0.id == toast.originSpaceID && $0.resolvedPersonaID == toast.originPersonaID }),
              let tab = tabs.first(where: { $0.id == toast.tabID }), !tab.isPrivate, tab.agentOwnerID == nil else { return }
        let source = windows.first { $0.id == toast.originWindowID && $0.kind == .main && !$0.isPrivate }
            ?? (window.kind == .main ? window : nil) ?? sidebarTarget()
        // Small-window tabs must join the sidebar before the existing move can carry them.
        tab.isInSmallWindow = false
        if tab.spaceID == origin.id {
            source.selectTab(tab.id)
        } else {
            moveTab(tab.id, toSpace: origin.id, windowsFollow: false, activating: source)
        }
        source.nsWindow?.makeKeyAndOrderFront(nil)
        source.focusPage()
    }
}

extension BrowserWindowModel {
    func showSiteRuleToast(_ toast: SiteRuleToast) {
        guard !isPrivate else { return }
        withAnimation(.easeInOut(duration: 0.2)) { siteRuleToast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, toast.expiresAt.timeIntervalSinceNow)) { [weak self] in
            guard let self, siteRuleToast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.siteRuleToast = nil }
        }
    }

    func siteRuleHint(for input: String) -> String? {
        guard !isPrivate else { return nil }
        guard let url = BrowserSession.destination(forInput: input, siteSearch: session.siteSearch),
              let destination = session.destination(forOpening: currentSpace, url: url) else { return nil }
        let place = session.displayedPlace(ofPersona: destination.space.resolvedPersonaID, space: destination.space) ?? destination.space.name
        return localized("Opens in \(place)")
    }
}

/// A short notice uses the sidebar's row text and material, without covering the page's controls.
struct SiteRuleToastView: View {
    @ObservedObject var window: BrowserWindowModel

    var body: some View {
        if let toast = window.siteRuleToast {
            HStack(spacing: 12) {
                Text(toast.message).foregroundStyle(.primary)
                Button(localized("Undo")) { window.session.undoSiteRuleOpening(toast, from: window) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .transition(.opacity)
        }
    }
}
