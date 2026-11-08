import SwiftUI
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet

// MARK: On a remote agent

/// The host an agent runs on, as a quiet label. Nothing for an agent on This Mac.
struct HostLabel: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID

    var body: some View {
        if let host = store.remoteHost(of: agentID) {
            Label(host.name, systemImage: "server.rack")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Runs on \(host.name)")
        }
    }
}

/// Who's watching a remote agent (initials), who's typing, and Take Over when it's someone else.
struct TeamBar: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID
    /// Show "Take Over" as a button (tiles and tabs) rather than only saying who's typing.
    var offersTakeOver = true

    var body: some View {
        if let host = store.remoteHost(of: agentID) {
            HStack(spacing: 6) {
                let others = store.watchers(of: agentID).filter { $0.id != host.record.deviceID }
                if !others.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(others.prefix(4), id: \.id) { d in Initials(name: d.name) }
                    }
                    .help("Also watching: \(others.map(\.name).joined(separator: ", "))")
                }
                if let c = store.otherController(of: agentID) {
                    let refused = store.remoteRefused[agentID] != nil
                    Text("\(c.name) is typing")
                        .font(.caption2)
                        .foregroundStyle(refused ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    if offersTakeOver {
                        Button("Take Over") { store.takeControl(agentID) }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                            .help("Type here instead. \(c.name) sees that you took over, and the terminal takes your size.")
                    }
                } else if store.isController(of: agentID) && !others.isEmpty {
                    Text("You're typing").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .animation(Motion.bouncy, value: store.otherController(of: agentID)?.id)
        }
    }
}

private struct Initials: View {
    let name: String

    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(letters.isEmpty ? "?" : letters)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.white.opacity(0.14)))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .help(name)
    }
}

/// Over a remote agent's terminal while its host can't be reached: the last screen stays, greyed, with why.
struct HostOfflineCover: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID

    var body: some View {
        if let host = store.remoteHost(of: agentID), !host.status.isConnected {
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 8) {
                    Image(systemName: host.status.needsYou ? "exclamationmark.triangle" : "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text(host.status.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if host.status.needsYou {
                        Button("Pair Again…") { store.hosts.pairAgain(host) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
        }
    }
}

// MARK: Sidebar

/// "This Mac", above the projects on this Mac, once there are hosts too.
struct MachineHeader: View {
    var body: some View {
        Label("This Mac", systemImage: "laptopcomputer")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A paired host in the sidebar: its name and how it is, with what you can do about it.
struct HostHeader: View {
    @Environment(AppStore.self) private var store
    let host: RemoteHost

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text(host.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Circle().fill(dotColor).frame(width: 6, height: 6)
                .help(host.status.label)
            Spacer()
            Menu {
                switch host.status {
                case .connected:
                    Button("Disconnect") { host.disconnect() }
                case .incompatible, .identityChanged, .unpaired:
                    Button("Pair Again…") { store.hosts.pairAgain(host) }
                default:
                    Button("Connect Now") { host.connect() }
                }
                Divider()
                Button("Forget This Host…", role: .destructive) { store.pendingForgetHost = host }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 8)
            .help("Host options. Its agents keep running on it whatever you do here.")
        }
        .help(host.status.label)
    }

    private var dotColor: Color {
        switch host.status {
        case .connected: .green
        case .connecting: .yellow
        case .offline, .stopped: .secondary
        case .incompatible, .identityChanged, .unpaired: .orange
        }
    }
}

/// When a host's projects can't be shown: say why, in its place in the sidebar.
struct HostStatusRow: View {
    @Environment(AppStore.self) private var store
    let host: RemoteHost

    var body: some View {
        if !host.status.isConnected {
            Text(host.status.label)
                .font(.caption)
                .foregroundStyle(host.status.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(2)
        } else if store.shownProjects(on: host).isEmpty {
            Text("No projects yet. Add one on the host: hiveminds-host projects add <folder>")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
    }
}

/// A host on the network this Mac hasn't paired with: its address (its name stays private until pairing).
struct NearbyHostRow: View {
    @Environment(AppStore.self) private var store
    let nearby: HostsModel.Nearby

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(nearby.address ?? nearby.serviceName).lineLimit(1)
                Text("A HiveMinds host").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Pair…") {
                if let address = nearby.address { store.hosts.beginPairing(address: address, port: nearby.port ?? HostProtocol.defaultPort, expectedID: nearby.id) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(nearby.address == nil)
        }
    }
}

// MARK: Pairing

struct PairingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: PairingSession
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair with \(session.title)").font(.title3.weight(.semibold))
                    if !session.fingerprint.isEmpty {
                        Text("Fingerprint \(session.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .help("The host's terminal shows its fingerprint when it starts. They should match.")
                    }
                }
            }
            content
            HStack {
                Spacer()
                switch session.step {
                case .paired:
                    Button("Done") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                case .needsCode:
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                    Button("Pair") { session.submit(code: code) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(code.filter(\.isNumber).count != 6)
                default:
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .modifier(WindowAppearance())
        .onChange(of: session.step) { _, step in
            if case .needsCode = step { code = ""; codeFocused = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
        case .needsCode(let note):
            VStack(alignment: .leading, spacing: 8) {
                Text("Type the 6-digit pairing code shown in the host's terminal (or in `hiveminds-host pair` there).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("123 456", text: $code)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                    .onSubmit { if code.filter(\.isNumber).count == 6 { session.submit(code: code) } }
                    .onAppear { codeFocused = true }
                if let note { Text(note).font(.callout).foregroundStyle(.orange) }
                Text("A paired Mac can run commands on the host through its agents. Pair only hosts you trust.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the code…").foregroundStyle(.secondary) }
        case .waitingForOwner:
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text("The code is right. Waiting for the host's owner to allow this Mac (they press y in its terminal)…")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paired(let name):
            Label("Paired with \(name). Its projects show in the sidebar.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close() {
        session.cancel()
        store.hosts.pairing = nil
        dismiss()
    }
}

/// Pairing with a host by its address, for when discovery can't see it (another network, discovery off).
struct PairByAddressSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with a Host").font(.title3.weight(.semibold))
            Text("The address the host's terminal shows when it starts, like 192.168.1.20 or 192.168.1.20:7420.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.20", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Continue", action: go).keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .modifier(WindowAppearance())
    }

    private func go() {
        var host = address.trimmingCharacters(in: .whitespaces)
        var port = HostProtocol.defaultPort
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            if let p = Int(host[host.index(after: close)...].dropFirst()) { port = p }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let i = host.firstIndex(of: ":"), let p = Int(host[host.index(after: i)...]) {
            port = p
            host = String(host[..<i])
        }
        guard !host.isEmpty else { return }
        dismiss()
        store.hosts.beginPairing(address: host, port: port)
    }
}

// MARK: Settings > Hosts

struct HostSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingKey.hostsDiscover) private var discover = SettingDefault.hostsDiscover
    @AppStorage(SettingKey.hostsAutoConnect) private var autoConnect = SettingDefault.hostsAutoConnect
    @AppStorage(SettingKey.hostsDisplayName) private var displayName = SettingDefault.hostsDisplayName
    @State private var pairingByAddress = false
    @State private var forgetting: RemoteHost?

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: "Lists HiveMinds hosts on your local network in the sidebar, so you can pair without typing an address. Turning it off stops looking.") {
                    Toggle("Find hosts on my network", isOn: $discover)
                }
                SettingRow(explainer: "Paired hosts connect when HiveMinds opens, and reconnect by themselves after a drop.") {
                    Toggle("Connect to paired hosts at launch", isOn: $autoConnect)
                }
                SettingRow(explainer: "Shown to teammates watching the same agent, and written in hosts' logs. Takes effect the next time a host connects.") {
                    TextField("Your name", text: $displayName, prompt: Text(Host.current().localizedName ?? "Mac"))
                }
            } header: {
                Text("Hosts")
            } footer: {
                Text("A host is another machine running hiveminds-host. Its agents use its own Claude Code login and keep running when you quit HiveMinds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.hosts.hosts.isEmpty {
                    Text("No paired hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts.hosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                            Text(host.status.isConnected ? "Connected · \(host.record.address)" : host.status.label)
                                .font(.caption)
                                .foregroundStyle(host.status.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                            Text("Fingerprint \(Identity.display(host.record.fingerprint))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if host.status.needsYou {
                            Button("Pair Again…") { store.hosts.pairAgain(host) }
                        }
                        Button("Forget", role: .destructive) { forgetting = host }
                    }
                }
                Button("Pair with a Host by Address…") { pairingByAddress = true }
            } header: {
                Text("Paired hosts")
            } footer: {
                Text("Forget removes the pairing from this Mac. The host's agents keep running; on the host, `hiveminds-host devices revoke` removes this Mac from its side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = store.hosts.problem {
                Section { Text(problem).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: discover) { _, _ in store.hosts.settingsChanged() }
        .onChange(of: autoConnect) { _, on in if on { store.hosts.connectAll() } }
        .sheet(isPresented: $pairingByAddress) { PairByAddressSheet() }
        .confirmationDialog("Forget \(forgetting?.name ?? "this host")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let h = forgetting { store.hosts.forget(h) } }
        } message: {
            Text("This Mac disconnects and forgets its pairing. Its agents keep running on the host. To use it again, pair again.")
        }
    }
}

/// The pairing sheet and the Forget confirmation, wherever they're asked for.
struct HostDialogs: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { store.hosts.pairing }, set: { store.hosts.pairing = $0 })) { PairingSheet(session: $0) }
            .confirmationDialog("Forget \(store.pendingForgetHost?.name ?? "this host")?",
                                isPresented: Binding(get: { store.pendingForgetHost != nil }, set: { if !$0 { store.pendingForgetHost = nil } }),
                                presenting: store.pendingForgetHost) { host in
                Button("Forget", role: .destructive) { store.hosts.forget(host) }
            } message: { _ in
                Text("This Mac disconnects and forgets its pairing. Its agents keep running on the host. To use it again, pair again.")
            }
    }
}
