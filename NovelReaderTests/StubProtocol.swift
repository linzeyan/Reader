import Foundation

/// Answers requests out of a variable instead of off the network.
///
/// A `URLProtocol` rather than a protocol-shaped seam in `FeedService`: what is under
/// test includes the request it builds — the conditional headers are the point of half of
/// it — and only this level sees the request as the server would.
///
/// Shared by the two suites that need a network: one hands it to a session of its own,
/// the other registers it globally, because what it is testing runs through the app's
/// `URLSession.shared`.
final class StubProtocol: URLProtocol {
    enum Answer {
        case ok(String, headers: [String: String] = [:])
        case notModified
        case status(Int)
    }

    nonisolated(unsafe) static var answer: Answer = .status(500)
    /// Answers for named addresses, for the one path that fetches two documents: a page,
    /// and then the feed that page declares.
    nonisolated(unsafe) static var answersByURL: [String: Answer] = [:]
    /// Where the request "ended up", for the redirect case.
    nonisolated(unsafe) static var landedURL: URL?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        answer = .status(500)
        answersByURL = [:]
        landedURL = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        let url = Self.landedURL ?? request.url!
        let answer = Self.answersByURL[request.url?.absoluteString ?? ""] ?? Self.answer
        let (status, body, headers): (Int, Data?, [String: String]) = switch answer {
        case .ok(let text, let headers): (200, Data(text.utf8), headers)
        case .notModified: (304, nil, [:])
        case .status(let code): (code, nil, [:])
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
