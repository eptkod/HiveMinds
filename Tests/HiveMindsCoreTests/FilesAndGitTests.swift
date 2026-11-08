import Foundation
import Testing
@testable import HiveMindsCore

/// A fresh folder under the system temp folder, removed by the caller with `cleanUp`.
func scratchFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hiveminds-tests-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url) }

@Suite struct HookSettingsTests {
    @Test func writesHooksStatusLineAndKeyFiles() throws {
        let dir = try scratchFolder("hooks")
        defer { cleanUp(dir) }
        let own = dir.appendingPathComponent("user-settings.json")
        try Data(#"{"statusLine":{"command":"my-line"}}"#.utf8).write(to: own)
        let files = HookSettings.Files(hooks: dir.appendingPathComponent("h.json"), hooksWithKey: dir.appendingPathComponent("hk.json"),
                                       keyOnly: dir.appendingPathComponent("k.json"), statusLineScript: dir.appendingPathComponent("s.sh"),
                                       usage: dir.appendingPathComponent("usage.json"))
        HookSettings.write(files, keyVariable: "HIVEMINDS_ANTHROPIC_KEY", userSettings: own)

        let hooks = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: files.hooks)) as? [String: Any])
        let events = try #require(hooks["hooks"] as? [String: Any])
        #expect(Set(events.keys) == Set(HookSettings.events))
        #expect(hooks["includeCoAuthoredBy"] as? Bool == false)
        #expect((hooks["attribution"] as? [String: String]) == ["commit": "", "pr": ""])
        #expect(hooks["apiKeyHelper"] == nil)
        let withKey = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: files.hooksWithKey)) as? [String: Any])
        #expect(withKey["apiKeyHelper"] as? String == "printenv HIVEMINDS_ANTHROPIC_KEY" && withKey["hooks"] != nil)
        let keyOnly = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: files.keyOnly)) as? [String: Any])
        #expect(keyOnly["hooks"] == nil && keyOnly["apiKeyHelper"] != nil)
        let script = try String(contentsOf: files.statusLineScript, encoding: .utf8)
        #expect(script.contains(files.usage.path) && script.contains("HIVEMINDS_STATUS") && script.hasSuffix("printf '%s' \"$input\" | my-line\n"))
    }

    @Test func theHookCommandAppendsOneLinePerEvent() async throws {
        let dir = try scratchFolder("hookcmd")
        defer { cleanUp(dir) }
        let events = dir.appendingPathComponent("e.jsonl")
        for json in ["{\n \"a\": 1\n}", "{\"b\": 2}"] {
            let r = await Shell.run("/bin/sh", ["-c", "printf '%s' '\(json)' | sh -c '\(HookSettings.eventCommand.replacingOccurrences(of: "'", with: "'\\''"))'"],
                                    env: ["HIVEMINDS_EVENTS": events.path])
            #expect(r.ok)
        }
        #expect(try String(contentsOf: events, encoding: .utf8) == "{ \"a\": 1}\n{\"b\": 2}\n")
    }
}

@Suite struct EventTailTests {
    @Test func followsNewLinesOnly() throws {
        let dir = try scratchFolder("tail")
        defer { cleanUp(dir) }
        let file = dir.appendingPathComponent("e.jsonl")
        try Data("{\"old\": true}\n".utf8).write(to: file)
        let queue = DispatchQueue(label: "tail-test")
        let got = DispatchSemaphore(value: 0)
        var seen: [[String: Any]] = []
        let tail = try #require(EventTail(url: file, queue: queue) { seen.append($0); got.signal() })
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"hook_event_name\": \"Stop\"}\nnot json\n{\"n\":".utf8))
        #expect(got.wait(timeout: .now() + 5) == .success)
        handle.write(Data(" 2}\n".utf8))
        #expect(got.wait(timeout: .now() + 5) == .success)
        try handle.close()
        queue.sync {}
        #expect(seen.count == 2)
        #expect(seen.first?["hook_event_name"] as? String == "Stop")
        #expect(seen.last?["n"] as? Int == 2)
        _ = tail
    }
}

@Suite(.serialized) struct GitTests {
    let git = Shell.which("git") ?? "/usr/bin/git"

    func repo() async throws -> URL {
        let dir = try scratchFolder("git")
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] {
            #expect(await Shell.run(git, ["-C", dir.path] + args).ok)
        }
        try "one\ntwo\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(await Shell.run(git, ["-C", dir.path, "add", "."]).ok)
        #expect(await Shell.run(git, ["-C", dir.path, "commit", "-qm", "first"]).ok)
        return dir
    }

    @Test func excludeIsAddedOnce() throws {
        let dir = try scratchFolder("exclude")
        defer { cleanUp(dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try "*.log".write(to: dir.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        Git.excludeFromGit(projectPath: dir.path, pattern: "/.hiveminds/")
        Git.excludeFromGit(projectPath: dir.path, pattern: "/.hiveminds/")
        #expect(try String(contentsOf: dir.appendingPathComponent(".git/info/exclude"), encoding: .utf8) == "*.log\n/.hiveminds/\n")
    }

    @Test func worktreeAgentChangesAreMeasuredFromItsBranchPoint() async throws {
        let dir = try await repo()
        defer { cleanUp(dir) }
        let project = Project(name: "p", path: dir.path)
        let (path, branch) = try await Git.makeWorktree(git: git, project: project, slug: "fix-it-ab12")
        #expect(branch == "hive/fix-it-ab12" && path == dir.path + "/.hiveminds/worktrees/fix-it-ab12")
        try "one\nTWO\nthree\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        #expect(await Shell.run(git, ["-C", path, "commit", "-qam", "change"]).ok)
        try "new\n".write(toFile: path + "/b.txt", atomically: true, encoding: .utf8)
        let agent = Agent(projectID: project.id, provider: .codex, model: "default", role: "", cwd: path, branch: branch)
        let set = try await Git.changes(git: git, of: agent, projectPath: dir.path, transcripts: [])
        #expect(set.base == "main")
        #expect(set.files.map(\.path) == ["a.txt", "b.txt"])
        // As before the move: a new file's line count includes the empty piece after its last newline.
        #expect(set.added == 4 && set.removed == 1)
        #expect(set.files[1].untracked)
        let d = await Git.diff(git: git, cwd: path, file: set.files[0], against: set)
        #expect(d.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context])
        #expect(d.lines.map(\.text).dropFirst() == [" one", "-two", "+TWO", "+three", ""])
        #expect(!d.cut)
        // The project's own `git status` doesn't see the agents' folder.
        #expect(await Shell.run(git, ["-C", dir.path, "status", "--porcelain"]).out.isEmpty)
    }

    @Test func worktreeErrorsSayWhatToDo() async throws {
        let dir = try scratchFolder("notrepo")
        defer { cleanUp(dir) }
        let project = Project(name: "Plain", path: dir.path)
        await #expect(throws: CoreError.self) { try await Git.makeWorktree(git: nil, project: project, slug: "x") }
        do {
            _ = try await Git.makeWorktree(git: git, project: project, slug: "x")
            Issue.record("should have thrown")
        } catch {
            #expect(error.localizedDescription == "Plain isn't a git repository, so the agent can't get its own branch. Turn off \"Own branch\".")
        }
    }

    @Test func claudeAgentInTheProjectFolderOnlySeesWhatItEdited() async throws {
        let dir = try await repo()
        defer { cleanUp(dir) }
        try "x\n".write(to: dir.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: dir.appendingPathComponent("theirs.txt"), atomically: true, encoding: .utf8)
        let transcript = dir.appendingPathComponent("t.jsonl")
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"\#(dir.path)/mine.txt"}}]}}"#
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let agent = Agent(projectID: UUID(), provider: .claude, model: "haiku", role: "", cwd: dir.path)
        let set = try await Git.changes(git: git, of: agent, projectPath: dir.path, transcripts: [transcript.path])
        #expect(set.onlyItsOwn)
        #expect(set.files.map(\.path) == ["mine.txt"])
    }

    @Test func editsCountCommandsThatWriteAFileButNotOnesThatRunIt() {
        let e = Edits(paths: ["/p/a.swift"], commands: ["sed -i '' s/x/y/ notes.md", "scripts/build.sh"])
        #expect(e.touched("/p/a.swift", relative: "a.swift"))
        #expect(e.touched("/p/notes.md", relative: "notes.md"))
        #expect(!e.touched("/p/scripts/build.sh", relative: "scripts/build.sh"))
    }

    @Test func longDiffsAreCut() {
        let raw = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n" + (0..<10).map { "+\($0)" }.joined(separator: "\n")
        let r = Git.parseDiff(raw, limit: 5)
        #expect(r.cut && r.lines.count == 5 && r.lines[0].kind == .hunk)
    }
}
