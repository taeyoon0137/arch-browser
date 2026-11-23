// Tests every harness guide topic the design names.
// Tests the tool, parameter, and value names and the statuses the topics use.
// Tests skills made from the same text with only `name` and `description` in their front matter.
// The version line and its digest come first.
// Tests the version line and digest check and the `guide` tool's results.
import AgentControl
import CryptoKit
import Foundation
import Testing

/// Computes the hex SHA-256 digest of a text's UTF-8 bytes as the design describes.
private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Returns a `SKILL.md`'s front matter as keys and raw values, along with its body's lines.
/// Returns nil without front matter.
private func parts(_ markdown: String) -> (frontMatter: [(String, String)], body: [Substring])? {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
    let frontMatter = lines[1 ..< end].map { line -> (String, String) in
        let colon = line.firstIndex(of: ":") ?? line.endIndex
        return (String(line[..<colon]), String(line[colon...].dropFirst().drop(while: { $0 == " " })))
    }
    return (frontMatter, Array(lines[(end + 1)...]))
}

/// Checks a skill as the tools read it.
/// Returns the decoded description from its front matter.
private func checkSkill(_ skill: AgentSkill) throws -> String {
    #expect(skill.name.count <= 64)
    #expect(skill.name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }, "\(skill.name)")
    let parsed = try #require(parts(skill.markdown))
    // Only `name` and `description`, since the tools check front matter keys.
    #expect(parsed.frontMatter.map(\.0) == ["name", "description"])
    #expect(parsed.frontMatter.first?.1 == skill.name)
    let description = try AgentJSON.decode(Data(parsed.frontMatter[1].1.utf8)).stringValue
    #expect(description == skill.description)
    #expect(skill.description.count <= 1_024)
    // The version line carries the digest of the same text with the bare version line.
    let versionLine = try #require(parsed.body.first.map(String.init))
    #expect(AgentSkill.versionLine == "arch-skill-version: 1")
    let bare = skill.markdown.replacingOccurrences(of: versionLine, with: AgentSkill.versionLine)
    #expect(versionLine == "\(AgentSkill.versionLine) sha256=\(sha256(bare))")
    #expect(AgentSkill.origin(of: skill.markdown) == .archs)
    #expect(skill.markdown.hasSuffix("\n") && !skill.markdown.hasSuffix("\n\n"))
    return try #require(description)
}

@Suite struct HarnessTests {
    @Test func everyTopicOfTheDesignExists() {
        #expect(AgentGuideTopic.allCases.map(\.rawValue) == ["browsing", "forms", "research", "downloads", "purchases-and-messages", "troubleshooting", "cli"])
        for topic in AgentGuideTopic.allCases {
            let text = AgentHarness.text(for: topic)
            #expect(!text.isEmpty, "\(topic)")
            #expect(!text.contains("\n\n\n"), "\(topic)")
            #expect(text.utf8.count <= AgentLimits.resultTextBytes, "\(topic)")
            #expect(topic.summary.hasSuffix("."), "\(topic)")
            // The guide lists every topic with its summary.
            #expect(AgentHarness.instructions.contains("- \(topic.rawValue): \(topic.summary)"), "\(topic)")
            #expect(AgentHarness.mcpInstructions.contains(topic.rawValue), "\(topic)")
        }
        #expect(AgentHarness.instructions.utf8.count <= AgentLimits.resultTextBytes)
    }

    @Test func topicsNameOnlyTheCatalogsToolsParametersAndValues() throws {
        func values(_ parameter: AgentToolParameter) -> [String] {
            switch parameter.kind {
            case .choice(let values), .list(let values?): return values
            default: return []
            }
        }
        // Words with an underscore, such as hand_to_user or max_chars, must come from the catalog or outside programs' tools beside it.
        let catalog = AgentToolCatalog.tools + [AgentToolCatalog.renameTab, AgentToolCatalog.watchEvents]
        var known = Set(catalog.map(\.name))
        for tool in catalog {
            for parameter in tool.parameters {
                known.insert(parameter.name)
                known.formUnion(values(parameter))
            }
        }
        let texts = [AgentHarness.instructions, AgentHarness.mcpInstructions] + AgentGuideTopic.allCases.map(\.text)
        let words = Set(texts.flatMap { $0.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init) })
        for word in words where word.contains("_") {
            #expect(known.contains(word), "\(word)")
        }
        // Each name without an underscore must be a parameter or value of the named tool.
        // It stays listed only while a text uses it.
        let uses: [(tool: String, parameter: String?, values: [String])] = [
            ("guide", "topic", []),
            ("navigate", nil, []),
            ("click", nil, []),
            ("screenshot", nil, []),
            ("open_tab", "ref", []),
            ("open_tab", "tab", []),
            ("snapshot", "mode", ["interactive", "full"]),
            ("snapshot", "ref", []),
            ("snapshot", "diff", []),
            ("read_text", "offset", []),
            ("type", "ref", []),
            ("type", "replace", []),
            ("type", "submit", []),
            ("wait_for", "text", []),
            ("wait_for", "url", []),
            ("wait_for", "ref", []),
            ("wait_for", "load", []),
            ("list_tabs", "scope", ["shared"]),
            ("request_approval", "kind", ["purchase", "send", "delete", "download", "other"]),
            ("hand_to_user", "reason", ["sign_in", "verification", "payment"]),
        ]
        for use in uses {
            let tool = try #require(AgentToolCatalog.tool(named: use.tool), "\(use.tool)")
            #expect(words.contains(use.tool), "\(use.tool)")
            guard let name = use.parameter else { continue }
            let parameter = try #require(tool.parameters.first { $0.name == name }, "\(use.tool) \(name)")
            #expect(words.contains(name), "\(use.tool) \(name)")
            for value in use.values {
                #expect(values(parameter).contains(value), "\(use.tool) \(name) \(value)")
                #expect(words.contains(value), "\(use.tool) \(name) \(value)")
            }
        }
    }

    @Test func troubleshootingCoversEveryStatusButOk() {
        let text = AgentHarness.text(for: .troubleshooting)
        for status in AgentResultStatus.allCases where status != .ok {
            #expect(text.contains("- \(status.rawValue):"), "\(status)")
        }
        for code in ["notInteractable", "notVisible", "tabNotFound", "navigationFailed", "pageChanged"] {
            #expect(text.contains(code), "\(code)")
        }
    }

    @Test func purchasesAndMessagesStopBeforeTheLastStep() {
        let text = AgentHarness.text(for: .purchasesAndMessages)
        #expect(text.contains("Prepare, never finish"))
        #expect(text.contains("request_approval"))
        #expect(text.contains("hand_to_user"))
    }

    @Test func theEntrySkillNamesArchCLIByItsPath() throws {
        let skill = AgentHarness.entrySkill(cliPath: "/Applications/Arch.app/Contents/Helpers/arch-cli")
        #expect(skill.name == "arch-browser")
        #expect(skill.name == AgentHarness.entrySkillName)
        _ = try checkSkill(skill)
        #expect(skill.body.contains("/Applications/Arch.app/Contents/Helpers/arch-cli guide"))
        #expect(skill.body.contains("Allow Outside Clients"))
        #expect(skill.body.contains("<untrusted source=\"page\""))
        for topic in AgentGuideTopic.allCases { #expect(skill.body.contains(topic.rawValue), "\(topic)") }
        // Write a path with spaces and quotes as the shell reads it.
        let odd = AgentHarness.entrySkill(cliPath: "/Users/someone/My Apps/Arch's.app/Contents/Helpers/arch-cli")
        #expect(odd.body.contains(#"'/Users/someone/My Apps/Arch'\''s.app/Contents/Helpers/arch-cli' guide"#))
        #expect(odd.markdown != skill.markdown)
    }

    @Test func inAppGuidanceNamesTheSessionsToolsAndKeepsTheOutsideGuide() {
        let guide = AgentHarness.guideResult(arguments: [:], inSession: true)
        #expect(guide.text == AgentHarness.sessionInstructions)
        for name in ["session_info", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot", "wait_for", "ask_user", "request_approval", "hand_to_user", "guide"] {
            #expect(guide.text.contains(name), "\(name)")
        }
        // An in-app session's call waits on its card.
        // Its guidance therefore never sends it to approval_wait.
        for topic in AgentGuideTopic.allCases {
            let text = AgentHarness.guideResult(arguments: ["topic": .string(topic.rawValue)], inSession: true).text
            for unavailable in ["approval_wait", "approvalPending", "arch-cli guide"] {
                #expect(!text.contains(unavailable), "\(topic) describes \(unavailable)")
            }
        }
        #expect(!guide.text.contains("approval_wait"))
        let outside = AgentMCPServer(mode: .outside, version: "test")
        let bound = AgentMCPServer(mode: .session(ticket: "fixture"), version: "test")
        #expect(outside.instructions == AgentHarness.mcpInstructions && outside.instructions.contains("request_approval"))
        #expect(bound.instructions == AgentHarness.boundMCPInstructions && !bound.instructions.contains("request_approval"))
        #expect(AgentHarness.guideResult(arguments: ["topic": "browsing"]).text.contains("open_tab"))
    }

    @Test func sessionSkillsAreTheTopicsButCLI() throws {
        let skills = AgentHarness.sessionSkills
        let topics = AgentGuideTopic.allCases.filter { $0 != .cli }
        #expect(skills.map(\.name) == topics.map { "arch-\($0.rawValue)" })
        #expect(Set(skills.map(\.name)).count == skills.count)
        for (skill, topic) in zip(skills, topics) {
            let description = try checkSkill(skill)
            #expect(!description.isEmpty)
            let delivered = AgentHarness.guideResult(arguments: ["topic": .string(topic.rawValue)], inSession: true)
            #expect(skill.body == delivered.text)
            #expect(skill.markdown.contains(delivered.text))
            #expect(skill.body != topic.text)
        }
        #expect(!skills.map(\.name).contains(AgentHarness.entrySkillName))
    }

    @Test func descriptionsThatYAMLWouldMisreadStayOneString() throws {
        let skill = AgentSkill(name: "check", description: #"Use: "quoted" \ # not a comment"#, body: "Text.")
        #expect(try checkSkill(skill) == skill.description)
    }

    @Test func theVersionLineMarksArchsSkillsAndItsDigestShowsChanges() {
        let skill = AgentSkill(name: "a", description: "b", body: "Text.")
        #expect(AgentSkill.origin(of: skill.markdown) == .archs)
        // Arch also recognizes another format version with its digest.
        let bare = "---\nname: a\n---\narch-skill-version: 12\n\nText.\n"
        #expect(AgentSkill.origin(of: bare.replacingOccurrences(of: "version: 12", with: "version: 12 sha256=\(sha256(bare))")) == .archs)
        // Arch's version line with a line added, the body or front matter edited, a wrong digest, or none.
        #expect(AgentSkill.origin(of: skill.markdown + "My note.\n") == .modified)
        #expect(AgentSkill.origin(of: skill.markdown.replacingOccurrences(of: "Text.", with: "Mine.")) == .modified)
        #expect(AgentSkill.origin(of: skill.markdown.replacingOccurrences(of: "name: a", with: "name: c")) == .modified)
        #expect(AgentSkill.origin(of: "---\nname: a\n---\narch-skill-version: 1 sha256=00\n\nText.\n") == .modified)
        #expect(AgentSkill.origin(of: "---\nname: a\n---\narch-skill-version: 1 mine\n\nText.\n") == .modified)
        #expect(AgentSkill.origin(of: bare) == .modified)
        // Without front matter, without the line, with another line first, in the front matter, or with no number.
        #expect(AgentSkill.origin(of: "arch-skill-version: 1\n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\ndescription: b\n---\n# A skill of the user's\n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\n---\n\narch-skill-version: 1\n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\narch-skill-version: 1\n---\nText.\n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\n---\narch-skill-version: \n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\n---\narch-skill-version: 1a\n") == .other)
        #expect(AgentSkill.origin(of: "---\nname: a\n---") == .other)
        #expect(AgentSkill.origin(of: "") == .other)
    }

    @Test func theGuideToolGivesTheGuideOrATopic() throws {
        let topics = AgentJSON.array(AgentGuideTopic.allCases.map { .string($0.rawValue) })
        #expect(AgentHarness.guideResult(arguments: [:]) == AgentToolResult(status: .ok, content: [.text(AgentHarness.instructions)], structured: ["topics": topics]))
        #expect(AgentHarness.guideResult(arguments: ["topic": .null]).content == [.text(AgentHarness.instructions)])
        for topic in AgentGuideTopic.allCases {
            let result = AgentHarness.guideResult(arguments: ["topic": .string(topic.rawValue)])
            #expect(result == AgentToolResult(status: .ok, content: [.text(topic.text)], structured: ["topic": .string(topic.rawValue), "topics": topics]))
        }
        let unknown = AgentHarness.guideResult(arguments: ["topic": "secrets"])
        #expect(unknown.status == .error)
        #expect(unknown.content == [.text("There is no guide topic named secrets. Topics: browsing, forms, research, downloads, purchases-and-messages, troubleshooting, cli.")])
        #expect(unknown.code == "invalidArguments")
        #expect(AgentHarness.guideResult(arguments: ["topic": 3]).content == [.text("topic must be a string. Topics: browsing, forms, research, downloads, purchases-and-messages, troubleshooting, cli.")])
        #expect(AgentHarness.guideResult(arguments: ["topic": "forms", "tab": "t1"]).status == .error)
        // The result travels as the control protocol's tools/call result.
        let decoded = try AgentJSON(encoding: AgentHarness.guideResult(arguments: ["topic": "forms"])).decode(as: AgentToolResult.self)
        #expect(decoded.content == [.text(AgentHarness.text(for: .forms))])
    }
}
