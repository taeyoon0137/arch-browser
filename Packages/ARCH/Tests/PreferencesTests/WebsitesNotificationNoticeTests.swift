// When Settings ▸ Websites tells the user about Arch's notification permission: only while a website may send notifications, with System Settings while the permission is off and Arch's own request while macOS has not asked.
import Browsing
import Testing
@testable import Preferences

@Suite struct WebsitesNotificationNoticeTests {
    @Test func theNoticeShowsOnlyWhileAnAllowedWebsiteCannotShowNotifications() {
        #expect(WebsitesSection.notificationNotice(for: .denied, hasAllowedSite: true) == .openSystemSettings)
        #expect(WebsitesSection.notificationNotice(for: .notDetermined, hasAllowedSite: true) == .turnOn)
        #expect(WebsitesSection.notificationNotice(for: .allowed, hasAllowedSite: true) == nil)
        #expect(WebsitesSection.notificationNotice(for: .unavailable, hasAllowedSite: true) == nil)
        #expect(WebsitesSection.notificationNotice(for: .denied, hasAllowedSite: false) == nil)
        #expect(WebsitesSection.notificationNotice(for: .notDetermined, hasAllowedSite: false) == nil)
    }
}
