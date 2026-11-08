import Foundation
import HiveMindsCore
#if canImport(Glibc)
import Glibc
#endif

/// `config.json`: what the person running the host chose. Only registered project folders are ever offered.
struct HostConfig: Codable {
    /// The name shown to paired devices. Nil means the machine's name.
    var name: String?
    var projects: [Project] = []

    static func load(_ paths: Paths) throws -> HostConfig {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return HostConfig() }
        do {
            return try JSONDecoder().decode(HostConfig.self, from: Data(contentsOf: paths.configFile))
        } catch {
            throw HostError("Couldn't read \(paths.configFile.path): \(error.localizedDescription) Fix or remove it, then try again.")
        }
    }

    func save(_ paths: Paths) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writePrivate(enc.encode(self), to: paths.configFile)
    }

    /// The project at a folder, by its path (any spelling of it) or, failing that, by its name.
    func project(matching s: String) -> Project? {
        let path = HostConfig.standardize(s)
        return projects.first { $0.path == path } ?? projects.first { $0.name == s }
    }

    static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        // The real path (symlinks resolved, `..` gone) when it exists, so one folder is always one project.
        if let real = realpath(absolute, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }
}

/// The agents on this host, saved in `agents.json` so their conversations can be picked up after a restart.
final class AgentFile {
    private let url: URL
    private(set) var agents: [Agent] = []

    init(_ paths: Paths) throws {
        url = paths.agentsFile
        if FileManager.default.fileExists(atPath: url.path) {
            do { agents = try JSONDecoder().decode([Agent].self, from: Data(contentsOf: url)) }
            catch { throw HostError("Couldn't read \(url.path): \(error.localizedDescription)") }
        }
    }

    func put(_ agent: Agent) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
        save()
    }

    func remove(_ id: UUID) {
        agents.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? writePrivate(enc.encode(agents), to: url)
    }
}

/// A problem to tell the person at the terminal about, in plain words.
struct HostError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}
