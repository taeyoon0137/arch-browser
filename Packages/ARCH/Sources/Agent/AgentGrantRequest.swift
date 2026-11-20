// The question the grant sheet asks and the user's answer (docs/agents.md, Outside clients: identity, grants, revocation), apart from the sheet, so that the service's rules run against a fake prompt in tests: which Persona, space, access, scopes, and duration, and which grants ask for Touch ID or the login password.
import AgentControl
import Foundation
import LocalAuthentication

/// What the sheet shows: the client and the Personas and spaces it may get.
public struct AgentGrantRequest: Sendable {
    public var client: AgentClientIdentity
    /// The user's own Personas, without the Agents Persona.
    public var personas: [AgentPersonaInfo]
    /// The Agents Persona's spaces while it exists; empty before Arch creates it with its first space.
    public var agentsSpaces: [AgentSpaceInfo]
    public var spacesByPersona: [UUID: [AgentSpaceInfo]]

    public init(client: AgentClientIdentity, personas: [AgentPersonaInfo], agentsSpaces: [AgentSpaceInfo], spacesByPersona: [UUID: [AgentSpaceInfo]]) {
        self.client = client
        self.personas = personas
        self.agentsSpaces = agentsSpaces
        self.spacesByPersona = spacesByPersona
    }

    /// Returns the spaces available for the chosen Persona.
    public func spaces(of persona: AgentGrantChoice.PersonaChoice) -> [AgentSpaceInfo] {
        switch persona {
        case .agents: return agentsSpaces
        case .existing(let id): return spacesByPersona[id] ?? []
        }
    }
}

/// The user's Allow, with the sheet's choices. Every field starts at the design's default.
public struct AgentGrantChoice: Equatable, Sendable {
    /// The Agents Persona or one of the user's existing Personas.
    public enum PersonaChoice: Hashable, Sendable {
        /// The Agents Persona, which Arch creates on first use.
        case agents
        /// One of the user's own Personas, whose sign-ins the client then reads with.
        case existing(UUID)
    }

    /// How long an outside client's grant remains valid.
    public enum Duration: String, CaseIterable, Sendable {
        case untilQuit
        case day
        case untilRevoked

        public var title: String {
            switch self {
            case .untilQuit: return "Until Arch Quits"
            case .day: return "For 24 Hours"
            case .untilRevoked: return "Until I Revoke It"
            }
        }

        /// Converts the selected duration into the grant's expiry rule.
        func expiry(from date: Date) -> AgentGrantExpiry {
            switch self {
            case .untilQuit: return .whenArchQuits
            case .day: return .at(date.addingTimeInterval(24 * 60 * 60))
            case .untilRevoked: return .whenRevoked
            }
        }
    }

    public var persona: PersonaChoice = .agents
    /// nil: the Persona's first space.
    public var spaceID: UUID?
    public var level: AgentAccessLevel = .readOnly
    public var scopes = AgentGrantScopes()
    public var duration: Duration = .untilQuit

    public init(persona: PersonaChoice = .agents, spaceID: UUID? = nil, level: AgentAccessLevel = .readOnly, scopes: AgentGrantScopes = AgentGrantScopes(), duration: Duration = .untilQuit) {
        self.persona = persona
        self.spaceID = spaceID
        self.level = level
        self.scopes = scopes
        self.duration = duration
    }

    /// Every grant asks for Touch ID or the login password except Read Only in the Agents Persona with no extra scope until Arch quits; a grant in one of the user's own Personas reads with their sign-ins, so it always asks.
    public var needsAuthentication: Bool {
        !(persona == .agents && level == .readOnly && scopes.isEmpty && duration == .untilQuit)
    }
}

/// Shows the grant sheet. `ask` returns nil for Don't Allow, a sheet that timed out, and one that `cancelAll()` closed.
@MainActor public protocol AgentGrantPrompting: AnyObject {
    func ask(_ request: AgentGrantRequest) async -> AgentGrantChoice?
    /// Closes every sheet as Don't Allow, as at quit.
    func cancelAll()
}

/// Touch ID or the login password, through LocalAuthentication.
public protocol AgentAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

/// Uses LocalAuthentication to verify the device owner before a grant.
public struct AgentDeviceOwnerAuthentication: AgentAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
