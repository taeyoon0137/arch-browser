// The exact address the user reviewed in the session panel and the source that made it eligible.
import AI
import Foundation

struct AgentResearchPage: Hashable {
    enum Source: Hashable {
        case message(UUID)
        case attachment(tab: UUID, document: UUID, handle: String)
        case outline(tab: UUID, document: UUID, address: URL, handle: String, link: AgentOutlineLink)

        var attachmentID: UUID? {
            switch self {
            case .message: return nil
            case .attachment(let id, _, _), .outline(let id, _, _, _, _): return id
            }
        }
    }

    let url: URL
    let source: Source

    var isOutlineLink: Bool {
        if case .outline = source { return true }
        return false
    }

    var outlineLabel: String? {
        guard case .outline(_, _, _, let handle, let link) = source else { return nil }
        return link.name.isEmpty ? "\(handle) [\(link.ref)]" : "\(handle) [\(link.ref)] · \(link.name)"
    }

    func matches(_ address: URL) -> Bool {
        guard let reviewed = AgentSeenAddress(url) else { return false }
        return AgentSeenAddress(address) == reviewed
    }
}

extension AgentSession {
    func researchChoices(host: any AgentBrowserHost, allowsAI: (URL) -> Bool) -> [AgentResearchPage] {
        var pages = items.flatMap { item -> [AgentResearchPage] in
            guard case .user(let text) = item.kind else { return [] }
            return AgentSiteScope.addresses(in: text).map { AgentResearchPage(url: $0, source: .message(item.id)) }
        }
        for tab in host.userTabs(in: personaID) where handles.sharedTabIDs.contains(tab.id) && tab.canAttachToSession(allowsAI: allowsAI) {
            if let url = tab.url {
                pages.append(AgentResearchPage(url: url, source: .attachment(tab: tab.id, document: tab.documentID, handle: handles.tabs.handle(for: tab.id))))
            }
        }
        var seen = Set<AgentSeenAddress>()
        return pages.filter { page in
            guard let address = AgentSeenAddress(page.url), permitsAddress(page.url, host: host, allowsAI: allowsAI), scope.written(page.url) == .opens else { return false }
            return seen.insert(address).inserted
        }
    }

    func outlineLinks(host: any AgentBrowserHost, allowsAI: (URL) -> Bool) -> [AgentResearchPage] {
        let tabs = host.userTabs(in: personaID)
        return handles.sharedTabIDs.flatMap { id -> [AgentResearchPage] in
            guard let tab = tabs.first(where: { $0.id == id }), tab.canAttachToSession(allowsAI: allowsAI),
                  let record = snapshots.current(tab, pages: 0) else { return [] }
            let handle = handles.tabs.handle(for: id)
            return record.displayedLinks.compactMap { link in
                guard permitsAddress(link.url, host: host, allowsAI: allowsAI) else { return nil }
                return AgentResearchPage(url: link.url, source: .outline(tab: id, document: tab.documentID, address: record.url, handle: handle, link: link))
            }
        }
    }

    func permits(_ page: AgentResearchPage, host: any AgentBrowserHost, allowsAI: (URL) -> Bool) -> Bool {
        guard permitsAddress(page.url, host: host, allowsAI: allowsAI) else { return false }
        switch page.source {
        case .message(let id):
            guard scope.written(page.url) == .opens, let item = items.first(where: { $0.id == id }), case .user(let text) = item.kind else { return false }
            return AgentSiteScope.addresses(in: text).contains(where: page.matches)
        case .outline(let id, let document, let address, let handle, let link):
            guard link.url == page.url, handles.sharedTabIDs.contains(id), handles.tabs.id(for: handle) == id else { return false }
            return host.userTabs(in: personaID).contains { tab in
                tab.id == id && tab.documentID == document && tab.url == address && tab.canAttachToSession(allowsAI: allowsAI)
            }
        case .attachment(let id, let document, let handle):
            guard scope.written(page.url) == .opens, handles.sharedTabIDs.contains(id), handles.tabs.id(for: handle) == id else { return false }
            return host.userTabs(in: personaID).contains { tab in
                tab.id == id && tab.documentID == document && tab.url == page.url && tab.canAttachToSession(allowsAI: allowsAI)
            }
        }
    }

    private func permitsAddress(_ url: URL, host: any AgentBrowserHost, allowsAI: (URL) -> Bool) -> Bool {
        guard origin == .app, !hasEnded, host.spaces(in: personaID).contains(where: { $0.id == spaceID }),
              let address = AgentSeenAddress(url), address.hasDefaultPort, url.user == nil, url.password == nil,
              !AISitePattern.localNetwork.matches(url), !address.host.hasSuffix("."), address.host.contains("."),
              let suffix = address.host.split(separator: ".").last, suffix.allSatisfy({ $0.isASCII && $0.isLetter }),
              !["internal", "lan", "home", "localdomain", "arpa"].contains(suffix),
              scope.contains(url) else { return false }
        return AgentPolicy.mayOpen(url, allowsAI: allowsAI) == .allowed
    }

    func permitsResearchTab(_ tab: AgentTabInfo, host: any AgentBrowserHost, allowsAI: (URL) -> Bool) -> Bool {
        guard let page = researchPages[tab.id] else { return true }
        return tab.spaceID == spaceID && tab.url.map(page.matches) == true && permits(page, host: host, allowsAI: allowsAI)
    }
}
