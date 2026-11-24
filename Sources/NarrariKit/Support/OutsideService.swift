import Foundation

public enum ServiceAddressError: ProblemError, Equatable {
    case empty
    case malformed
    case notHTTPS
    case containsCredentials

    public var problem: Problem {
        switch self {
        case .empty: Problem("address.empty", "Enter the address of the service. It starts with https://.")
        case .malformed: Problem("address.malformed", "Enter a full address that starts with https://, such as https://host/v1.")
        case .notHTTPS: Problem("address.not-https", "Use an https address. Plain http is allowed only for this Mac (localhost).")
        case .containsCredentials: Problem("address.credentials", "Take the name and password out of the address. A key goes in the Key field.")
        }
    }
}

public struct ServiceAddress: Sendable, Equatable {
    private static let thisMac: Set<String> = ["localhost", "127.0.0.1", "::1"]
    private static let schemes: Set<String> = ["http", "https"]

    public let url: URL

    public init(_ text: String) throws(ServiceAddressError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), Self.schemes.contains(scheme),
            let host = components.host?.lowercased(), !host.isEmpty,
            let url = components.url
        else { throw .malformed }
        // A key belongs in the Keychain, never inside an address that is stored in settings.
        guard components.user == nil, components.password == nil else { throw .containsCredentials }
        let isThisMac = Self.thisMac.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard scheme == "https" || isThisMac else { throw .notHTTPS }
        self.url = url
    }

    // An address goes into settings only once it can be used; an empty field clears it.
    public static func isStorable(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || problem(with: text) == nil
    }

    // The message a settings field shows for this text, or nil when the address can be used.
    public static func problem(with text: String) -> String? {
        do {
            _ = try ServiceAddress(text)
            return nil
        } catch {
            return error.problem.message
        }
    }

    func endpoint(_ path: String) -> URL {
        url.appending(path: path)
    }
}

public enum OutsideService {
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    static func send(_ request: URLRequest, with session: URLSession) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response.statusCode)
    }
}

// A redirect could carry the key to another host or over plain http, so none is followed.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
