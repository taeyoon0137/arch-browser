// What an outside client's `task/start` becomes (docs/agents.md, arch-cli ▸ `arch-cli task`; Modes): the session's space among the grant's Persona's spaces, by name or the grant's own, its model among the models that can run a session, by name or the route's, and its mode, at the lower of the grant's level and the Settings default, which the client's mode can only lower. The client chooses nothing else: its text adds nothing to the site scope, and no tab is attached.
import AgentControl
import AI
import Foundation

struct AgentTaskPlan: Equatable {
    var spaceID: UUID
    var model: AIModelRef?
    var mode: AgentAccessLevel

    /// A sentence for the client when the task names what the grant's Persona or Settings lack.
    struct Refusal: Error, Equatable {
        var message: String
    }

    static func make(for start: AgentTaskStart, grant: AgentGrant, spaces: [AgentSpaceInfo], models: [AIModelRef], settingsDefault: AgentAccessLevel) throws -> AgentTaskPlan {
        let space: AgentSpaceInfo
        if let name = start.space {
            guard let named = spaces.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
                throw Refusal(message: "The grant's Persona has no space named \(name).")
            }
            space = named
        } else {
            guard let own = spaces.first(where: { $0.id == grant.spaceID }) ?? spaces.first else { throw Refusal(message: "The grant's Persona has no space.") }
            space = own
        }
        var model: AIModelRef?
        if let name = start.model {
            guard let named = models.first(where: { $0.model == name }) else { throw Refusal(message: "No Claude Code or Codex model is named \(name) in Settings \u{25B8} AI.") }
            model = named
        }
        return AgentTaskPlan(spaceID: space.id, model: model, mode: mode(requested: start.mode, grant: grant.level, settingsDefault: settingsDefault))
    }

    /// The client's mode can only lower the lower of the grant's level and the Settings default.
    static func mode(requested: AgentAccessLevel?, grant: AgentAccessLevel, settingsDefault: AgentAccessLevel) -> AgentAccessLevel {
        let ceiling = grant.capped(at: settingsDefault)
        return requested?.capped(at: ceiling) ?? ceiling
    }
}
