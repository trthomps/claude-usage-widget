import Foundation

enum UsageError: Error, Equatable {
    case noCredentials
    case credentialsExpired
    case keychain(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case decoding(String)

    var title: String {
        switch self {
        case .noCredentials: "Not signed in"
        case .credentialsExpired: "Login expired"
        case .keychain: "Keychain access failed"
        case .unauthorized: "Login rejected"
        case .rateLimited: "Rate limited"
        case .http(let code): "Server error \(code)"
        case .network: "Offline"
        case .decoding: "Unexpected response"
        }
    }

    var message: String {
        switch self {
        case .noCredentials:
            "No Claude Code login found. Run \"claude\" in Terminal and sign in with your Claude account."
        case .credentialsExpired:
            "Claude Code's login token has expired. It renews the next time you use Claude Code, and usage updates then."
        case .keychain(let detail):
            "Couldn't read Claude Code's login from the Keychain: \(detail)"
        case .unauthorized:
            "Anthropic rejected the saved login. Run /login in Claude Code to sign in again."
        case .rateLimited(let retryAfter):
            "The usage API is rate limiting requests. Retrying \(retryAfter.map { "in " + Fmt.duration($0) } ?? "shortly")."
        case .http(let code):
            "The usage API returned HTTP \(code). Retrying automatically."
        case .network(let detail):
            "Couldn't reach Anthropic: \(detail)"
        case .decoding(let detail):
            "Couldn't read the usage response (\(detail))."
        }
    }

    var symbol: String {
        switch self {
        case .noCredentials, .unauthorized: "person.crop.circle.badge.questionmark"
        case .credentialsExpired: "clock.badge.exclamationmark"
        case .keychain: "key.slash"
        case .rateLimited: "hourglass"
        case .network: "wifi.slash"
        case .http, .decoding: "exclamationmark.triangle"
        }
    }
}

/// The endpoint Claude Code's /usage command reads.
struct UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-widget/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try UsageParser.parse(data)
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.http(http.statusCode)
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
