import Foundation

/// The URLSession the providers use unless a test injects its own.
public enum LLMSession {
    /// Ephemeral (no disk cache or cookies for prompt data). Per-request idle timeouts are set on
    /// each `URLRequest`; the long default resource timeout allows slow local models.
    public static let `default`: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

extension URLRequest {
    /// A JSON POST/GET request with the given extra headers.
    static func json(
        url: URL,
        method: String = "POST",
        body: [String: Any]? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}
