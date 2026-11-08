import Foundation

/// Everything outside the agent that decides how its CLI starts. The app fills this from its settings and
/// Keychain; HiveMinds Host fills it from its own config and each request.
package struct LaunchContext: Sendable {
    /// The CLI to run (`claude` or `codex`).
    package var executable: String
    /// The environment to start from: the login PATH, minus variables that would confuse a child agent.
    package var baseEnvironment: [String: String]
    /// Variables that carry an API key, when the provider signs in with one.
    package var signInEnvironment: [String: String]
    /// Codex: extra flags that point it at the API key, when it signs in with one.
    package var codexSignInArgs: [String]
    /// Claude Code: the `--settings` file with the HiveMinds hooks (and `apiKeyHelper` when it uses a key).
    package var claudeSettingsFile: String
    /// Claude Code: where its hooks append events, one JSON object per line.
    package var eventsFile: String
    /// Claude Code: where its status line saves the session's state (cost, tokens).
    package var statusFile: String
    /// The access level for meeting seats that don't have their own.
    package var defaultAccess: Access
    /// On Manual review, whether meeting seats may still write their notes without asking.
    package var meetingSeatsAcceptEdits: Bool

    package init(executable: String, baseEnvironment: [String: String], signInEnvironment: [String: String] = [:],
                 codexSignInArgs: [String] = [], claudeSettingsFile: String, eventsFile: String, statusFile: String,
                 defaultAccess: Access, meetingSeatsAcceptEdits: Bool) {
        self.executable = executable
        self.baseEnvironment = baseEnvironment
        self.signInEnvironment = signInEnvironment
        self.codexSignInArgs = codexSignInArgs
        self.claudeSettingsFile = claudeSettingsFile
        self.eventsFile = eventsFile
        self.statusFile = statusFile
        self.defaultAccess = defaultAccess
        self.meetingSeatsAcceptEdits = meetingSeatsAcceptEdits
    }
}

/// How to start an agent's CLI: the one place that builds its command line, so This Mac and a host can't drift.
package struct LaunchPlan: Equatable, Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var directory: String
    /// Claude Code: this start resumes an earlier conversation (`--resume`), rather than beginning one.
    package var resumes: Bool
    /// Codex takes its first task on the command line, so the agent counts as started as soon as it launches.
    package var startsTaskNow: Bool
    /// The status to show while it starts.
    package var status: AgentStatus
    package var activity: String

    package static func make(for agent: Agent, _ c: LaunchContext) -> LaunchPlan {
        var env = c.baseEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["HIVEMINDS_AGENT"] = agent.id.uuidString
        env.merge(c.signInEnvironment) { $1 }

        var args: [String] = []
        var resumes = false
        var startsTaskNow = false
        let status: AgentStatus
        let activity: String
        switch agent.provider {
        case .claude:
            env["HIVEMINDS_EVENTS"] = c.eventsFile
            env["HIVEMINDS_STATUS"] = c.statusFile
            let session = agent.sessionID.uuidString.lowercased()
            args += agent.hasStarted ? ["--resume", session] : ["--session-id", session]
            resumes = agent.hasStarted
            args += ["--settings", c.claudeSettingsFile]
            if agent.model != "default" { args += ["--model", agent.model] }
            args += agent.provider.effortArgs(agent.effort)
            if !agent.role.isEmpty { args += ["--append-system-prompt", agent.role] }
            // Meeting seats use the default access from Settings > Agents, unless they were given their own.
            let access = agent.access ?? (agent.meetingID != nil ? c.defaultAccess : nil)
            if !agent.hasStarted && agent.startsInPlan == true {
                // Plan mode replaces the access level's mode for the first start. Unrestricted stays on offer
                // for when you approve the plan.
                args += ["--permission-mode", "plan"]
                if access == .unrestricted { args.append("--allow-dangerously-skip-permissions") }
            } else if let access { args += access.args(for: .claude) }
            // On Manual review, meeting seats still write their notes without stopping to ask, unless you turned that off.
            if agent.meetingID != nil && access == .manual && c.meetingSeatsAcceptEdits { args += ["--permission-mode", "acceptEdits"] }
            if !agent.hasStarted, let task = agent.pendingTask { args.append(task) }
            status = .starting
            activity = "Starting up"
        case .codex:
            args += c.codexSignInArgs
            if agent.model != "default" { args += ["--model", agent.model] }
            args += agent.provider.effortArgs(agent.effort)
            if let access = agent.access { args += access.args(for: .codex) }
            if let task = agent.pendingTask {
                args.append(task)
                startsTaskNow = true
            }
            status = .idle
            activity = "Running in its terminal"
        }
        return LaunchPlan(executable: c.executable, arguments: args, environment: env, directory: agent.cwd,
                          resumes: resumes, startsTaskNow: startsTaskNow, status: status, activity: activity)
    }
}

/// Why an agent can't start, with a line for its terminal and what its status should say.
package struct LaunchProblem: Equatable, Sendable {
    package var note: String
    package var activity: String

    /// Nil when it can start. `machine` names where it runs, for the message: "this Mac", "this host".
    package static func check(_ agent: Agent, executable: String?, machine: String) -> LaunchProblem? {
        guard executable != nil else {
            return LaunchProblem(note: "\(agent.provider.label) isn't installed on \(machine).\r\n", activity: "\(agent.provider.label) isn't installed")
        }
        guard FileManager.default.fileExists(atPath: agent.cwd) else {
            return LaunchProblem(note: "This agent's folder is gone: \(agent.cwd)\r\n", activity: "Its folder is missing")
        }
        return nil
    }
}

/// What happens when an agent's CLI ends: it goes to sleep, with a line in its terminal. If it was resuming an
/// earlier conversation and failed straight away (that conversation was deleted, say), the next start begins a
/// new conversation instead.
package struct AgentExit: Equatable, Sendable {
    /// Start a new conversation next time: `hasStarted = false` and a new session id.
    package var startsOver: Bool
    package var note: String
    package var activity: String

    package static func after(resumed: Bool, exitCode: Int32?, ranFor: TimeInterval) -> AgentExit {
        if resumed, exitCode != 0, ranFor < 8 {
            return AgentExit(startsOver: true,
                             note: "\r\n\u{1b}[2m— The earlier conversation couldn't be reopened. Press Restart to begin a new one. —\u{1b}[0m\r\n",
                             activity: "Couldn't reopen its conversation")
        }
        return AgentExit(startsOver: false,
                         note: "\r\n\u{1b}[2m— Session ended. Press Restart to pick up where it left off. —\u{1b}[0m\r\n",
                         activity: "Session ended")
    }
}
