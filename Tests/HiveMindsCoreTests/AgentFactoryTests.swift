import Foundation
import Testing
@testable import HiveMindsCore

/// How New Agent turns a request into an agent, as the app's createAgent did before this moved to HiveMindsCore.
@Suite struct AgentFactoryTests {
    func request(task: String = "  Fix the login bug\n", issue: IssueRef? = nil, title: String? = nil,
                 plan: Bool = false, provider: Provider = .claude) -> NewAgent {
        NewAgent(provider: provider, model: "haiku", effort: .high, access: .manual, planMode: plan, role: "  Be brief ",
                 task: task, ownBranch: true, issue: issue, title: title)
    }

    @Test func branchNamesComeFromTheIssueTheTitleOrTheRequest() {
        let issue = IssueRef(repo: "a/b", number: 42, title: "Crash on start", url: "u")
        #expect(AgentFactory.branchSlug(request(), suffix: "ab12") == "fix-the-login-bug-ab12")
        #expect(AgentFactory.branchSlug(request(issue: issue), suffix: "ab12") == "issue-42-crash-on-start-ab12")
        #expect(AgentFactory.branchSlug(request(title: "Score bug"), suffix: "ab12") == "score-bug-ab12")
        #expect(AgentFactory.branchSlug(request(task: "  "), suffix: "ab12") == "agent-ab12")
        #expect(AgentFactory.branchSlug(request()).count == "fix-the-login-bug-".count + 4)
    }

    @Test func theAgentGetsItsPromptTitleAndPlanMode() {
        let project = UUID()
        let a = AgentFactory.make(request(plan: true), projectID: project, cwd: "/p", branch: "hive/x", prompt: "Fix the login bug\n\nfile.png")
        #expect(a.projectID == project && a.cwd == "/p" && a.branch == "hive/x")
        #expect(a.pendingTask == "Fix the login bug\n\nfile.png")
        #expect(a.role == "Be brief")
        #expect(a.title == "Fix the login bug")
        #expect(a.startsInPlan == true)
        #expect(a.effort == .high && a.access == .manual && a.model == "haiku")
        // Plan mode is Claude Code's; Codex agents don't get it.
        #expect(AgentFactory.make(request(plan: true, provider: .codex), projectID: project, cwd: "/p", branch: nil, prompt: "x").startsInPlan == nil)
        // No request: no pending task, and the chat stays untitled until it gets one.
        let empty = AgentFactory.make(request(task: ""), projectID: project, cwd: "/p", branch: nil, prompt: "")
        #expect(empty.pendingTask == nil && empty.isUntitled)
    }

    @Test func issuesAndGivenTitlesDontNeedHaiku() {
        let issue = IssueRef(repo: "a/b", number: 7, title: "Score shows one too many", url: "u")
        #expect(AgentFactory.make(request(issue: issue), projectID: UUID(), cwd: "/p", branch: nil, prompt: "x").title == "Score shows one too many")
        #expect(!AgentFactory.wantsGeneratedTitle(request(issue: issue)))
        #expect(!AgentFactory.wantsGeneratedTitle(request(title: "Named")))
        #expect(!AgentFactory.wantsGeneratedTitle(request(task: " ")))
        #expect(AgentFactory.wantsGeneratedTitle(request()))
        #expect(ChatTitle.question(for: "Fix it").hasSuffix("Request: Fix it"))
    }

    @Test func aHostMakesTheWorktreeToo() async throws {
        let dir = try scratchFolder("factory")
        defer { cleanUp(dir) }
        let git = Shell.which("git") ?? "/usr/bin/git"
        for args in [["init", "-q", "-b", "main"], ["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "i"]] {
            #expect(await Shell.run(git, ["-C", dir.path] + args).ok)
        }
        let a = try await AgentFactory.create(request(), in: Project(name: "p", path: dir.path), git: git)
        #expect(a.branch?.hasPrefix("hive/fix-the-login-bug-") == true)
        #expect(FileManager.default.fileExists(atPath: a.cwd))
        #expect(a.pendingTask == "Fix the login bug")
    }
}
