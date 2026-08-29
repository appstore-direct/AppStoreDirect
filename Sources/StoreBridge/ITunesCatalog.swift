import Foundation

/// Catalogue search and lookup against Apple's **public** iTunes Search API.
///
/// This is the one part of the App Store surface that is documented, unauthenticated
/// and stable, so it is implemented natively rather than routed through the bridge.
/// It carries no credentials — the account only supplies the country code so results
/// match the storefront the user can actually install from.
public actor ITunesCatalog {
    private let session: URLSession
    private let host = "itunes.apple.com"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Free-text search, e.g. "Snapchat".
    public func search(
        term: String,
        countryCode: String,
        limit: Int = 25
    ) async throws -> [StoreApp] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/search"
        components.queryItems = [
            .init(name: "term", value: trimmed),
            .init(name: "country", value: countryCode),
            .init(name: "entity", value: "software"),
            .init(name: "media", value: "software"),
            .init(name: "limit", value: String(min(max(limit, 1), 200))),
        ]

        return try await fetch(components)
    }

    /// Exact lookup by bundle identifier — used to reconcile installed apps
    /// on the device with their store listings.
    public func lookup(bundleIDs: [String], countryCode: String) async throws -> [StoreApp] {
        guard !bundleIDs.isEmpty else { return [] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/lookup"
        components.queryItems = [
            .init(name: "bundleId", value: bundleIDs.joined(separator: ",")),
            .init(name: "country", value: countryCode),
            .init(name: "entity", value: "software"),
            .init(name: "limit", value: String(bundleIDs.count)),
        ]
        return try await fetch(components)
    }

    /// Lookup by Apple's numeric App Store ID.
    public func lookup(appStoreIDs: [Int64], countryCode: String) async throws -> [StoreApp] {
        guard !appStoreIDs.isEmpty else { return [] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/lookup"
        components.queryItems = [
            .init(name: "id", value: appStoreIDs.map(String.init).joined(separator: ",")),
            .init(name: "country", value: countryCode),
            .init(name: "entity", value: "software"),
        ]
        return try await fetch(components)
    }

    private func fetch(_ components: URLComponents) async throws -> [StoreApp] {
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Matches the client identity used everywhere else in the app.
        request.setValue(StoreUserAgent.value, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw StoreError.bridgeFailure(
                code: "catalog-\(code)",
                message: "App Store search is unavailable right now (HTTP \(code))."
            )
        }

        let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        return payload.results.compactMap(\.storeApp)
    }
}

/// The single place the client identity is defined. Apple's bag returns a different,
/// SAP-capable document for this agent — see docs/ARCHITECTURE.md §1.1.
public enum StoreUserAgent {
    public static let value = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
}

// MARK: - Wire format

private struct SearchResponse: Decodable {
    let results: [Entry]
}

private struct Entry: Decodable {
    let trackId: Int64?
    let bundleId: String?
    let trackName: String?
    let artistName: String?
    let version: String?
    let minimumOsVersion: String?
    let artworkUrl512: String?
    let artworkUrl100: String?
    let artworkUrl60: String?
    let price: Double?
    let currency: String?
    let fileSizeBytes: String?
    let averageUserRating: Double?
    let userRatingCount: Int?

    var storeApp: StoreApp? {
        // A result without an adam ID or bundle ID cannot be acquired or installed,
        // so it is dropped rather than shown as an un-installable row.
        guard let trackId, let bundleId, let trackName else { return nil }
        let artwork = artworkUrl512 ?? artworkUrl100 ?? artworkUrl60
        return StoreApp(
            appStoreID: trackId,
            bundleID: bundleId,
            name: trackName,
            developer: artistName ?? "",
            version: version ?? "",
            minimumOSVersion: minimumOsVersion ?? "",
            iconURL: artwork.flatMap(URL.init(string:)),
            price: price ?? 0,
            currency: currency ?? "",
            fileSizeBytes: fileSizeBytes.flatMap(Int64.init),
            averageRating: averageUserRating,
            ratingCount: userRatingCount
        )
    }
}
