import SwiftUI
import HiveMindsCore
import HiveMindsProtocol

// The agent model (Provider, Agent, Project, AgentStatus, …) lives in HiveMindsCore, shared with HiveMinds Host.
// What's here is only for the app's own screens.

extension AgentStatus {
    var color: Color {
        switch self {
        case .asleep: .secondary
        case .starting: .secondary
        case .idle: .purple
        case .working: .blue
        case .needsYou: .orange
        case .done: .green
        }
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case agents = "Agents", meetings = "Meetings", github = "GitHub"
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case overview
    /// Every agent, including deleted ones.
    case history
    /// A project's workspace on its Canvas tab.
    case project(UUID)
    case agent(UUID)
    case browser(UUID)
    /// A shell (terminal) open as a tab in a project's workspace.
    case shell(UUID)
    /// A meeting's overview, opened as a tab in its project's workspace.
    case meeting(UUID)
}

/// A web page open as a tab in a project's workspace.
struct BrowserTab: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
    var url = ""
    var title = ""
}

/// A shell open as a tab in a project's workspace, started in the project's folder.
struct ShellTab: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
}
