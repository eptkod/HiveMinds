import Foundation

/// The Claude Code settings files HiveMinds starts agents with: hooks that append each event, one JSON object
/// per line, to the file the agent was started with (`$HIVEMINDS_EVENTS`), and a status line that saves the
/// session's state. HiveMinds watches those files: no server, nothing listening on a port.
package enum HookSettings {
    /// The Claude Code hook events HiveMinds follows.
    package static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "Notification", "PermissionRequest", "StopFailure", "SessionEnd"]

    /// Appends the event (stdin, one line) to `$HIVEMINDS_EVENTS`, and never fails the hook.
    package static let eventCommand = #"[ -n "$HIVEMINDS_EVENTS" ] && { tr -d '\n' >> "$HIVEMINDS_EVENTS"; echo >> "$HIVEMINDS_EVENTS"; }; true"#

    /// Where the files go.
    package struct Files: Sendable {
        /// Hooks and status line, for agents that sign in through the plan's login.
        package var hooks: URL
        /// The same plus `apiKeyHelper`, for agents that sign in with an API key.
        package var hooksWithKey: URL
        /// Only `apiKeyHelper`, for one-off Claude calls (chat titles, pull request text).
        package var keyOnly: URL
        package var statusLineScript: URL
        /// Where the status line saves the plan's usage limits, for the usage meter.
        package var usage: URL

        package init(hooks: URL, hooksWithKey: URL, keyOnly: URL, statusLineScript: URL, usage: URL) {
            self.hooks = hooks
            self.hooksWithKey = hooksWithKey
            self.keyOnly = keyOnly
            self.statusLineScript = statusLineScript
            self.usage = usage
        }
    }

    /// Writes all the files. `keyVariable` is the environment variable that carries the API key.
    /// `userSettings` is the user's own Claude Code settings, whose status line command is run too.
    package static func write(_ files: Files, keyVariable: String,
                              userSettings: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")) {
        var hooks: [String: Any] = [:]
        for e in events { hooks[e] = [["hooks": [["type": "command", "command": eventCommand]]]] }
        try? statusLineScript(usage: files.usage, userSettings: userSettings).write(to: files.statusLineScript, atomically: true, encoding: .utf8)
        // Agents never credit Claude in commits or PRs: no Co-Authored-By trailer, no "Generated with" footer.
        let noCredit: [String: Any] = ["attribution": ["commit": "", "pr": ""], "includeCoAuthoredBy": false]
        let settings: [String: Any] = [
            "hooks": hooks,
            "statusLine": ["type": "command", "command": "/bin/sh '\(files.statusLineScript.path)'"],
        ].merging(noCredit) { $1 }
        // Claude Code asks this command for the key. It prints our variable, so the key itself never touches disk.
        let keyHelper = ["apiKeyHelper": "printenv \(keyVariable)"].merging(noCredit) { $1 }
        for (file, contents) in [(files.hooks, settings), (files.hooksWithKey, settings.merging(keyHelper) { $1 }),
                                 (files.keyOnly, keyHelper)] {
            if let data = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Claude Code hands its status line command the session's state, including how much of the plan's
    /// 5-hour and weekly limits is used. The script saves that for the usage meter, then runs your own
    /// status line from ~/.claude/settings.json, if you have one, so agents look as they would elsewhere.
    package static func statusLineScript(usage: URL, userSettings: URL) -> String {
        var script = """
        #!/bin/sh
        # Written by HiveMinds on every launch.
        input=$(cat)
        case "$input" in *'"rate_limits"'*) printf '%s' "$input" > '\(usage.path)' ;; esac
        [ -n "$HIVEMINDS_STATUS" ] && printf '%s' "$input" > "$HIVEMINDS_STATUS"

        """
        if let data = try? Data(contentsOf: userSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let line = json["statusLine"] as? [String: Any], let own = line["command"] as? String, !own.isEmpty {
            script += "printf '%s' \"$input\" | \(own)\n"
        }
        return script
    }
}
