import Foundation
import Network
import SwiftData
import UniformTypeIdentifiers

/// API HTTP locale (127.0.0.1 uniquement) utilisee par le serveur MCP (voxa_mcp.py)
/// pour piloter Voxa depuis Claude Code.
///
/// Authentification : jeton Bearer aleatoire ecrit dans
/// ~/Library/Application Support/Voxa/api.json (permissions 600), avec le port.
final class LocalAPIServer {
    #if APPSTORE
    // Port different : les versions DMG et App Store peuvent etre installees ensemble
    static let defaultPort: UInt16 = 47822
    #else
    static let defaultPort: UInt16 = 47821
    #endif

    private let listVM: TranscriptionListVM
    private let modelContainer: ModelContainer
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.pierre.Voxa.api")
    private let token: String

    static var configFileURL: URL {
        AppPaths.appSupportDirectory.appendingPathComponent("api.json")
    }

    static var mcpScriptPath: String {
        AppPaths.scriptsDirectory.appendingPathComponent("voxa_mcp.py").path
    }

    init(listVM: TranscriptionListVM, modelContainer: ModelContainer) {
        self.listVM = listVM
        self.modelContainer = modelContainer
        self.token = Self.loadOrCreateToken()
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.defaultPort)!
            )
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                print("[API] Listener: \(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
            writeConfig()
        } catch {
            print("[API] ERREUR demarrage: \(error)")
        }
    }

    // MARK: - Token / config

    private static func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: configFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["token"] as? String, !token.isEmpty {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeConfig() {
        let config: [String: Any] = [
            "port": Int(Self.defaultPort),
            "token": token,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.pierre.Voxa",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else { return }
        let url = Self.configFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - HTTP plumbing

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json; charset=utf-8"

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return Response(status: status, body: data)
        }

        static func error(_ message: String, status: Int) -> Response {
            .json(["error": message], status: status)
        }

        static func text(_ string: String) -> Response {
            Response(status: 200, body: Data(string.utf8), contentType: "text/plain; charset=utf-8")
        }
    }

    private static let maxBodySize = 10 * 1024 * 1024

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                Task { @MainActor in
                    let response = await self.route(request)
                    self.send(response, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > Self.maxBodySize {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Retourne nil tant que la requete n'est pas complete.
    static func parse(_ data: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return Request(
            method: String(requestLine[0]),
            path: components?.path ?? "/",
            query: query,
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                      500: "Internal Server Error"][response.status] ?? "OK"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    @MainActor
    private func route(_ request: Request) async -> Response {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .error("Unauthorized", status: 401)
        }

        let parts = request.path.split(separator: "/").map(String.init)
        let context = modelContainer.mainContext

        switch (request.method, parts.count) {
        case ("GET", 1) where parts[0] == "health":
            return .json(["status": "ok", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""])

        case ("GET", 1) where parts[0] == "speakers":
            return .json(["speakers": knownSpeakers()])

        case ("GET", 1) where parts[0] == "transcriptions":
            return listTranscriptions(request.query, context: context)

        case ("POST", 1) where parts[0] == "transcriptions":
            return await createTranscription(request.body, context: context)

        case (_, 2...) where parts[0] == "transcriptions":
            guard let id = UUID(uuidString: parts[1]),
                  let project = fetchProject(id, context: context) else {
                return .error("Transcription not found: \(parts[1])", status: 404)
            }
            let action = parts.count > 2 ? parts[2] : ""
            switch (request.method, action) {
            case ("GET", ""):
                return .json(summary(of: project))
            case ("GET", "transcript"):
                return transcript(of: project, query: request.query)
            case ("GET", "export"):
                let format = ExportFormat(rawValue: request.query["format"] ?? "md") ?? .md
                return .text(ExportService.export(project: project, format: format))
            case ("POST", "speakers"):
                return renameSpeakers(project, body: request.body)
            case ("PUT", "report"):
                return saveReport(project, body: request.body)
            default:
                return .error("Unknown route", status: 404)
            }

        default:
            return .error("Unknown route", status: 404)
        }
    }

    // MARK: - Handlers

    @MainActor
    private func fetchProject(_ id: UUID, context: ModelContext) -> TranscriptionProject? {
        let descriptor = FetchDescriptor<TranscriptionProject>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    @MainActor
    private func listTranscriptions(_ query: [String: String], context: ModelContext) -> Response {
        let descriptor = FetchDescriptor<TranscriptionProject>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        var projects = (try? context.fetch(descriptor)) ?? []

        if let search = query["query"]?.lowercased(), !search.isEmpty {
            projects = projects.filter { project in
                project.title.lowercased().contains(search)
                    || project.speakerNames.values.contains { $0.lowercased().contains(search) }
                    || project.segments.contains { $0.text.lowercased().contains(search) }
            }
        }
        if let since = query["since"], let date = Self.parseDate(since) {
            projects = projects.filter { $0.createdAt >= date }
        }
        let limit = Int(query["limit"] ?? "") ?? 20
        return .json(["transcriptions": projects.prefix(limit).map { summary(of: $0) }])
    }

    @MainActor
    private func createTranscription(_ body: Data, context: ModelContext) async -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawPath = json["path"] as? String else {
            return .error("Body must be JSON with a 'path' field", status: 400)
        }
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        guard type?.conforms(to: .audiovisualContent) == true else {
            return .error("Unsupported file type: .\(ext)", status: 400)
        }
        let language = (json["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        #if APPSTORE
        // Sandbox : seulement les dossiers autorises par l'utilisateur dans les Reglages
        do {
            let project = try await FolderAccess.shared.withAccess(to: url) { () async throws -> TranscriptionProject in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw APIError.notFound("File not found: \(url.path)")
                }
                return try await listVM.enqueue(url, language: language, modelContext: context)
            }
            return .json(summary(of: project), status: 201)
        } catch let error as FolderAccessError {
            return .error(error.localizedDescription, status: 403)
        } catch APIError.notFound(let message) {
            return .error(message, status: 404)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
        #else
        // Ne transcrire que des fichiers du dossier utilisateur
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard url.path.hasPrefix(home + "/") else {
            return .error("Only files inside \(home) can be transcribed", status: 400)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("File not found: \(url.path)", status: 404)
        }
        do {
            let project = try await listVM.enqueue(url, language: language, modelContext: context)
            return .json(summary(of: project), status: 201)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
        #endif
    }

    private enum APIError: Error {
        case notFound(String)
    }

    @MainActor
    private func renameSpeakers(_ project: TranscriptionProject, body: Data) -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let mapping = json["names"] as? [String: String] else {
            return .error("Body must be JSON: {\"names\": {\"SPEAKER_00\": \"Name\"}}", status: 400)
        }
        let known = Set(project.uniqueSpeakers)
        let unknown = mapping.keys.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            return .error("Unknown speaker labels: \(unknown.sorted()). Valid: \(known.sorted())", status: 400)
        }

        var names = project.speakerNames
        var auto = project.autoRecognizedSpeakers
        for (label, name) in mapping {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            names[label] = trimmed.isEmpty ? nil : trimmed
            auto.removeValue(forKey: label)
        }
        project.speakerNames = names
        project.autoRecognizedSpeakers = auto
        SpeakerNameHistory.addNames(Array(mapping.values))
        // Enregistre les empreintes vocales (si encore en memoire) pour la reconnaissance future
        SpeakerEmbeddingStore.shared.confirmSpeakerNames(projectId: project.id, labelToName: mapping)
        if project.status == .awaitingSpeakerNames {
            project.status = .completed
            project.completedAt = Date()
        }
        return .json(summary(of: project))
    }

    @MainActor
    private func saveReport(_ project: TranscriptionProject, body: Data) -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let markdown = json["markdown"] as? String else {
            return .error("Body must be JSON with a 'markdown' field", status: 400)
        }
        project.meetingReport = markdown
        project.reportModelUsed = (json["model"] as? String) ?? "Claude"
        return .json(summary(of: project))
    }

    // MARK: - Serialization

    @MainActor
    private func summary(of project: TranscriptionProject) -> [String: Any] {
        var dict: [String: Any] = [
            "id": project.id.uuidString,
            "title": project.title,
            "created_at": ISO8601DateFormatter().string(from: project.createdAt),
            "status": project.status.rawValue,
            "progress_percent": project.status == .completed || project.status == .awaitingSpeakerNames
                ? 100 : Int(project.progressPercent.rounded()),
            "duration_sec": Int(project.audioDurationSec.rounded()),
            "segments_count": project.segments.count,
            "has_report": !(project.meetingReport ?? "").isEmpty,
            "speakers": speakers(of: project),
        ]
        if let step = project.currentStep, project.status.isProcessing { dict["current_step"] = step }
        if let language = project.language { dict["language"] = language }
        if let error = project.errorMessage { dict["error"] = error }
        if project.status == .pending, let index = listVM.batchQueue.firstIndex(of: URL(fileURLWithPath: project.audioFilePath)) {
            dict["queue_position"] = index + 1
        }
        return dict
    }

    @MainActor
    private func speakers(of project: TranscriptionProject) -> [[String: Any]] {
        project.uniqueSpeakers.map { label in
            let segments = project.segments.filter { $0.speakerLabel == label }
            var entry: [String: Any] = [
                "label": label,
                "segments": segments.count,
                "speaking_sec": Int(segments.reduce(0) { $0 + $1.duration }.rounded()),
            ]
            if let name = project.speakerNames[label] { entry["name"] = name }
            if let score = project.autoRecognizedSpeakers[label] {
                entry["recognized_automatically"] = true
                entry["recognition_score"] = (score * 100).rounded() / 100
            }
            return entry
        }
    }

    @MainActor
    private func transcript(of project: TranscriptionProject, query: [String: String]) -> Response {
        let all = project.sortedSegments
        let offset = max(0, Int(query["offset"] ?? "") ?? 0)
        let limit = max(1, Int(query["limit"] ?? "") ?? 400)
        let page = all.dropFirst(offset).prefix(limit)

        let text = page.map { seg in
            let speaker = seg.speakerLabel.map { project.displayName(for: $0) } ?? "?"
            return "[\(TimeFormatting.timestamp(seg.startTime))] \(speaker): \(seg.text)"
        }.joined(separator: "\n")

        var dict = summary(of: project)
        dict["offset"] = offset
        dict["returned_segments"] = page.count
        dict["total_segments"] = all.count
        if offset + page.count < all.count { dict["next_offset"] = offset + page.count }
        dict["transcript"] = text
        if let report = project.meetingReport, !report.isEmpty, offset == 0 {
            dict["meeting_report"] = report
        }
        return .json(dict)
    }

    private func knownSpeakers() -> [[String: Any]] {
        SpeakerEmbeddingStore.shared.knownSpeakers().map { ["name": $0.name, "voice_samples": $0.samples] }
    }

    private static func parseDate(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
