import SwiftUI
import AppKit
import WebKit

/// One browser tab's page. Its web view lives as long as the tab, so switching tabs doesn't reload it.
@MainActor @Observable
final class BrowserPage {
    let id: UUID
    @ObservationIgnored let webView: WKWebView
    var url = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let delegate = BrowserDelegate()

    init(tab: BrowserTab, onChange: @escaping (String, String) -> Void) {
        id = tab.id
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .black
        // See-through until a page draws, like the rest of the window.
        webView.setValue(false, forKey: "drawsBackground")
        webView.uiDelegate = delegate
        url = tab.url
        title = tab.title

        func watch<V>(_ path: KeyPath<WKWebView, V>, _ apply: @escaping (BrowserPage, WKWebView) -> Void) {
            observations.append(webView.observe(path, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let self { apply(self, view) } }
            })
        }
        watch(\.url) { page, view in
            guard let u = view.url?.absoluteString, u != page.url else { return }
            page.url = u
            onChange(page.url, page.title)
        }
        watch(\.title) { page, view in
            let t = view.title ?? ""
            guard !t.isEmpty, t != page.title else { return }
            page.title = t
            onChange(page.url, page.title)
        }
        watch(\.canGoBack) { page, view in page.canGoBack = view.canGoBack }
        watch(\.canGoForward) { page, view in page.canGoForward = view.canGoForward }
        watch(\.isLoading) { page, view in page.isLoading = view.isLoading }

        if let u = URL(string: tab.url), !tab.url.isEmpty { webView.load(URLRequest(url: u)) }
    }

    func open(_ input: String) {
        guard let u = Self.url(from: input) else { return }
        url = u.absoluteString
        webView.load(URLRequest(url: u))
    }

    /// What you type in the address field: a full address, a bare domain, a local port, or a search.
    static func url(from input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") { return URL(string: t) }
        if let port = Int(t), (1...65535).contains(port) { return URL(string: "http://localhost:\(port)") }
        let local = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].contains { t.hasPrefix($0) }
        if local { return URL(string: "http://\(t)") }
        if !t.contains(" "), t.contains(".") { return URL(string: "https://\(t)") }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: t)]
        return search.url
    }
}

/// Links that would open a new window open in the same tab instead.
private final class BrowserDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// The open pages, kept while their tabs exist.
@MainActor
enum Browsers {
    private static var pages: [UUID: BrowserPage] = [:]

    static func page(for tab: BrowserTab, store: AppStore) -> BrowserPage {
        if let p = pages[tab.id] { return p }
        let id = tab.id
        let p = BrowserPage(tab: tab) { [weak store] url, title in store?.browserTabChanged(id, url: url, title: title) }
        pages[tab.id] = p
        return p
    }

    /// The page if it's been opened this session, for tab titles.
    static func existing(_ id: UUID) -> BrowserPage? { pages[id] }

    static func close(_ id: UUID) {
        guard let p = pages.removeValue(forKey: id) else { return }
        p.webView.stopLoading()
        p.webView.removeFromSuperview()
    }
}

// MARK: Views

struct BrowserView: View {
    @Environment(AppStore.self) private var store
    let tab: BrowserTab
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let page = Browsers.page(for: tab, store: store)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!page.canGoBack)
                    .help("Back")
                Button { page.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!page.canGoForward)
                    .help("Forward")
                Button {
                    if page.isLoading { page.webView.stopLoading() } else { page.webView.reload() }
                } label: {
                    Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(page.url.isEmpty)
                .help(page.isLoading ? "Stop loading" : "Reload")

                TextField("Address", text: $address, prompt: Text("Search or type an address, or a port like 3000"))
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit { page.open(address); addressFocused = false }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .padding(.horizontal, 4)

                Button {
                    if let u = URL(string: page.url) { NSWorkspace.shared.open(u) }
                } label: { Image(systemName: "safari") }
                    .disabled(page.url.isEmpty)
                    .help("Open in your usual browser")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ZStack {
                WebViewHost(webView: page.webView)
                if page.url.isEmpty {
                    BrowserStartPage(project: store.project(tab.projectID)) { page.open($0) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding([.horizontal, .bottom], 14)
        }
        .onAppear {
            address = page.url
            if page.url.isEmpty { addressFocused = true }
        }
        .onChange(of: page.url) { _, new in if !addressFocused { address = new } }
    }
}

/// What a new tab shows: a few places you're likely to want while building.
struct BrowserStartPage: View {
    let project: Project?
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Type an address or search above")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(["3000", "5173", "8080"], id: \.self) { port in
                    Button("localhost:\(port)") { open(port) }
                }
                if let repo = project?.repo {
                    Button { open("https://github.com/\(repo)") } label: {
                        Label("\(repo) on GitHub", systemImage: "arrow.up.right")
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Puts a tab's long-lived web view into the SwiftUI layout.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
