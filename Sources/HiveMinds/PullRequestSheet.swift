import SwiftUI
import AppKit

/// Shows what an agent's branch changed, drafts a title and description, and only pushes when you say so.
struct PullRequestSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    @State private var plan: PRPlan?
    @State private var title = ""
    @State private var prBody = ""
    @State private var draft = false
    @State private var drafting = false
    @State private var working = false
    @State private var error: String?

    /// The agent as it is now. Its pull request can turn up after the sheet opens.
    private var current: Agent { store.agent(agent.id) ?? agent }
    /// A pull request is already open, so this only sends the newest changes to it.
    private var updating: Bool { current.pullRequest?.state == "OPEN" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(updating ? "Update Pull Request" : "Open a Pull Request").font(.title2.weight(.semibold))
            if let plan {
                summary(plan)
                if !updating && plan.hasChanges { fields }
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at its changes…").foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if let pr = current.pullRequest, let url = URL(string: pr.url) {
                    Button("View #\(pr.number) on GitHub") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Pushing…" : (updating ? "Push Changes" : "Push and Open")) { publish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canPublish)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await load() }
    }

    private var canPublish: Bool {
        guard let plan, !working else { return false }
        if updating { return plan.unpushed > 0 || !plan.uncommitted.isEmpty }
        return plan.hasChanges && !title.trimmingCharacters(in: .whitespaces).isEmpty && !drafting
    }

    private func summary(_ plan: PRPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(plan.branch) → \(plan.base)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if !plan.hasChanges {
                Text("This branch has no changes yet, so there's nothing to open a pull request for.")
            } else {
                Text(changeLine(plan))
                if updating && plan.unpushed == 0 && plan.uncommitted.isEmpty {
                    Text("Everything is already on GitHub.").foregroundStyle(.secondary)
                }
                Text(updating
                     ? "This pushes the branch to GitHub, so the open pull request shows the new changes."
                     : "This pushes the branch to GitHub and opens a pull request that anyone with access to the repository can see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func changeLine(_ plan: PRPlan) -> String {
        var parts: [String] = []
        if !plan.commits.isEmpty { parts.append(plan.commits.count == 1 ? "1 commit" : "\(plan.commits.count) commits") }
        if !plan.uncommitted.isEmpty {
            let n = plan.uncommitted.count
            parts.append("\(n) changed \(n == 1 ? "file" : "files") not committed yet, which will be committed first")
        }
        return parts.joined(separator: ", ") + "."
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title, prompt: Text(drafting ? "Writing a title…" : "Title"))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prBody)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 180)
                if prBody.isEmpty {
                    Text(drafting ? "Writing a description…" : "Description (optional)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Toggle("Open as a draft", isOn: $draft)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("A draft can't be merged until you mark it ready on GitHub.")
        }
    }

    private func load() async {
        await store.refreshPullRequest(agent.id)
        do {
            let p = try await store.planPullRequest(agent)
            plan = p
            guard !updating, p.hasChanges else { return }
            title = agent.isUntitled ? "" : agent.title
            drafting = true
            if let d = await store.draftPullRequest(agent, p) {
                // Keep anything you typed while it was drafting.
                if title.isEmpty || title == agent.title { title = d.title }
                if prBody.isEmpty { prBody = d.body }
            }
            drafting = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func publish() {
        guard let plan else { return }
        working = true
        error = nil
        Task {
            do {
                try await store.publishPullRequest(current, plan: plan, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   body: prBody, draft: draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
