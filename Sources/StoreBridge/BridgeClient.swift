import Foundation

/// Transport for the `appstore-bridge` sidecar: newline-delimited JSON over pipes.
///
/// One process per operation. The sidecar holds session material in memory, so a
/// short life is the point — it starts, does one job, and exits.
actor BridgeClient {
    private let executableURL: URL
    private let protocolVersion = 1

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Locates the sidecar: inside the app bundle when shipped, next to the binary
    /// when running from a build directory.
    static func locateExecutable() -> URL? {
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()

        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "appstore-bridge"),
            executableDirectory?.appendingPathComponent("appstore-bridge"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/appstore-bridge"),
            // Running from a SwiftPM build directory (.build/debug/asdctl), where the
            // bridge is built one level up at .build/appstore-bridge.
            executableDirectory?
                .deletingLastPathComponent()
                .appendingPathComponent("appstore-bridge"),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs one request to completion, forwarding any progress events.
    ///
    /// - Parameter onEvent: called for each `event` line before the final response.
    func call<Result: Decodable & Sendable>(
        method: String,
        params: some Encodable & Sendable,
        onEvent: (@Sendable (String, Data) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executableURL

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // The sidecar must not inherit anything it does not need.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]

        do {
            try process.run()
        } catch {
            throw StoreError.bridgeUnavailable(error.localizedDescription)
        }

        // Send the request, then close stdin so the sidecar exits when finished.
        let payload = BridgeRequest(id: UUID().uuidString, method: method, params: params)
        do {
            let encoded = try JSONEncoder().encode(payload)
            input.fileHandleForWriting.write(encoded)
            input.fileHandleForWriting.write(Data("\n".utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw StoreError.bridgeUnavailable("could not send request")
        }

        defer {
            if process.isRunning { process.terminate() }
        }

        return try await withTaskCancellationHandler {
            try await readResponse(from: output, stderr: errors, onEvent: onEvent)
        } onCancel: {
            process.terminate()
        }
    }

    private func readResponse<Result: Decodable & Sendable>(
        from output: Pipe,
        stderr: Pipe,
        onEvent: (@Sendable (String, Data) -> Void)?
    ) async throws -> Result {
        let handle = output.fileHandleForReading
        var buffer = Data()
        let decoder = JSONDecoder()

        while true {
            // Drain complete lines already buffered before blocking for more.
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }

                let envelope = try? decoder.decode(BridgeEnvelope.self, from: Data(line))
                guard let envelope else { continue }

                if let name = envelope.event {
                    // `ready` is the handshake; anything else is progress.
                    if name == "ready" {
                        guard envelope.protocolVersion == protocolVersion else {
                            throw StoreError.bridgeUnavailable(
                                "the App Store helper is version \(envelope.protocolVersion ?? -1), expected \(protocolVersion)"
                            )
                        }
                        continue
                    }
                    if let onEvent, let data = envelope.data {
                        onEvent(name, data)
                    }
                    continue
                }

                guard let ok = envelope.ok else { continue }
                if ok {
                    guard let result = envelope.result else {
                        throw StoreError.bridgeUnavailable("empty response")
                    }
                    return try decoder.decode(Result.self, from: result)
                }
                throw Self.mapError(envelope.error)
            }

            let chunk = try handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
        }

        // The sidecar exited without answering: surface its stderr, already redacted
        // on the Go side, so a crash is diagnosable rather than silent.
        let diagnostics = (try? stderr.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw StoreError.bridgeUnavailable(
            diagnostics.isEmpty ? "the helper exited unexpectedly" : String(diagnostics.suffix(400))
        )
    }

    /// Maps the sidecar's stable error codes onto typed Swift errors, so the UI
    /// branches on the condition and never on message text.
    private static func mapError(_ error: BridgeEnvelope.Failure?) -> StoreError {
        guard let error else { return .bridgeUnavailable("unknown failure") }
        switch error.code {
        case "two-factor-required": return .twoFactorRequired
        case "session-expired":     return .sessionExpired
        case "licence-required":    return .licenceUnavailable(reason: error.message)
        case "paid-app":            return .paidAppsUnsupported(name: error.message)
        case "not-purchased":       return .notPurchased(name: error.message)
        default:                    return .bridgeFailure(code: error.code, message: error.message)
        }
    }
}

// MARK: - Wire types

private struct BridgeRequest<Params: Encodable & Sendable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

private struct BridgeEnvelope: Decodable {
    let id: String?
    let ok: Bool?
    let result: Data?
    let error: Failure?
    let event: String?
    let data: Data?
    let protocolVersion: Int?

    struct Failure: Decodable {
        let code: String
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, result, error, event, data, protocolVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(Failure.self, forKey: .error)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        // `result` and `data` are re-encoded rather than decoded here so the caller
        // can decode them into whatever concrete type the method returns.
        result = try container.decodeIfPresent(AnyCodable.self, forKey: .result)
            .flatMap { try? JSONEncoder().encode($0) }
        data = try container.decodeIfPresent(AnyCodable.self, forKey: .data)
            .flatMap { try? JSONEncoder().encode($0) }
    }
}

/// Minimal type-erased JSON value, used only to pass a sub-object through.
private struct AnyCodable: Codable {
    let value: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int64.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) { value = array }
        else if let dictionary = try? container.decode([String: AnyCodable].self) { value = dictionary }
        else { value = nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil:                          try container.encodeNil()
        case let bool as Bool:             try container.encode(bool)
        case let int as Int64:             try container.encode(int)
        case let double as Double:         try container.encode(double)
        case let string as String:         try container.encode(string)
        case let array as [AnyCodable]:    try container.encode(array)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        default:                           try container.encodeNil()
        }
    }
}
