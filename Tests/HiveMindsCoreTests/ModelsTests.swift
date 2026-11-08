import Foundation
import Testing
@testable import HiveMindsCore

@Suite struct ModelsTests {
    @Test func roughTitleKeepsShortPromptsAndCutsLongOnes() {
        #expect(Agent.roughTitle("Fix the login bug") == "Fix the login bug")
        #expect(Agent.roughTitle("   ") == Agent.untitled)
        let long = Agent.roughTitle(String(repeating: "word ", count: 30))
        #expect(long == String(repeating: "word ", count: 9) + "word…")
    }

    @Test func slugifyMakesBranchSafeNames() {
        #expect(slugify("Fix: the Login bug!") == "fix-the-login-bug")
        #expect(slugify(String(repeating: "a", count: 50)).count == 32)
    }

    @Test func agentStillDecodesTheOldNameKey() throws {
        let agent = Agent(projectID: UUID(), title: "Hello", provider: .claude, model: "haiku", role: "", cwd: "/tmp")
        let data = try JSONEncoder().encode(agent)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["name"] as? String == "Hello")
        #expect(json["title"] == nil)
        #expect(try JSONDecoder().decode(Agent.self, from: data) == agent)
    }
}
