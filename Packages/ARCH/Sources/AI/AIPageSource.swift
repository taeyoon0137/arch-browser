// The pages of open tabs, as features read them for their requests. `Browsing` supplies them from the engines' readable page content, so this module depends on no engine.
import Foundation

/// Reads page content and selection from open tabs without depending on a browser engine.
public protocol AIPageSource: Sendable {
    /// The tab's readable page text, up to `limit` characters, without the values of fields or the text of editable areas.
    func content(ofTab id: UUID, limit: Int) async throws -> AIPageContent
    /// The text selected in the tab's page outside fields and editable areas, or nil without one.
    func selection(ofTab id: UUID) async throws -> AISelection?
}
