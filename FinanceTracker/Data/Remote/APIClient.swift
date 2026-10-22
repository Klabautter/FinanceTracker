import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BankProviderError.invalidResponse(endpoint: request.url?.path ?? "?")
        }
        return (data, http)
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport

    enum Method: String { case get = "GET", post = "POST" }

    func send(
        path: String,
        method: Method,
        queryItems: [URLQueryItem] = [],
        body: (some Encodable)? = nil as String?,
        bearerToken: String? = nil
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method.rawValue

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // Enable Banking & Co. liefern im Fehler-Body die konkrete
            // Ursache (z. B. abgelaufener Code), für sichtbare Fehler.
            let errorBody = String(data: data.prefix(500), encoding: .utf8)
            throw BankProviderError.requestFailed(
                endpoint: path,
                status: response.statusCode,
                body: errorBody
            )
        }
        return data
    }
}
