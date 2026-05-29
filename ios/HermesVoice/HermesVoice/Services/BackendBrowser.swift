import Foundation
import Network

/// A backend discovered on the LAN via Bonjour. `txt` is read at browse time
/// (NWBrowser hands us the TXT record for free), so we know the scheme / path /
/// canonical host before resolving.
struct DiscoveredBackend: Identifiable, Hashable {
    let id = UUID()
    let name: String          // Bonjour instance name, e.g. "Hermes Voice"
    let serviceType: String   // "_hermes-voice._tcp." (trailing dot, from NWBrowser)
    let domain: String        // "local."
    var txt: [String: String] = [:]
}

/// Discovers `_hermes-voice._tcp` on the local network and resolves a chosen
/// service into a usable base URL.
///
/// Hybrid approach (Apple-DTS-recommended): `NWBrowser` browses (modern, gives
/// the TXT record for free), then `NetService` resolves the selected service to
/// a DNS hostname + port — the Network framework has no resolve-without-connect
/// API, and NetService is the supported way to get a hostname for URLSession.
///
/// mDNS is link-local only (it does NOT traverse Tailscale), so this finds the
/// backend only on the same Wi-Fi. The URL is built preferring a `host` the
/// backend advertises in TXT (e.g. a Tailscale MagicDNS name) so an HTTPS cert
/// validates; otherwise the resolved `.local` host is used.
///
/// Requires `NSBonjourServices` listing `_hermes-voice._tcp` in Info.plist —
/// without it, browsing silently returns nothing.
@MainActor
final class BackendBrowser: NSObject, ObservableObject {
    @Published private(set) var results: [DiscoveredBackend] = []
    @Published private(set) var resolvedURL: URL?
    @Published private(set) var resolveError: String?
    @Published private(set) var isResolving = false

    private var browser: NWBrowser?
    private var resolving: NetService?
    private var resolvingBackend: DiscoveredBackend?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_hermes-voice._tcp", domain: "local."
        )
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] found, _ in
            Task { @MainActor in self?.apply(found) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving?.stop()
        resolving = nil
        isResolving = false
    }

    private func apply(_ found: Set<NWBrowser.Result>) {
        var mapped: [DiscoveredBackend] = []
        for r in found {
            guard case let .service(name, type, domain, _) = r.endpoint else { continue }
            var item = DiscoveredBackend(name: name, serviceType: type, domain: domain)
            if case let .bonjour(txt) = r.metadata {
                item.txt = txt.dictionary
            }
            mapped.append(item)
        }
        results = mapped.sorted { $0.name < $1.name }
    }

    /// Resolve a discovered backend to a URL. Result lands in `resolvedURL`.
    func resolve(_ backend: DiscoveredBackend, timeout: TimeInterval = 5) {
        resolving?.stop()
        resolveError = nil
        resolvedURL = nil
        isResolving = true
        // NetService.resolve needs a live RunLoop; the main RunLoop always is.
        let svc = NetService(domain: backend.domain, type: backend.serviceType, name: backend.name)
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        resolving = svc
        resolvingBackend = backend
        svc.resolve(withTimeout: timeout)
    }

    private func buildURL(host: String, port: Int, txt: [String: String]) -> URL? {
        // Bonjour hostnames carry a trailing dot ("hermes.local.") that some TLS
        // stacks reject — strip it.
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        // Prefer a cert-valid canonical host the backend advertised (e.g. a
        // Tailscale MagicDNS name) so HTTPS validates; else the resolved host.
        let canonical = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
        let scheme = txt["scheme"] ?? "http"
        let path = txt["path"] ?? ""

        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = canonical ?? cleanHost
        comps.port = port
        if !path.isEmpty && path != "/" {
            comps.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        return comps.url
    }
}

extension BackendBrowser: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        // Delegate fires on the main RunLoop (we scheduled it there). Read the
        // value-type results here, then hop to the actor — don't capture the
        // non-Sendable NetService into the Task.
        let host = sender.hostName
        let port = sender.port
        sender.stop()
        Task { @MainActor in
            self.isResolving = false
            if let host, let backend = self.resolvingBackend {
                self.resolvedURL = self.buildURL(host: host, port: port, txt: backend.txt)
            } else {
                self.resolveError = "Couldn't resolve host"
            }
            self.resolving = nil
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
        Task { @MainActor in
            self.isResolving = false
            self.resolveError = "Resolve failed"
            self.resolving = nil
        }
    }
}
