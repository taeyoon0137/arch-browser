import SwiftUI

/// Link-opening controls shared with Settings, using Browsing's string catalog.
public struct LinkOpeningSettings: View {
    @AppStorage(PeekPolicy.automaticPeekKey) private var automaticPeek = PeekPolicy.automaticPeekByDefault
    @State private var sites = RegularWindowSites()
    @State private var site = ""

    public init() {}

    public var body: some View {
        Section {
            Toggle(localized("Automatically open links from pinned tabs and favorites in Peek"), isOn: $automaticPeek)
        }
        Section {
            ForEach(sites.hosts, id: \.self) { host in
                HStack {
                    Text(verbatim: host)
                    Spacer()
                    Button {
                        sites.remove(host)
                        sites.save()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(localized("Remove"))
                    .accessibilityLabel(String(format: localized("Remove %@"), host))
                }
            }
            HStack {
                TextField(localized("Site or URL"), text: $site)
                    .onSubmit(addSite)
                Button(localized("Add"), action: addSite)
                    .disabled(!canAdd)
            }
        } header: {
            Text(localized("Open in a Regular Window"))
        } footer: {
            Text(localized("Links from other apps open in a regular window for these sites and their subdomains."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            sites = RegularWindowSites()
        }
    }

    private var canAdd: Bool {
        guard let host = RegularWindowSites.host(parsing: site) else { return false }
        return !sites.hosts.contains(host)
    }

    private func addSite() {
        guard sites.add(site) else { return }
        sites.save()
        site = ""
    }
}
