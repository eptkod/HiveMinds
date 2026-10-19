import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file or screenshot handed to a new agent along with its first request.
struct Attachment: Identifiable {
    enum Source {
        case file(URL)
        /// A pasted or dropped image that only exists in memory, saved as PNG when the agent starts.
        case image(Data)
    }

    let id = UUID()
    let source: Source
    let name: String
    let thumbnail: NSImage

    init(file url: URL) {
        source = .file(url)
        name = url.lastPathComponent
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        thumbnail = (isImage ? NSImage(contentsOf: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    init?(image: NSImage, name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        source = .image(png)
        self.name = name
        thumbnail = image
    }

    /// Copies the attachments into `folder` (names kept, duplicates numbered) and returns their paths.
    static func save(_ items: [Attachment], to folder: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        return try items.map { item in
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var name = item.name
            var n = 2
            while used.contains(name) { name = "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"); n += 1 }
            used.insert(name)
            let dest = folder.appending(path: name)
            switch item.source {
            case .file(let url): try fm.copyItem(at: url, to: dest)
            case .image(let data): try data.write(to: dest)
            }
            return dest.path
        }
    }

    /// The first request with the attachments listed after it, so the agent knows to read them.
    static func prompt(_ task: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return task }
        let list = paths.map { "- \($0)" }.joined(separator: "\n")
        let intro = paths.count == 1 ? "I've attached this file:" : "I've attached these files:"
        return (task.isEmpty ? "" : task + "\n\n") + intro + "\n" + list
    }

    /// What's on the pasteboard as attachments: copied files first, otherwise a copied image such as
    /// a screenshot. Empty when it holds only text, so ordinary text pastes are left alone.
    static func from(pasteboard pb: NSPasteboard) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { Attachment(file: $0) }
        }
        guard pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb) else { return [] }
        return Attachment(image: image, name: screenshotName()).map { [$0] } ?? []
    }

    static func screenshotName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(f.string(from: Date())).png"
    }

    /// Reads dropped items: Finder files and screenshot thumbnails come as file URLs, images from
    /// other apps (a browser, Preview) as image data.
    static func load(_ providers: [NSItemProvider], into add: @escaping @MainActor (Attachment) -> Void) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in add(Attachment(file: url)) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage, let a = Attachment(image: image, name: screenshotName()) else { return }
                    Task { @MainActor in add(a) }
                }
            }
        }
    }
}

/// The attachments under the request box: a small thumbnail per item with a button to remove it.
struct AttachmentStrip: View {
    @Binding var items: [Attachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(nsImage: item.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(item.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 140, alignment: .leading)
                        Button {
                            withAnimation(Motion.bouncy) { items.removeAll { $0.id == item.id } }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.squish)
                        .help("Remove")
                    }
                    .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .help(item.name)
                    .transition(Motion.enter)
                }
            }
        }
        .scrollIndicators(.never)
    }
}
