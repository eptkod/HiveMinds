import Foundation
import HiveMindsProtocol
#if canImport(Glibc)
import Glibc
#endif

/// `~/.local/state/hiveminds-host/audit.log`: who connected, paired, started, typed into, approved or deleted what
/// (docs/HOST-PROTOCOL.md §3). One JSON object per line, appended, 0600. Never what was typed.
final class AuditLog {
    let url: URL
    private var handle: FileHandle?

    init(_ url: URL) {
        self.url = url
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if fd >= 0 {
            fchmod(fd, 0o600)
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    /// Writes one entry. `device` is who did it, when it was a device.
    func write(_ event: String, device: DeviceInfo? = nil, address: String? = nil, agent: UUID? = nil, detail: String? = nil) {
        var entry: [String: Any] = ["time": AuditLog.stamp.string(from: Date()), "event": event]
        if let device { entry["device"] = ["id": device.id, "name": device.name] }
        if let address { entry["address"] = address }
        if let agent { entry["agent"] = agent.uuidString }
        if let detail { entry["detail"] = detail }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        handle?.write(data)
    }

    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One entry as a line for people: "2026-11-08 10:02:13  Ethan's MacBook Pro  paired  (192.168.1.31)".
    static func describe(_ e: [String: Any]) -> String {
        var time = e["time"] as? String ?? ""
        if let d = stamp.date(from: time) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            time = f.string(from: d)
        }
        let who = (e["device"] as? [String: Any])?["name"] as? String ?? "-"
        var line = "\(time)  \(who)  \(e["event"] as? String ?? "?")"
        if let agent = e["agent"] as? String { line += "  agent \(agent.prefix(8))" }
        if let detail = e["detail"] as? String { line += "  \(detail)" }
        if let address = e["address"] as? String { line += "  (\(address))" }
        return line
    }
}
