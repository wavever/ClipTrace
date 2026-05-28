import Foundation
import SwiftData

/// Model Context Protocol stdio server. When the binary is launched with
/// `--mcp`, AppKit is bypassed and we instead speak newline-delimited
/// JSON-RPC 2.0 over stdin/stdout. Diagnostics go to stderr so the protocol
/// stream stays clean.
///
/// The server exposes three tools — `search_clipboard`, `list_recent`, and
/// `get_clip` — that let an MCP client (Claude Desktop, Claude Code, etc.)
/// query the same SwiftData store the GUI uses. WAL mode allows concurrent
/// reads while the main app is running.
enum MCPServer {
    private static let protocolVersion = "2024-11-05"
    private static let serverName = "ClipTrace"
    private static let serverVersion = "1.0.0"
    private static let semanticThreshold: Float = 0.35
    private static let semanticStrongThreshold: Float = 0.55
    private static let semanticTopDelta: Float = 0.16
    private static let semanticKeywordBoost: Float = 0.35
    private static let semanticSourceBoost: Float = 0.12

    // MARK: - Entry point

    static func run() {
        let enabled = (UserDefaults.standard.object(forKey: "mcpEnabled") as? Bool) ?? true
        guard enabled else {
            log("MCP server disabled in settings; exiting")
            return
        }

        log("MCP server starting")

        let container: ModelContainer
        do {
            container = try ModelContainer(for: Schema([ClipboardItem.self]))
        } catch {
            log("Failed to open ModelContainer: \(error)")
            return
        }

        // SwiftData's ModelContext is @MainActor. We're on the main thread
        // before AppKit/SwiftUI ever spins up, so we can safely claim main
        // actor isolation for the duration of the loop.
        MainActor.assumeIsolated {
            let context = ModelContext(container)
            loop(context: context)
        }

        log("MCP server exiting")
    }

    @MainActor
    private static func loop(context: ModelContext) {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                log("Skipping non-UTF8 frame")
                continue
            }

            let raw: Any
            do {
                raw = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                log("Parse error: \(error). Frame: \(trimmed.prefix(200))")
                writeResponse(jsonError(id: nil, code: -32700, message: "Parse error"))
                continue
            }

            guard let dict = raw as? [String: Any] else {
                writeResponse(jsonError(id: nil, code: -32600, message: "Invalid Request"))
                continue
            }

            handle(message: dict, context: context)
        }
    }

    // MARK: - Dispatch

    @MainActor
    private static func handle(message: [String: Any], context: ModelContext) {
        let id = message["id"]
        let method = (message["method"] as? String) ?? ""
        let params = (message["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": serverName,
                    "version": serverVersion
                ]
            ]
            writeResponse(jsonResult(id: id, result: result))

        case "notifications/initialized", "initialized":
            // Notifications never get a response.
            return

        case "tools/list":
            writeResponse(jsonResult(id: id, result: ["tools": toolDescriptors()]))

        case "tools/call":
            let toolName = (params["name"] as? String) ?? ""
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            do {
                let text = try dispatchTool(name: toolName, arguments: arguments, context: context)
                let result: [String: Any] = [
                    "content": [
                        ["type": "text", "text": text]
                    ]
                ]
                writeResponse(jsonResult(id: id, result: result))
            } catch let MCPError.invalidParams(msg) {
                writeResponse(jsonError(id: id, code: -32602, message: msg))
            } catch let MCPError.toolNotFound(name) {
                writeResponse(jsonError(id: id, code: -32601, message: "Unknown tool: \(name)"))
            } catch {
                writeResponse(jsonError(id: id, code: -32603, message: "Internal error: \(error)"))
            }

        default:
            // No response for unknown notifications (no id), error otherwise.
            if id == nil { return }
            writeResponse(jsonError(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Tools

    private enum MCPError: Error {
        case invalidParams(String)
        case toolNotFound(String)
    }

    /// Public catalog of MCP tools exposed by this server. Used both by the
    /// JSON-RPC `tools/list` response and by the Settings UI so the two
    /// stay in sync.
    struct ToolInfo {
        let name: String
        let description: String
        let descriptionLocalizationKey: String
    }

    static let publicTools: [ToolInfo] = [
        ToolInfo(
            name: "search_clipboard",
            description: "Search clipboard history. Uses local sentence embeddings for semantic ranking when possible, falls back to keyword matching.",
            descriptionLocalizationKey: "settings.mcp.tools.search_clipboard.desc"
        ),
        ToolInfo(
            name: "list_recent",
            description: "List the most recent clipboard entries, optionally filtered by type.",
            descriptionLocalizationKey: "settings.mcp.tools.list_recent.desc"
        ),
        ToolInfo(
            name: "get_clip",
            description: "Fetch a single clipboard entry by UUID, returning full content plus metadata.",
            descriptionLocalizationKey: "settings.mcp.tools.get_clip.desc"
        ),
    ]

    private static func toolDescriptors() -> [[String: Any]] {
        [
            [
                "name": "search_clipboard",
                "description": publicTools[0].description,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Text to search for"
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of results (default 10)"
                        ],
                        "semantic": [
                            "type": "boolean",
                            "description": "Use semantic embeddings when true (default true)"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "list_recent",
                "description": publicTools[1].description,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of results (default 20)"
                        ],
                        "type": [
                            "type": "string",
                            "description": "Optional ClipboardItemType raw value (text, url, image, video, file, rtf)"
                        ]
                    ]
                ]
            ],
            [
                "name": "get_clip",
                "description": publicTools[2].description,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "UUID of the clipboard item"
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    }

    @MainActor
    private static func dispatchTool(name: String, arguments: [String: Any], context: ModelContext) throws -> String {
        switch name {
        case "search_clipboard":
            return try searchClipboard(arguments: arguments, context: context)
        case "list_recent":
            return try listRecent(arguments: arguments, context: context)
        case "get_clip":
            return try getClip(arguments: arguments, context: context)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    // MARK: search_clipboard

    @MainActor
    private static func searchClipboard(arguments: [String: Any], context: ModelContext) throws -> String {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw MCPError.invalidParams("query is required")
        }
        let limit = max(1, (arguments["limit"] as? Int) ?? 10)
        let semantic = (arguments["semantic"] as? Bool) ?? true

        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        let items: [ClipboardItem]
        do {
            items = try context.fetch(descriptor)
        } catch {
            log("Fetch failed: \(error)")
            return "No matches"
        }

        var matched: [ClipboardItem] = []

        if semantic {
            let queryVectors = EmbeddingService.shared.embeddingsForSearch(query)
            if !queryVectors.isEmpty {
                struct Scored {
                    let item: ClipboardItem
                    let semanticScore: Float
                    let keywordScore: Float
                    let originalIndex: Int

                    var score: Float { semanticScore + keywordScore }
                    var hasKeywordMatch: Bool { keywordScore > 0 }
                }

                var scored: [Scored] = []
                for (index, item) in items.enumerated() {
                    let semanticScore = EmbeddingService.shared.bestSimilarity(
                        queryVectors: queryVectors,
                        itemEmbedding: item.embedding,
                        itemLanguage: item.embeddingLang
                    ) ?? 0
                    let keywordScore = keywordMatchScore(for: item, query: query)
                    if semanticScore >= semanticThreshold || keywordScore > 0 {
                        scored.append(
                            Scored(
                                item: item,
                                semanticScore: semanticScore,
                                keywordScore: keywordScore,
                                originalIndex: index
                            )
                        )
                    }
                }

                if let topSemantic = scored.map(\.semanticScore).max(), topSemantic >= semanticThreshold {
                    let cutoff = max(semanticThreshold, topSemantic - semanticTopDelta)
                    scored = scored.filter {
                        $0.hasKeywordMatch ||
                        $0.semanticScore >= semanticStrongThreshold ||
                        $0.semanticScore >= cutoff
                    }
                }
                scored.sort {
                    if $0.hasKeywordMatch != $1.hasKeywordMatch {
                        return $0.hasKeywordMatch
                    }
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    return $0.originalIndex < $1.originalIndex
                }
                matched = scored.prefix(limit).map { $0.item }
            }
        }

        if matched.isEmpty {
            matched = items
                .filter { keywordMatchScore(for: $0, query: query) > 0 }
                .prefix(limit)
                .map { $0 }
        }

        if matched.isEmpty {
            return "No matches"
        }

        return matched.enumerated()
            .map { idx, item in formatResultRow(index: idx, item: item) }
            .joined(separator: "\n\n")
    }

    private static func keywordMatchScore(for item: ClipboardItem, query: String) -> Float {
        var score: Float = 0
        if item.content.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if let title = item.effectiveCustomTitle,
           title.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if let ocr = item.ocrText, !ocr.isEmpty,
           ocr.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if item.sourceApp.localizedCaseInsensitiveContains(query) {
            score += semanticSourceBoost
        }
        return score
    }

    // MARK: list_recent

    @MainActor
    private static func listRecent(arguments: [String: Any], context: ModelContext) throws -> String {
        let limit = max(1, (arguments["limit"] as? Int) ?? 20)
        let typeFilter = (arguments["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 4 // overshoot in case of type filter

        let fetched: [ClipboardItem]
        do {
            fetched = try context.fetch(descriptor)
        } catch {
            log("Fetch failed: \(error)")
            return "No matches"
        }

        let filtered: [ClipboardItem]
        if let type = typeFilter, !type.isEmpty {
            filtered = fetched.filter { $0.type == type }
        } else {
            filtered = fetched
        }

        let limited = Array(filtered.prefix(limit))
        if limited.isEmpty {
            return "No matches"
        }

        return limited.enumerated()
            .map { idx, item in formatResultRow(index: idx, item: item) }
            .joined(separator: "\n\n")
    }

    // MARK: get_clip

    @MainActor
    private static func getClip(arguments: [String: Any], context: ModelContext) throws -> String {
        guard let raw = arguments["id"] as? String,
              let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("id must be a valid UUID string")
        }

        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.id == uuid }
        )
        let items: [ClipboardItem]
        do {
            items = try context.fetch(descriptor)
        } catch {
            log("Fetch failed: \(error)")
            return "Not found"
        }

        guard let item = items.first else {
            return "Not found"
        }

        let body: String
        if item.itemType == .image {
            if let ocr = item.ocrText, !ocr.isEmpty {
                body = "[Image, \(item.imageData?.count ?? 0) bytes]\n\nOCR:\n\(ocr)"
            } else {
                body = "[Image, \(item.imageData?.count ?? 0) bytes, not text-extractable]"
            }
        } else {
            body = item.content
        }

        var headerLines: [String] = [
            "Type: \(item.type)",
            "Source: \(item.sourceApp)",
            "Created: \(iso8601(item.createdAt))",
            "Pinned: \(item.isPinned)",
            "Favorite: \(item.isFavorite)",
            "Length: \(item.content.count) chars",
        ]
        if let title = item.effectiveCustomTitle {
            headerLines.insert("Title: \(title)", at: 1)
        }
        let header = headerLines.joined(separator: "\n")

        return "\(header)\n\n---\n\(body)"
    }

    // MARK: - Formatting helpers

    private static func formatResultRow(index: Int, item: ClipboardItem) -> String {
        let snippet: String
        if item.itemType == .image {
            snippet = "[Image, \(item.imageData?.count ?? 0) bytes]"
        } else {
            let collapsed = item.content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            if collapsed.count > 300 {
                snippet = String(collapsed.prefix(300)) + "..."
            } else {
                snippet = collapsed
            }
        }
        let source = item.sourceApp.isEmpty ? "unknown" : item.sourceApp
        return "[\(index)] [\(item.type)] (\(source), \(iso8601(item.createdAt))) — \(snippet)\nID: \(item.id.uuidString)"
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    // MARK: - JSON-RPC framing

    private static func jsonResult(id: Any?, result: [String: Any]) -> [String: Any] {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            msg["id"] = id
        } else {
            msg["id"] = NSNull()
        }
        return msg
    }

    private static func jsonError(id: Any?, code: Int, message: String) -> [String: Any] {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id = id {
            msg["id"] = id
        } else {
            msg["id"] = NSNull()
        }
        return msg
    }

    private static func writeResponse(_ object: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [])
            data.append(0x0A)
            // The non-throwing `write(_:)` raises an ObjC
            // `NSFileHandleOperationException` on broken pipe / EPIPE, which
            // Swift can't catch and crashes the process. The throwing
            // `write(contentsOf:)` surfaces the same condition as a Swift
            // error we can silently swallow when the MCP client disconnects.
            try? FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            log("Failed to encode response: \(error)")
        }
    }

    // MARK: - Logging (stderr only)

    private static func log(_ message: String) {
        let line = "[MCP] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}
