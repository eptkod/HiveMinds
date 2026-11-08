import Foundation
import CDNSSD
import CHiveMindsSystem
import HiveMindsProtocol
#if canImport(Glibc)
import Glibc
#endif

/// Announces the host on the local network as `_hiveminds._tcp` (docs/HOST-PROTOCOL.md §4): service name
/// `hiveminds-<first 8 of the host id>`, TXT `v=<protocol>` and `id=<host id>`. No machine, user or project names.
package final class Announcer {
    private var ref: UnsafeMutableRawPointer?
    private var source: DispatchSourceRead?
    package let name: String

    /// Starts announcing. Throws with a message when the mDNS daemon or Avahi's library isn't there.
    package init(hostID: String, port: Int, queue: DispatchQueue) throws {
        name = "hiveminds-\(hostID.prefix(8))"
        var txt: [UInt8] = []
        for entry in ["v=\(HostProtocol.version)", "id=\(hostID)"] {
            let bytes = Array(entry.utf8)
            txt.append(UInt8(bytes.count))
            txt += bytes
        }
        var r: UnsafeMutableRawPointer?
        var fd: Int32 = -1
        var err = [CChar](repeating: 0, count: 256)
        let code = txt.withUnsafeBufferPointer { t in
            hiveminds_dnssd_register(name, HostProtocol.serviceType, UInt16(port), t.baseAddress, UInt16(t.count), &r, &fd, &err, err.count)
        }
        guard code == 0, let r else { throw DiscoveryError(String(cString: err)) }
        ref = r
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in
            guard let ref = self?.ref else { return }
            _ = hiveminds_dnssd_process(ref)
        }
        source = s
        s.resume()
    }

    /// The name the network ended up giving it (after renaming on a clash), once confirmed.
    package var registeredName: String? {
        guard let ref else { return nil }
        let s = String(cString: hiveminds_dnssd_registered_name(ref))
        return s.isEmpty ? nil : s
    }

    package func stop() {
        source?.cancel()
        source = nil
        if let ref { hiveminds_dnssd_stop(ref) }
        ref = nil
    }

    deinit { stop() }
}

package struct DiscoveryError: Error, CustomStringConvertible {
    package var description: String
    init(_ s: String) { description = s }
}

/// Calls `onChange` (on `queue`, at most once a second) when this machine's network addresses change.
package final class AddressWatch {
    private var source: DispatchSourceRead?
    private var pending = false

    package init?(queue: DispatchQueue, onChange: @escaping () -> Void) {
        let fd = hiveminds_address_watch_open()
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while read(fd, &buf, buf.count) > 0 {}
            guard let self, !self.pending else { return }
            // Address changes come in bursts (DHCP, Wi-Fi joining): look once they've settled.
            self.pending = true
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.pending = false
                onChange()
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    deinit { source?.cancel() }
}
