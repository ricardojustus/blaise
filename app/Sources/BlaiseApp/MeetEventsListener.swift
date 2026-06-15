import BlaiseCore
import Foundation
import Network
import os

/// The C12 contract consumer's transport shell: a loopback-only HTTP
/// listener on 127.0.0.1:18429. All contract logic (decrypt, acks, status
/// semantics, ingestion) lives in `MeetEventsIngestor` (BlaiseCore,
/// unit-tested); this actor only parses the HTTP request, calls the
/// ingestor, and writes the signed response.
///
/// Resilience (contract): if the port is occupied, log + Settings banner +
/// a rebind retry every 60 s; the banner clears on a successful bind. A
/// squatter receives ciphertext only; the extension's unsigned responses
/// fall into its network-class retry path.
actor MeetEventsListener {
    static let port: UInt16 = 18429
    static let endpointPath = "/v1/meet-events"

    private let ingestor: MeetEventsIngestor
    private let status: ListenerStatusHolder
    private var listener: NWListener?
    private var rebindTask: Task<Void, Never>?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "meet.listener")

    init(ingestor: MeetEventsIngestor, status: ListenerStatusHolder) {
        self.ingestor = ingestor
        self.status = status
    }

    func start() {
        // FIELD FAILURE 2026-06-11: dev/demo instances on BLAISE_DATA_ROOT
        // overrides squatted the production port with valid signed acks and
        // swallowed two meetings' batches into throwaway databases. Only an
        // instance on the real data root binds (opt-in via
        // BLAISE_MEET_LISTENER=1 for deliberate integration tests).
        guard MeetEventsListenerPolicy.bindAllowed() else {
            logger.notice(
                "meet-events listener disabled: BLAISE_DATA_ROOT override active (set BLAISE_MEET_LISTENER=1 to opt in)"
            )
            return
        }
        bind()
    }

    func stop() {
        rebindTask?.cancel()
        rebindTask = nil
        listener?.cancel()
        listener = nil
    }

    private func bind() {
        listener?.cancel()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = false
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleStateChange(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(connection) }
            }
            listener.start(queue: DispatchQueue(label: BlaiseBundle.subsystem("meet.listener")))
            self.listener = listener
        } catch {
            handleBindFailure("\(error)")
        }
    }

    private func handleStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            logger.info("meet-events listener bound on 127.0.0.1:\(Self.port)")
            await MainActor.run { status.banner = nil }
        case .failed(let error):
            handleBindFailure("\(error)")
        default:
            break
        }
    }

    private func handleBindFailure(_ detail: String) {
        logger.error("meet-events port \(Self.port) unavailable: \(detail, privacy: .public) — retrying in 60 s")
        let status = status
        Task { @MainActor in
            status.banner =
                "Another process is using port \(Self.port); Meet extension events are buffering. Retrying every 60 s."
        }
        listener?.cancel()
        listener = nil
        rebindTask?.cancel()
        rebindTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.bind()
        }
    }

    // MARK: - One connection (request → ingestor → signed response)

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: BlaiseBundle.subsystem("meet.conn")))
        defer { connection.cancel() }
        guard let request = try? await readRequest(connection) else { return }
        guard request.method == "POST", request.path == Self.endpointPath else {
            try? await send(connection, status: 404, headers: [:])
            return
        }
        let response = await ingestor.handle(body: request.body)
        var headers: [String: String] = [:]
        if let ack = response.ackHeaderValue {
            headers[MeetEventsCrypto.ackHeader] = ack
        }
        try? await send(connection, status: response.status, headers: headers)
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    /// Minimal HTTP/1.1 request reader: headers, Content-Length, body.
    /// Anything malformed or oversized aborts the connection (the extension
    /// sees a network-class failure and ring-retries).
    private func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        let headerEnd = Data("\r\n\r\n".utf8)
        // Batches are ≤ 64 KiB by construction; cap defensively at 4 MiB.
        let maxBytes = 4 * 1024 * 1024

        while buffer.range(of: headerEnd) == nil {
            guard buffer.count < maxBytes else { throw ListenerError.oversized }
            buffer.append(try await receiveChunk(connection))
        }
        let headerRange = buffer.range(of: headerEnd)!
        let headerData = buffer.prefix(upTo: headerRange.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw ListenerError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ListenerError.malformed }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength <= maxBytes else { throw ListenerError.oversized }

        var body = Data(buffer.suffix(from: headerRange.upperBound))
        while body.count < contentLength {
            body.append(try await receiveChunk(connection))
        }
        return HTTPRequest(method: method, path: path, body: body.prefix(contentLength))
    }

    private enum ListenerError: Error {
        case malformed, oversized, closed
    }

    private func receiveChunk(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ListenerError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String]) async throws {
        let reason: String =
            switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            default: "Internal Server Error"
            }
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }
}
