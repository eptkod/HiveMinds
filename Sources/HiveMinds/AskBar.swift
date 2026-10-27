import SwiftUI

/// What an agent is waiting on, with the answers right there: Allow or Don't Allow for a permission prompt,
/// the options (or your own words) for a question, Approve or Keep Planning for a plan. Shown on Overview cards,
/// Canvas tiles and in meeting footers, so you
/// don't have to open the agent's terminal. It shows nothing when the agent isn't waiting.
struct AskBar: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID

    var body: some View {
        let s = store.state(agentID)
        if s.status == .needsYou, let ask = s.ask {
            Group {
                switch ask.kind {
                case .permission(let tool, let detail):
                    PermissionAsk(agentID: agentID, tool: tool, detail: detail)
                case .questions(let questions):
                    QuestionsAsk(agentID: agentID, questions: questions)
                case .plan(let plan):
                    PlanAsk(agentID: agentID, plan: plan)
                }
            }
            .id(ask.id)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
            .transition(Motion.enter)
        }
    }
}

private struct PermissionAsk: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID
    let tool: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tool == "Bash" ? "Wants to run" : "Wants to use \(tool)", systemImage: "hand.raised")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(detail)
            HStack(spacing: 8) {
                Button("Allow") { store.allow(agentID) }
                    .buttonStyle(.glassProminent)
                    .help("Let it go ahead this once")
                Button("Don't Allow") { store.decline(agentID) }
                    .buttonStyle(.glass)
                    .help("Turn it down. It then waits for you to say what to do instead.")
            }
            .controlSize(.small)
        }
    }
}

/// The plan it wants to follow, to read through, then approve or send back with what to change.
private struct PlanAsk: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID
    let plan: String
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Wants you to approve its plan", systemImage: "checklist")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            if !plan.isEmpty {
                ScrollView {
                    Text(Self.markdown(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            TextField("What to change (optional)", text: $feedback)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { if !feedback.trimmingCharacters(in: .whitespaces).isEmpty { store.keepPlanning(agentID, feedback) } }
            HStack(spacing: 8) {
                Button("Approve") { store.approvePlan(agentID) }
                    .buttonStyle(.glassProminent)
                    .help(store.agent(agentID)?.access == .manual
                          ? "Start on the plan. It still asks before each edit."
                          : "Start on the plan, keeping the conversation so far")
                Button("Keep Planning") { store.keepPlanning(agentID, feedback) }
                    .buttonStyle(.glass)
                    .help("Send it back with what you typed above. Left empty, it stops and waits for you.")
            }
            .controlSize(.small)
        }
    }

    /// Bold, code and links from the plan's Markdown; headings and lists stay as written.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Steps through the questions one at a time, then sends every answer together.
private struct QuestionsAsk: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID
    let questions: [AskQuestion]
    @State private var answers: [QuestionAnswer] = []
    @State private var ownWords = ""

    var body: some View {
        let i = min(answers.count, questions.count - 1)
        let q = questions[i]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(q.header.isEmpty ? "Question" : q.header, systemImage: "questionmark.bubble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                if questions.count > 1 {
                    Text("\(i + 1) of \(questions.count)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Text(q.question).font(.callout).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect {
                // Picking several options takes arrow keys and a review screen, so that stays in the terminal.
                Text("This one takes several picks. Answer it in the agent's terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { n, option in
                        Button { pick(.option(n)) } label: {
                            Text(option).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.small)
                TextField("Or answer in your own words", text: $ownWords)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        let text = ownWords.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        ownWords = ""
                        pick(.text(text))
                    }
            }
            HStack(spacing: 10) {
                if !answers.isEmpty {
                    Button("Back") { answers.removeLast() }
                        .buttonStyle(.borderless).font(.caption)
                }
                Button("Skip") { store.decline(agentID) }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Don't answer. It then waits for you to say what to do instead.")
            }
        }
    }

    private func pick(_ answer: QuestionAnswer) {
        answers.append(answer)
        if answers.count == questions.count { store.answer(agentID, answers) }
    }
}
