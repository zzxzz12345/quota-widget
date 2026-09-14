import Foundation
@testable import QuotaWidget

/// Helpers for driving providers without touching the network.
enum Stub {
    static func client(
        status: Int = 200,
        body: String,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) -> HTTPClient {
        var client = HTTPClient()
        client.transport = { request in
            onRequest?(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
        return client
    }

    /// Routes by URL substring so multi-call providers can be stubbed per endpoint.
    static func routing(
        _ routes: [String: (status: Int, body: String)],
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) -> HTTPClient {
        var client = HTTPClient()
        client.transport = { request in
            onRequest?(request)
            let url = request.url!.absoluteString
            let match = routes.first { url.contains($0.key) }
            let status = match?.value.status ?? 404
            let body = match?.value.body ?? "{\"error\":\"no stub for \(url)\"}"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
        return client
    }

    static func store(environment: [String: String] = [:], authFiles: [String: String] = [:]) -> CredentialStore {
        var parsed: [String: JSON] = [:]
        for (path, json) in authFiles {
            parsed[path] = try! JSON.parse(Data(json.utf8))
        }
        return CredentialStore(environment: environment, authFiles: parsed)
    }

    static func context(
        _ config: ProviderConfig,
        client: HTTPClient,
        store: CredentialStore
    ) -> ProviderContext {
        ProviderContext(credentials: store, http: client, config: config)
    }
}

/// Records values a stubbed transport observed, so tests can assert on the
/// outgoing request without fighting closure capture rules.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var headers: [String: String] = [:]

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        if let url = request.url?.absoluteString {
            urls.append(url)
        }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key.lowercased()] = value
        }
    }

    var recordedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    func url(containing fragment: String) -> String? {
        recordedURLs.first { $0.contains(fragment) }
    }

    func header(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return headers[name.lowercased()]
    }
}

extension ProviderStatus {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var unconfiguredReason: String? {
        if case .notConfigured(let reason) = self { return reason }
        return nil
    }
}

extension ProviderQuota {
    func window(_ id: String) -> QuotaWindow? {
        windows.first { $0.id == id }
    }

    func metric(_ id: String) -> QuotaMetric? {
        metrics.first { $0.id == id }
    }
}
