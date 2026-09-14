import Foundation

enum HTTPFailure: LocalizedError {
    case invalidURL(String)
    case transport(String)
    case status(code: Int, body: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .transport(let message): return message
        case .status(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            return detail.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(detail)"
        case .decode(let message): return "Unreadable response: \(message)"
        }
    }

    /// A 401/403 means the credential is wrong, which is worth surfacing
    /// differently from a transient network problem.
    var isAuthFailure: Bool {
        if case .status(let code, _) = self { return code == 401 || code == 403 }
        return false
    }
}

struct HTTPClient {
    /// Swap-in point for tests, which return canned responses instead of
    /// reaching the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    var timeout: TimeInterval = 20
    var userAgent: String = "QuotaWidget/1.0 (macOS)"
    var transport: Transport?

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func getJSON(_ urlString: String, headers: [String: String] = [:]) async throws -> JSON {
        let (data, response) = try await get(urlString, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPFailure.status(
                code: response.statusCode,
                body: Self.messageFromErrorBody(body) ?? body
            )
        }
        do {
            return try JSON.parse(data)
        } catch {
            throw HTTPFailure.decode(error.localizedDescription)
        }
    }

    /// Providers bury the useful text in different places (`message`, `msg`,
    /// `error.message`, `detail`, `base_resp.status_msg`). Dig it out so the
    /// panel shows a sentence instead of a raw JSON blob.
    static func messageFromErrorBody(_ body: String) -> String? {
        guard let json = try? JSON.parse(Data(body.utf8)) else { return nil }
        let candidates = [
            "message", "msg", "detail", "error", "error.message",
            "base_resp.status_msg", "error.description"
        ]
        for pointer in candidates {
            if let value = json.string(at: pointer) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    func get(_ urlString: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw HTTPFailure.invalidURL(urlString) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPFailure.transport("No HTTP response from \(url.host ?? urlString)")
            }
            return (data, http)
        } catch let failure as HTTPFailure {
            throw failure
        } catch let error as URLError {
            throw HTTPFailure.transport(Self.describe(error))
        } catch {
            throw HTTPFailure.transport(error.localizedDescription)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport {
            return try await transport(request)
        }
        return try await session.data(for: request)
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "Request timed out"
        case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
        case .cannotFindHost, .cannotConnectToHost: return "Cannot reach host"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS connection failed"
        default: return error.localizedDescription
        }
    }
}
