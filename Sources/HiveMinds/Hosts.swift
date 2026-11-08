import Foundation
import Network
import Observation
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet

/// The hosts this Mac knows (docs/LINUX-HOST-SPEC.md §3): the paired ones, each with its connection, and the
/// unpaired ones discovery finds on the network. Discovery runs only while it's on in Settings > Hosts.
@MainActor @Observable
final class HostsModel {
    /// A host on the network that this Mac hasn't paired with. Only its address and id are known until pairing.
    struct Nearby: Identifiable, Hashable {
        var id: String
        var serviceName: String
        var address: String?
        var port: Int?
    }

    private(set) var hosts: [RemoteHost] = []
    private(set) var nearby: [Nearby] = []
    /// A problem worth showing in Settings (the Keychain, the network).
    private(set) var problem: String?
    /// The pairing sheet, when it's open.
    var pairing: PairingSession?

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var identity: Identity?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]
    @ObservationIgnored private var started = false

    init() {}

    /// Loads the paired hosts and connects to them (if that's on), and starts discovery (if that's on).
    func start(store: AppStore) {
        guard !started else { return }
        started = true
        self.store = store
        let records = HostKeychain.pairedHosts()
        if !records.isEmpty, let identity = ensureIdentity() {
            hosts = records.map { RemoteHost(record: $0, identity: identity, deviceName: HostDefaults.displayName, store: store) }
        }
        if HostDefaults.autoConnect { for h in hosts { h.connect() } }
        settingsChanged()
    }

    private func ensureIdentity() -> Identity? {
        if let identity { return identity }
        do {
            identity = try HostKeychain.deviceIdentity()
            return identity
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func host(_ id: String) -> RemoteHost? { hosts.first { $0.id == id } }

    /// Settings > Hosts changed: start or stop discovery.
    func settingsChanged() {
        if HostDefaults.discover { startBrowsing() } else { stopBrowsing() }
    }

    // MARK: Discovery

    private func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: HostProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { Task { @MainActor in self?.problem = "Couldn't look for hosts on the network: \(e.localizedDescription)" } }
        }
        b.start(queue: .main)
        browser = b
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        for c in resolving.values { c.cancel() }
        resolving = [:]
        nearby = []
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var next: [Nearby] = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata, let id = txt["id"], !id.isEmpty else { continue }
            if let h = host(id) {
                // A paired host: find its address, so a host that was offline is reached at once.
                if !h.status.isConnected { resolve(r.endpoint, id: id) }
                continue
            }
            var n = nearby.first { $0.id == id } ?? Nearby(id: id, serviceName: name)
            n.serviceName = name
            next.append(n)
            if n.address == nil { resolve(r.endpoint, id: id) }
        }
        nearby = next.sorted { $0.serviceName < $1.serviceName }
    }

    /// Finds a service's address by opening (and closing) a plain TCP connection to it: the host never sees more than
    /// a connection that ends before TLS. IPv4 first, since that's what a host listens on everywhere.
    private func resolve(_ endpoint: NWEndpoint, id: String) {
        guard resolving[id] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[id] = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint {
                        var address = "\(host)"
                        if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
                        self.resolved(id: id, address: address, port: Int(port.rawValue))
                    }
                    c.cancel()
                    self.resolving[id] = nil
                case .failed, .cancelled:
                    self.resolving[id] = nil
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func resolved(id: String, address: String, port: Int) {
        if let h = host(id) { h.seen(at: address, port: port) }
        if let i = nearby.firstIndex(where: { $0.id == id }) {
            nearby[i].address = address
            nearby[i].port = port
        }
    }

    // MARK: Pairing and forgetting

    /// Opens the pairing sheet for a host on the network, or one typed in by address.
    func beginPairing(address: String, port: Int = HostProtocol.defaultPort, expectedID: String? = nil, label: String? = nil) {
        guard let identity = ensureIdentity(), let store else { return }
        pairing = PairingSession(address: address, port: port, expectedID: expectedID, label: label, identity: identity) { [weak self] record in
            self?.paired(record, store: store)
        }
        pairing?.start()
    }

    func pairAgain(_ host: RemoteHost) {
        beginPairing(address: host.discovered?.host ?? host.record.address, port: host.discovered?.port ?? host.record.port,
                     expectedID: host.id, label: host.name)
    }

    private func paired(_ record: PairedHost, store: AppStore) {
        HostKeychain.save(record)
        if let existing = host(record.id) {
            existing.replace(record)
            existing.connect()
        } else if let identity {
            let h = RemoteHost(record: record, identity: identity, deviceName: HostDefaults.displayName, store: store)
            hosts.append(h)
            h.connect()
        }
        nearby.removeAll { $0.id == record.id }
    }

    /// Unpairs from this Mac's side: disconnects and forgets the token. The host's agents keep running.
    func forget(_ host: RemoteHost) {
        host.disconnect()
        HostKeychain.forget(host.id)
        hosts.removeAll { $0 === host }
        store?.remoteHostForgotten(host)
    }

    func connectAll() { for h in hosts { h.connect() } }
}

/// The pairing sheet's steps (docs/HOST-PROTOCOL.md §2.3).
@MainActor @Observable
final class PairingSession: Identifiable {
    enum Step: Equatable {
        case connecting
        /// Ask for the code shown on the host. `note` explains a wrong try.
        case needsCode(note: String?)
        case checking
        case waitingForOwner
        case paired(String)
        case failed(String)
    }

    let id = UUID()
    let address: String
    let port: Int
    /// The host's name when it's known (pairing again); otherwise the sheet shows the address.
    let label: String?
    private(set) var step: Step = .connecting
    /// The host's fingerprint, grouped, to compare with what the host's terminal shows.
    private(set) var fingerprint = ""
    @ObservationIgnored private let expectedID: String?
    @ObservationIgnored private let client: HostClient
    @ObservationIgnored private let onPaired: (PairedHost) -> Void
    @ObservationIgnored private var hostID = ""

    init(address: String, port: Int, expectedID: String?, label: String?, identity: Identity, onPaired: @escaping (PairedHost) -> Void) {
        self.address = address
        self.port = port
        self.expectedID = expectedID
        self.label = label
        self.onPaired = onPaired
        client = HostClient(identity: identity)
    }

    var title: String { label ?? (port == HostProtocol.defaultPort ? address : "\(address):\(port)") }

    func start() {
        Task {
            do {
                try await client.connect(host: address, port: port, pinned: nil)
                fingerprint = Identity.display(client.hostFingerprint ?? "")
                switch try await client.hello(client: "HiveMinds \(Bundle.main.appVersion)", deviceName: HostDefaults.displayName(), token: nil) {
                case .pairingRequired(let p):
                    hostID = p.hostId
                    if let expectedID, expectedID != p.hostId {
                        step = .failed("A different host answered at \(address). Check the address, or pair with it as a new host.")
                    } else {
                        step = .needsCode(note: nil)
                    }
                case .incompatible(let i):
                    step = .failed(i.update == "host" ? "This host needs updating to work with this version of HiveMinds." : "Update HiveMinds to pair with this host.")
                case .welcome:
                    step = .failed("This host already knows this Mac.")
                }
            } catch {
                step = .failed("Couldn't reach a host at \(title). Check it's running (`hiveminds-host serve`) and on this network. (\(error))")
            }
        }
    }

    func submit(code raw: String) {
        let code = raw.filter(\.isNumber)
        guard code.count == 6 else { return step = .needsCode(note: "The code has 6 digits.") }
        step = .checking
        let waiting: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.step = .waitingForOwner } }
        }
        Task {
            do {
                let (token, welcome) = try await client.pair(code: code, deviceName: HostDefaults.displayName(), onWaiting: waiting)
                let record = PairedHost(id: welcome.hostId, name: welcome.hostName, fingerprint: client.hostFingerprint ?? "",
                                        token: token, address: address, port: port, deviceID: welcome.device.id)
                client.close()
                step = .paired(welcome.hostName)
                onPaired(record)
            } catch ClientError.host(let e) {
                switch e.code {
                case "wrongCode":
                    let left = e.triesLeft ?? 0
                    step = .needsCode(note: "That isn't the code on the host. \(left) \(left == 1 ? "try" : "tries") left.")
                case "tooManyTries", "noCode":
                    step = .needsCode(note: "That code can't be used any more. Press p on the host for a new one, then type it here.")
                case "busy":
                    step = .needsCode(note: "Another device is pairing with this host right now. Try again in a minute.")
                case "notAllowed":
                    step = .failed("The host's owner didn't allow this Mac.")
                default:
                    step = .failed(e.message)
                }
            } catch {
                step = .failed("\(error)")
            }
        }
    }

    func cancel() { client.close() }
}

/// Settings > Hosts as plain values.
enum HostDefaults {
    private static var d: UserDefaults { .standard }
    static var discover: Bool { d.object(forKey: SettingKey.hostsDiscover) as? Bool ?? SettingDefault.hostsDiscover }
    static var autoConnect: Bool { d.object(forKey: SettingKey.hostsAutoConnect) as? Bool ?? SettingDefault.hostsAutoConnect }
    /// The name teammates and host logs see.
    static func displayName() -> String {
        let s = (d.string(forKey: SettingKey.hostsDisplayName) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (Host.current().localizedName ?? "Mac") : String(s.prefix(80))
    }
}
