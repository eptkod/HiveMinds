import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Follows a file that grows a line at a time (Claude Code's hook events, one JSON object per line), using a
/// kernel file watch rather than polling: a vnode source on macOS, inotify on Linux. Starts at the file's
/// current end, and calls `onEvent` on `queue` for each complete line that parses as a JSON object.
package final class EventTail {
    private let source: DispatchSourceProtocol
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var buffer = Data()
    private let onEvent: ([String: Any]) -> Void

    package init?(url: URL, queue: DispatchQueue = .main, onEvent: @escaping ([String: Any]) -> Void) {
        #if os(macOS)
        let fd = open(url.path, O_RDONLY | O_EVTONLY)
        #else
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        #endif
        guard fd >= 0 else { return nil }
        self.onEvent = onEvent
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        offset = handle.seekToEndOfFile()
        #if os(macOS)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.readNew() }
        #else
        let watch = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard watch >= 0, inotify_add_watch(watch, url.path, UInt32(IN_MODIFY)) >= 0 else {
            if watch >= 0 { close(watch) }
            return nil
        }
        source = DispatchSource.makeReadSource(fileDescriptor: watch, queue: queue)
        source.setEventHandler { [weak self] in
            // Drain the notifications; what changed is read from the file itself.
            var scratch = [UInt8](repeating: 0, count: 4096)
            while read(watch, &scratch, scratch.count) > 0 {}
            self?.readNew()
        }
        source.setCancelHandler { close(watch) }
        #endif
        source.resume()
    }

    deinit { source.cancel() }

    private func readNew() {
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onEvent(obj)
            }
        }
    }
}
