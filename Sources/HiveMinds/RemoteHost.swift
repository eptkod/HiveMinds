import Foundation
import Observation
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet

/// The app's connection to one paired host (docs/HOST-PROTOCOL.md). It signs in with its token, keeps the host's
/// projects and agents in the store, follows its events, and reconnects by itself after a drop: with backoff, and
/// only while it's trying (nothing runs while it's connected or idle).
@MainActor @Observable
final class RemoteHost: Identifiable {
    enum Status: Equatable {
        case connecting
        case connected
        /// Not reachable; it keeps trying.
        case offline(String)
        /// The host was stopped on purpose.
        case stopped(String)
        /// One side needs updating; it doesn't retry.
        case incompatible(String)
        /// A different certificate answered: something else is at that address, or the host was set up again.
        case identityChanged
        /// The host doesn't accept this Mac any more (revoked or expired). Pair again.
        case unpaired

        var label: String {
            switch self {
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .offline(let why): why
            case .stopped(let why): why
            case .incompatible(let why): why
            case .identityChanged: "This host's identity changed. Pair again only if you trust it."
            case .unpaired: "This Mac isn't paired with it any more. Pair again."
            }
        }

        var isConnected: Bool { self == .connected }
        /// Whether it gave up until something changes (a new pairing, an update).
        var needsYou: Bool {
            switch self {
            case .incompatible, .identityChanged, .unpaired: true
            default: false
            }
        }
    }

    private(set) var record: PairedHost
    private(set) var status: Status = .offline("Not connected yet")
    /// The host's projects and agents, as it last said.
    private(set) var projects: [ProjectInfo] = []
    private(set) var agents: [UUID: AgentInfo] = [:]
    /// Where discovery last saw it, if it did.
    var discovered: (host: String, port: Int)?

    private let identity: Identity
    private let deviceName: () -> String
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var client: HostClient?
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var retryDelay: TimeInterval = 1
    @ObservationIgnored private var wanted = false

    init(record: PairedHost, identity: Identity, deviceName: @escaping () -> String, store: AppStore) {
        self.record = record
        id = record.id
        self.identity = identity
        self.deviceName = deviceName
        self.store = store
    }

    /// The host's random id. Pairing again keeps it (a different id is a different host).
    nonisolated let id: String
    var name: String { record.name }

    // MARK: Connecting

    /// Connects (and keeps reconnecting) until `disconnect`.
    func connect() {
        wanted = true
        guard client == nil, !status.needsYou else { return }
        retry?.cancel()
        status = .connecting
        let address = discovered ?? (record.address, record.port)
        let c = HostClient(identity: identity, queue: DispatchQueue(label: "hiveminds.host.\(record.id)"))
        client = c
        // The main queue keeps messages and frames in the order they came (a snapshot after its `resized`).
        c.onMessage = { [weak self] m in DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(m, from: c) } } }
        c.onFrame = { f in DispatchQueue.main.async { MainActor.assumeIsolated { RemoteTerminals.shared.received(f) } } }
        c.onClose = { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(c) } } }
        Task {
            do {
                try await c.connect(host: address.host, port: address.port, pinned: record.fingerprint)
                let hello = try await c.hello(client: "HiveMinds \(Bundle.main.appVersion)", deviceName: deviceName(), token: record.token)
                guard client === c else { return c.close() }
                switch hello {
                case .welcome(let w):
                    if record.address != address.host || record.port != address.port || record.name != w.hostName {
                        record.address = address.host
                        record.port = address.port
                        record.name = w.hostName
                        HostKeychain.save(record)
                    }
                    try await signedIn(c)
                case .pairingRequired:
                    give(up: .unpaired, c)
                case .incompatible(let i):
                    give(up: .incompatible(i.update == "host" ? "\(record.name) needs updating to work with this version of HiveMinds."
                                                              : "Update HiveMinds to use \(record.name)."), c)
                }
            } catch ClientError.identityChanged {
                give(up: .identityChanged, c)
            } catch {
                guard client === c else { return }
                client = nil
                c.close()
                status = .offline("\(record.name) is offline, reconnecting…")
                scheduleRetry()
            }
        }
    }

    private func give(up why: Status, _ c: HostClient) {
        client = nil
        c.close()
        status = why
        store?.remoteHostChanged(self)
    }

    private func signedIn(_ c: HostClient) async throws {
        let p = try await c.request(.listProjects)
        let a = try await c.request(.listAgents)
        guard client === c else { return }
        projects = p.projects ?? []
        agents = Dictionary((a.agents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        status = .connected
        retryDelay = 1
        store?.remoteSynced(self)
        RemoteTerminals.shared.reattach(hostID: id)
    }

    /// Stops connecting. Its agents keep running on the host.
    func disconnect() {
        wanted = false
        retry?.cancel()
        retry = nil
        let c = client
        client = nil
        c?.close()
        if !status.needsYou { status = .offline("Not connected") }
        store?.remoteHostChanged(self)
    }

    /// Pairing again replaces the record and starts over.
    func replace(_ newRecord: PairedHost) {
        record = newRecord
        status = .offline("Not connected yet")
        if wanted { connect() }
    }

    /// Discovery found it (again): try now rather than waiting for the next retry.
    func seen(at host: String, port: Int) {
        discovered = (host, port)
        if wanted, client == nil, !status.needsYou { connect() }
    }

    private func closed(_ c: HostClient) {
        guard client === c else { return }
        client = nil
        if case .stopped = status {
            // Stopped on purpose: wait for discovery to see it again, checking now and then in case it can't.
            scheduleRetry(after: 60)
        } else {
            status = .offline("\(record.name) is offline, reconnecting…")
            scheduleRetry()
        }
        store?.remoteHostChanged(self)
    }

    private func scheduleRetry(after fixed: TimeInterval? = nil) {
        guard wanted else { return }
        retry?.cancel()
        let delay = fixed ?? retryDelay
        retryDelay = min(retryDelay * 2, 60)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.client == nil, self.wanted else { return }
                self.connect()
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: What the host says

    private func received(_ m: HostMessage, from c: HostClient) {
        guard client === c, case .event(let e) = m else { return }
        switch e {
        case .agentUpdated(let a):
            agents[a.id] = a
            store?.remoteAgentUpdated(a, on: self)
        case .agentRemoved(let id):
            agents[id] = nil
            store?.remoteAgentRemoved(id)
        case .projectsChanged(let p):
            projects = p
            store?.remoteSynced(self)
        case .promptResolved(let id, let by, _):
            store?.remotePromptResolved(id, by: by, on: self)
        case .viewers, .controller:
            // The same news also comes as agentUpdated, which carries the whole agent.
            break
        case .resized(let id, let cols, let rows):
            RemoteTerminals.shared.resized(id, cols: cols, rows: rows)
        case .inputRefused(let id, let controller):
            RemoteTerminals.shared.refused(id, controller: controller)
        case .detached(let id, _):
            RemoteTerminals.shared.detached(id)
        case .deviceRevoked:
            status = .unpaired
            store?.remoteHostChanged(self)
        case .hostStopping(let reason, _):
            status = .stopped(reason == "systemStop" ? "\(record.name) was stopped by its system." : "\(record.name) was stopped.")
            store?.remoteHostChanged(self)
        }
    }

    // MARK: Asking the host

    func request(_ r: Request) async throws -> Reply {
        guard let c = client, status.isConnected else {
            throw HostRequestError("\(record.name) isn't connected right now.")
        }
        do {
            return try await c.request(r)
        } catch ClientError.host(let e) {
            throw HostRequestError(e.message, code: e.code)
        } catch {
            throw HostRequestError("\(record.name) didn't answer: \(error)")
        }
    }

    func send(frame: TerminalFrame) {
        guard status.isConnected else { return }
        client?.send(frame: frame)
    }
}

struct HostRequestError: Error, LocalizedError {
    var errorDescription: String?
    var code: String?
    init(_ s: String, code: String? = nil) {
        errorDescription = s
        self.code = code
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
