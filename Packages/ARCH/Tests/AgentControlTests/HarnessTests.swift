// The harness: every guide topic the design names, the tool names and statuses the topics use, the MCP instructions within 2,000 characters, the skills made from the same text with front matter of only `name` and `description` and the version line first, the version line check, and the `guide` tool's results.
import AgentControl
import Foundation
import Testing

/// A `SKILL.md`'s front matter as key and raw value, its body's lines, or nil without front matter.
private func parts(_ markdown: String) -> (frontMatter: [(String, String)], body: [Substring])? {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
    let frontMatter = lines[1 ..< end].map { line -> (String, String) in
        let colon = line.firstIndex(of: ":") ?? line.endIndex
        return (String(line[..<colon]), String(line[colon...].dropFirst().drop(while: { $0 == " " })))
    }
    return (frontMatter, Array(lines[(end + 1)...]))
}

/// Checks a skill as the tools read it and returns its front matter's description, decoded.
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
    #expect(parsed.body.first.map(String.init) == AgentSkill.versionLine)
    #expect(AgentSkill.versionLine == "arch-skill-version: 1")
    #expect(AgentSkill.isArchs(skill.markdown))
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

    @Test func topicsNameOnlyTheCatalogsToolsParametersAndValues() {
        // Words with an underscore, such as hand_to_user or max_chars, must be the catalog's.
        var known = Set(AgentToolCatalog.tools.map(\.name))
        for tool in AgentToolCatalog.tools {
            for parameter in tool.parameters {
                known.insert(parameter.name)
                switch parameter.kind {
                case .choice(let values), .list(let values?): known.formUnion(values)
                default: break
                }
            }
        }
        let texts = [AgentHarness.instructions, AgentHarness.mcpInstructions] + AgentGuideTopic.allCases.map(\.text)
        for text in texts {
            let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).filter { $0.contains("_") }
            for word in words {
                #expect(known.contains(String(word)), "\(word)")
            }
        }
    }

    @Test func troubleshootingCoversEveryStatusButOk() {
        let text = AgentHarness.text(for: .troubleshooting)
        for status in AgentResultStatus.allCases where status != .ok {
            #expect(text.contains("- \(status.rawValue):"), "\(status)")
        }
        for code in ["notInteractable", "notVisible", "tabNotFound", "navigationFailed"] {
            #expect(text.contains(code), "\(code)")
        }
    }

    @Test func purchasesAndMessagesStopBeforeTheLastStep() {
        let text = AgentHarness.text(for: .purchasesAndMessages)
        #expect(text.contains("Prepare, never finish"))
        #expect(text.contains("request_approval"))
        #expect(text.contains("hand_to_user"))
    }

    @Test func theMCPInstructionsFitAndNameTheGuide() {
        #expect(AgentHarness.mcpInstructions.count <= 2_000)
        #expect(AgentHarness.mcpInstructions.contains("Call guide first"))
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
        // A path with spaces and quotes is written as the shell reads it.
        let odd = AgentHarness.entrySkill(cliPath: "/Users/someone/My Apps/Arch's.app/Contents/Helpers/arch-cli")
        #expect(odd.body.contains(#"'/Users/someone/My Apps/Arch'\''s.app/Contents/Helpers/arch-cli' guide"#))
        #expect(odd.markdown != skill.markdown)
    }

    @Test func sessionSkillsAreTheTopicsButCLI() throws {
        let skills = AgentHarness.sessionSkills
        let topics = AgentGuideTopic.allCases.filter { $0 != .cli }
        #expect(skills.map(\.name) == topics.map { "arch-\($0.rawValue)" })
        #expect(Set(skills.map(\.name)).count == skills.count)
        for (skill, topic) in zip(skills, topics) {
            let description = try checkSkill(skill)
            #expect(description.hasPrefix(topic.summary))
            // The same text as the guide topic.
            #expect(skill.body == topic.text)
            #expect(skill.markdown.contains(topic.text))
        }
        #expect(!skills.map(\.name).contains(AgentHarness.entrySkillName))
    }

    @Test func descriptionsThatYAMLWouldMisreadStayOneString() throws {
        let skill = AgentSkill(name: "check", description: #"Use: "quoted" \ # not a comment"#, body: "Text.")
        #expect(try checkSkill(skill) == skill.description)
    }

    @Test func theVersionLineMarksArchsSkills() {
        #expect(AgentSkill.isArchs("---\nname: a\ndescription: \"b\"\n---\narch-skill-version: 1\n\nText.\n"))
        #expect(AgentSkill.isArchs("---\nname: a\n---\narch-skill-version: 12"))
        // Without front matter, without the line, with another line first, in the front matter, or with no number.
        #expect(!AgentSkill.isArchs("arch-skill-version: 1\n"))
        #expect(!AgentSkill.isArchs("---\nname: a\ndescription: b\n---\n# A skill of the user's\n"))
        #expect(!AgentSkill.isArchs("---\nname: a\n---\n\narch-skill-version: 1\n"))
        #expect(!AgentSkill.isArchs("---\nname: a\narch-skill-version: 1\n---\nText.\n"))
        #expect(!AgentSkill.isArchs("---\nname: a\n---\narch-skill-version: \n"))
        #expect(!AgentSkill.isArchs("---\nname: a\n---\narch-skill-version: 1a\n"))
        #expect(!AgentSkill.isArchs("---\nname: a\n---"))
        #expect(!AgentSkill.isArchs(""))
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
