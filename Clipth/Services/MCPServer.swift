import Foundation
import SwiftData

/// Model Context Protocol stdio server. When the binary is launched with
/// `--mcp`, AppKit is bypassed and we instead speak newline-delimited
/// JSON-RPC 2.0 over stdin/stdout. Diagnostics go to stderr so the protocol
/// stream stays clean.
///
/// The server exposes read tools — `search_clipboard`, `list_recent`,
/// `get_clip`, `list_tags`, `list_recent_activity` — plus write tools —
/// `tag_clip`, `untag_clip`, `favorite_clip`, `pin_clip`, `delete_clip`,
/// `restore_clip`, `create_snippet` — that let an MCP client (Claude Desktop,
/// Claude Code, etc.) query and curate the same SwiftData store the GUI uses.
/// WAL mode allows concurrent reads plus a single writer while the main app
/// is running.
///
/// **Cross-process caveat:** the GUI holds its own `ModelContext` in a separate
/// process and SwiftData does not auto-observe external writes, so mutations
/// made here land in the store immediately but a currently-open window won't
/// reflect them until it refetches (next launch / search / scroll refresh).
/// Live cross-process refresh is a separate task.
enum MCPServer {
    private static let protocolVersion = "2024-11-05"
    private static let serverName = "Clipth"
    private static let serverVersion = "1.0.0"
    private static let semanticThreshold: Float = 0.35
    private static let semanticStrongThreshold: Float = 0.55
    private static let semanticTopDelta: Float = 0.16
    private static let semanticKeywordBoost: Float = 0.35
    private static let semanticSourceBoost: Float = 0.12

    // MARK: - Entry point

    static func run() {
        let enabled = (UserDefaults.standard.object(forKey: "mcpEnabled") as? Bool) ?? false
        guard enabled else {
            log("MCP server disabled in settings; exiting")
            return
        }

        log("MCP server starting")

        let container: ModelContainer
        do {
            // Skip the legacy-store recovery/merge: it is a one-time migration
            // owned by the GUI, and its filesystem scan can block for a long
            // time in a headless process (no window to answer a TCC prompt),
            // which reads to an MCP client as a server that never comes up.
            container = try AppContainer.makeContainer(recoverLegacy: false)
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
            } catch let MCPError.toolDisabled(name) {
                writeResponse(jsonError(id: id, code: -32601, message: "Tool disabled in Clipth settings: \(name)"))
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
        case toolDisabled(String)
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
        ToolInfo(
            name: "list_tags",
            description: "List every tag in use along with how many entries carry it.",
            descriptionLocalizationKey: "settings.mcp.tools.list_tags.desc"
        ),
        ToolInfo(
            name: "list_recent_activity",
            description: "List entries added since a given time (ISO 8601 or relative like 30m/2h/3d/1w). Handy for time-bounded summaries.",
            descriptionLocalizationKey: "settings.mcp.tools.list_recent_activity.desc"
        ),
        ToolInfo(
            name: "tag_clip",
            description: "Add tags to a clipboard entry (merged with its existing tags).",
            descriptionLocalizationKey: "settings.mcp.tools.tag_clip.desc"
        ),
        ToolInfo(
            name: "untag_clip",
            description: "Remove the given tags from a clipboard entry.",
            descriptionLocalizationKey: "settings.mcp.tools.untag_clip.desc"
        ),
        ToolInfo(
            name: "favorite_clip",
            description: "Set or clear an entry's favorite state.",
            descriptionLocalizationKey: "settings.mcp.tools.favorite_clip.desc"
        ),
        ToolInfo(
            name: "pin_clip",
            description: "Set or clear an entry's pinned state.",
            descriptionLocalizationKey: "settings.mcp.tools.pin_clip.desc"
        ),
        ToolInfo(
            name: "delete_clip",
            description: "Delete an entry — soft-delete to trash by default, or purge permanently with soft=false.",
            descriptionLocalizationKey: "settings.mcp.tools.delete_clip.desc"
        ),
        ToolInfo(
            name: "restore_clip",
            description: "Restore a soft-deleted entry from the trash.",
            descriptionLocalizationKey: "settings.mcp.tools.restore_clip.desc"
        ),
        ToolInfo(
            name: "create_snippet",
            description: "Create a snippet entry, optionally with a title and tags.",
            descriptionLocalizationKey: "settings.mcp.tools.create_snippet.desc"
        ),
        ToolInfo(
            name: "list_rules",
            description: "List the automation rules configured in Clipth, in evaluation order, with their conditions and actions.",
            descriptionLocalizationKey: "settings.mcp.tools.list_rules.desc"
        ),
        ToolInfo(
            name: "create_rule",
            description: "Create an automation rule (match conditions + action, including JavaScript or shell scripts). The rule is always created DISABLED — the user must review and enable it in Clipth's settings before it can ever run.",
            descriptionLocalizationKey: "settings.mcp.tools.create_rule.desc"
        ),
    ]

    /// UserDefaults key that gates whether a tool is advertised in
    /// `tools/list` and callable. Shared with the Settings UI so a toggle
    /// there takes effect in the (separate) MCP process on its next launch.
    static func toolEnabledDefaultsKey(_ name: String) -> String {
        "mcpTool.\(name).enabled"
    }

    /// Tools default to enabled — turning one off both hides it from
    /// `tools/list` (so it stops eating the client's context window) and
    /// rejects any direct call to it.
    static func isToolEnabled(_ name: String) -> Bool {
        (UserDefaults.standard.object(forKey: toolEnabledDefaultsKey(name)) as? Bool) ?? true
    }

    /// Look up a tool's English description from the single `publicTools`
    /// catalog so `tools/list` and the Settings UI never drift apart.
    private static func toolDescription(_ name: String) -> String {
        publicTools.first(where: { $0.name == name })?.description ?? ""
    }

    private static let idSchema: [String: Any] = [
        "type": "string",
        "description": "UUID of the clipboard item"
    ]

    /// String-condition sub-schema, shared by the text and file-name conditions.
    private static let matchSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "enum": ["any", "contains", "notContains", "regex"],
                "description": "any = no condition (default)"
            ],
            "value": [
                "type": "string",
                "description": "Keyword, or an ICU regular expression when mode is regex"
            ]
        ]
    ]

    /// The rule format, spelled out for an agent that has never seen Clipth.
    /// This schema *is* the contract: every field an agent can set, the exact
    /// vocabulary for each, and what the runner does with the result.
    private static let ruleInputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": [
                "type": "string",
                "description": "Short human-readable rule name shown in Clipth's settings"
            ],
            "triggers": [
                "type": "array",
                "items": ["type": "string", "enum": ["copy", "paste"]],
                "description": "When the rule runs. copy = as a clip is captured (changes what gets stored); paste = as text leaves Clipth for another app (changes only that paste, history untouched). Defaults to [\"copy\"]."
            ],
            "apps": [
                "type": "array",
                "items": [
                    "oneOf": [
                        ["type": "string"],
                        [
                            "type": "object",
                            "properties": [
                                "bundleId": ["type": "string"],
                                "name": ["type": "string"]
                            ],
                            "required": ["bundleId"]
                        ]
                    ]
                ],
                "description": "Bundle ids the rule is scoped to — the source app on copy, the target app on paste. Omit or leave empty for every app."
            ],
            "categories": [
                "type": "array",
                "items": ["type": "string", "enum": ["text", "image", "video", "audio", "file"]],
                "description": "Content kinds the rule applies to. text covers plain text, links and rich text; audio is recognised by file extension. Omit for every kind."
            ],
            "contentMatch": matchSchema.merging([
                "description": "Condition on the clip's text (text/link/rich-text clips only)"
            ]) { current, _ in current },
            "fileNameMatch": matchSchema.merging([
                "description": "Condition on the clip's file name (image/video/audio/file clips only)"
            ]) { current, _ in current },
            "fileExtensions": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Extensions a file clip must carry, without the dot (e.g. [\"mp3\",\"m4a\"]). Omit for any extension."
            ],
            "action": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "enum": ["drop", "replaceRegex", "shell", "javascript"],
                        "description": "drop = exclude the clip from history; replaceRegex = regex find/replace; shell/javascript = run a script"
                    ],
                    "pattern": ["type": "string", "description": "replaceRegex: the pattern to find"],
                    "replacement": ["type": "string", "description": "replaceRegex: the replacement template ($1 for groups)"],
                    "source": [
                        "type": "string",
                        "description": "shell/javascript: the script body. JavaScript runs in a sandboxed JSContext with a `clip` object ({text, type, sourceApp, bundleId, tags}) — define `function run(clip) {…}` and return a string to replace the text, an object {text, tags, title, newClip, copy, drop} for richer effects, or null to skip. console.log output is visible in the rule editor's test panel. Shell scripts read the clip on stdin and return the result on stdout (a JSON envelope with the same keys also works); metadata arrives as CLIP_TYPE / CLIP_SOURCE_APP / CLIP_BUNDLE_ID / CLIP_TAGS / CLIP_IMAGE_PATH, a non-zero exit means skip, and stderr shows up in the test panel."
                    ]
                ],
                "required": ["type"]
            ],
            "timeoutSeconds": [
                "type": "number",
                "description": "Per-run timeout for script actions, 0–30 seconds (default 3)"
            ]
        ],
        "required": ["name", "action"]
    ]

    private static func toolDescriptors() -> [[String: Any]] {
        let all: [[String: Any]] = [
            [
                "name": "search_clipboard",
                "description": toolDescription("search_clipboard"),
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
                "description": toolDescription("list_recent"),
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
                "description": toolDescription("get_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": idSchema],
                    "required": ["id"]
                ]
            ],
            [
                "name": "list_tags",
                "description": toolDescription("list_tags"),
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ],
            [
                "name": "list_recent_activity",
                "description": toolDescription("list_recent_activity"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since": [
                            "type": "string",
                            "description": "Lower time bound: ISO 8601 date/datetime, or relative like 30m / 2h / 3d / 1w"
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of results (default 50)"
                        ]
                    ],
                    "required": ["since"]
                ]
            ],
            [
                "name": "tag_clip",
                "description": toolDescription("tag_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Tags to add (merged with existing tags)"
                        ]
                    ],
                    "required": ["id", "tags"]
                ]
            ],
            [
                "name": "untag_clip",
                "description": toolDescription("untag_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Tags to remove (case-insensitive match)"
                        ]
                    ],
                    "required": ["id", "tags"]
                ]
            ],
            [
                "name": "favorite_clip",
                "description": toolDescription("favorite_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "favorite": [
                            "type": "boolean",
                            "description": "Desired favorite state (default true)"
                        ]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "pin_clip",
                "description": toolDescription("pin_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "pinned": [
                            "type": "boolean",
                            "description": "Desired pinned state (default true)"
                        ]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "delete_clip",
                "description": toolDescription("delete_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": idSchema,
                        "soft": [
                            "type": "boolean",
                            "description": "Soft-delete to trash when true (default), purge permanently when false"
                        ]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "restore_clip",
                "description": toolDescription("restore_clip"),
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": idSchema],
                    "required": ["id"]
                ]
            ],
            [
                "name": "create_snippet",
                "description": toolDescription("create_snippet"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "content": [
                            "type": "string",
                            "description": "Snippet body"
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional custom title shown in the list"
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional tags to attach"
                        ]
                    ],
                    "required": ["content"]
                ]
            ],
            [
                "name": "list_rules",
                "description": toolDescription("list_rules"),
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ],
            [
                "name": "create_rule",
                "description": toolDescription("create_rule"),
                "inputSchema": ruleInputSchema
            ]
        ]
        // Only advertise enabled tools so disabled ones don't occupy the
        // client's context window.
        return all.filter { descriptor in
            guard let name = descriptor["name"] as? String else { return false }
            return isToolEnabled(name)
        }
    }

    @MainActor
    private static func dispatchTool(name: String, arguments: [String: Any], context: ModelContext) throws -> String {
        // A disabled tool isn't advertised; treat a direct call as unavailable.
        guard isToolEnabled(name) else {
            throw MCPError.toolDisabled(name)
        }
        switch name {
        case "search_clipboard":
            return try searchClipboard(arguments: arguments, context: context)
        case "list_recent":
            return try listRecent(arguments: arguments, context: context)
        case "get_clip":
            return try getClip(arguments: arguments, context: context)
        case "list_tags":
            return try listTags(arguments: arguments, context: context)
        case "list_recent_activity":
            return try listRecentActivity(arguments: arguments, context: context)
        case "tag_clip":
            return try tagClip(arguments: arguments, context: context, adding: true)
        case "untag_clip":
            return try tagClip(arguments: arguments, context: context, adding: false)
        case "favorite_clip":
            return try favoriteClip(arguments: arguments, context: context)
        case "pin_clip":
            return try pinClip(arguments: arguments, context: context)
        case "delete_clip":
            return try deleteClip(arguments: arguments, context: context)
        case "restore_clip":
            return try restoreClip(arguments: arguments, context: context)
        case "create_snippet":
            return try createSnippet(arguments: arguments, context: context)
        case "list_rules":
            return listRules()
        case "create_rule":
            return try createRule(arguments: arguments)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    // MARK: - Shared helpers (write tools)

    /// Resolve the `id` argument to a live item, or throw a descriptive
    /// invalid-params error. Returns `nil` only when the UUID is well-formed
    /// but no row matches (callers turn that into a "Not found" reply).
    @MainActor
    private static func fetchItem(arguments: [String: Any], context: ModelContext) throws -> ClipboardItem? {
        guard let raw = arguments["id"] as? String,
              let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("id must be a valid UUID string")
        }
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.id == uuid }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Pull a required non-empty `[String]` from the arguments.
    private static func stringArray(_ arguments: [String: Any], key: String) throws -> [String] {
        guard let raw = arguments[key] as? [Any] else {
            throw MCPError.invalidParams("\(key) must be an array of strings")
        }
        let strings = raw.compactMap { $0 as? String }
        guard !strings.isEmpty else {
            throw MCPError.invalidParams("\(key) must contain at least one string")
        }
        return strings
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

        // Egress default: redact protected text/OCR unless the user opted into
        // raw MCP output. Protected metadata is always reported so a client can
        // tell a redacted value from an ordinary one.
        let settings = ContentProtectionSettings.current()
        let body: String
        var protection: ContentProtectionResult?
        if item.itemType == .image {
            if let ocr = item.ocrText, !ocr.isEmpty {
                let p = ContentProtector.redact(ocr, settings: settings)
                protection = p
                let shown = (settings.allowRawMCP || !p.isProtected) ? ocr : p.redactedText
                body = "[Image, \(item.imageByteCount ?? 0) bytes]\n\nOCR:\n\(shown)"
            } else {
                body = "[Image, \(item.imageByteCount ?? 0) bytes, not text-extractable]"
            }
        } else {
            let p = ContentProtector.redact(item.content, settings: settings)
            protection = p
            body = (settings.allowRawMCP || !p.isProtected) ? item.content : p.redactedText
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
        if let protection, protection.isProtected {
            headerLines.append("Protected: true")
            headerLines.append("ProtectedCategories: \(protection.categories.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        let header = headerLines.joined(separator: "\n")

        return "\(header)\n\n---\n\(body)"
    }

    // MARK: list_tags

    @MainActor
    private static func listTags(arguments: [String: Any], context: ModelContext) throws -> String {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let items = (try? context.fetch(descriptor)) ?? []

        // Count case-insensitively but report the first-seen spelling, so
        // "Work" and "work" collapse into one line.
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for item in items {
            for tag in item.tags {
                let key = tag.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = tag }
            }
        }

        guard !counts.isEmpty else { return "No tags" }

        return counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map { key, count in "\(display[key] ?? key) (\(count))" }
            .joined(separator: "\n")
    }

    // MARK: list_recent_activity

    @MainActor
    private static func listRecentActivity(arguments: [String: Any], context: ModelContext) throws -> String {
        guard let rawSince = (arguments["since"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSince.isEmpty else {
            throw MCPError.invalidParams("since is required")
        }
        guard let cutoff = parseSince(rawSince) else {
            throw MCPError.invalidParams("since must be ISO 8601 (e.g. 2026-05-01) or relative (e.g. 30m, 2h, 3d, 1w)")
        }
        let limit = max(1, (arguments["limit"] as? Int) ?? 50)

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let items = (try? context.fetch(descriptor)) ?? []
        if items.isEmpty {
            return "No activity since \(iso8601(cutoff))"
        }
        let header = "\(items.count) entr\(items.count == 1 ? "y" : "ies") since \(iso8601(cutoff)):"
        let rows = items.enumerated()
            .map { idx, item in formatResultRow(index: idx, item: item) }
            .joined(separator: "\n\n")
        return "\(header)\n\n\(rows)"
    }

    /// Accepts ISO 8601 (date or datetime) or a relative offset like `30m`,
    /// `2h`, `3d`, `1w`. Returns nil when neither form parses.
    private static func parseSince(_ raw: String) -> Date? {
        // Relative: <number><unit>
        if let last = raw.last, "mhdw".contains(last),
           let value = Int(raw.dropLast()), value >= 0 {
            let seconds: TimeInterval
            switch last {
            case "m": seconds = Double(value) * 60
            case "h": seconds = Double(value) * 3_600
            case "d": seconds = Double(value) * 86_400
            case "w": seconds = Double(value) * 604_800
            default: return nil
            }
            return Date().addingTimeInterval(-seconds)
        }
        // Absolute: full ISO 8601 datetime, then bare yyyy-MM-dd.
        if let date = iso8601Formatter.date(from: raw) {
            return date
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .iso8601)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: raw)
    }

    // MARK: tag_clip / untag_clip

    @MainActor
    private static func tagClip(arguments: [String: Any], context: ModelContext, adding: Bool) throws -> String {
        let tags = try stringArray(arguments, key: "tags")
        guard let item = try fetchItem(arguments: arguments, context: context) else {
            return "Not found"
        }

        if adding {
            item.setTags(item.tags + tags)
        } else {
            let remove = Set(tags.map { $0.lowercased() })
            item.setTags(item.tags.filter { !remove.contains($0.lowercased()) })
        }
        try? context.save()

        let current = item.tags.isEmpty ? "(none)" : item.tags.joined(separator: ", ")
        let verb = adding ? "Tagged" : "Untagged"
        return "\(verb) \(item.id.uuidString)\nTags: \(current)"
    }

    // MARK: favorite_clip

    @MainActor
    private static func favoriteClip(arguments: [String: Any], context: ModelContext) throws -> String {
        let favorite = (arguments["favorite"] as? Bool) ?? true
        guard let item = try fetchItem(arguments: arguments, context: context) else {
            return "Not found"
        }
        item.isFavorite = favorite
        try? context.save()
        return "\(item.id.uuidString)\nFavorite: \(favorite)"
    }

    // MARK: pin_clip

    @MainActor
    private static func pinClip(arguments: [String: Any], context: ModelContext) throws -> String {
        let pinned = (arguments["pinned"] as? Bool) ?? true
        guard let item = try fetchItem(arguments: arguments, context: context) else {
            return "Not found"
        }
        item.isPinned = pinned
        try? context.save()
        return "\(item.id.uuidString)\nPinned: \(pinned)"
    }

    // MARK: delete_clip

    @MainActor
    private static func deleteClip(arguments: [String: Any], context: ModelContext) throws -> String {
        let soft = (arguments["soft"] as? Bool) ?? true
        guard let item = try fetchItem(arguments: arguments, context: context) else {
            return "Not found"
        }
        let id = item.id.uuidString
        if soft {
            // Match the GUI: re-stamp deletedAt so trash retention counts from now.
            item.deletedAt = Date()
            try? context.save()
            return "Soft-deleted \(id) (moved to trash)"
        } else {
            context.delete(item)
            try? context.save()
            return "Permanently deleted \(id)"
        }
    }

    // MARK: restore_clip

    @MainActor
    private static func restoreClip(arguments: [String: Any], context: ModelContext) throws -> String {
        guard let item = try fetchItem(arguments: arguments, context: context) else {
            return "Not found"
        }
        guard item.deletedAt != nil else {
            return "\(item.id.uuidString) is not in the trash"
        }
        // Leave createdAt untouched: a data API should preserve the original
        // capture time rather than floating the row to the top like the GUI does.
        item.deletedAt = nil
        try? context.save()
        return "Restored \(item.id.uuidString)"
    }

    // MARK: create_snippet

    @MainActor
    private static func createSnippet(arguments: [String: Any], context: ModelContext) throws -> String {
        guard let content = (arguments["content"] as? String),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("content is required")
        }

        let item = ClipboardItem(
            type: .text,
            content: content,
            sourceApp: L("snippet.sourceApp"),
            preview: String(content.prefix(200))
        )
        if let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            item.customTitle = String(title.prefix(120))
        }
        if let rawTags = arguments["tags"] as? [Any] {
            item.setTags(rawTags.compactMap { $0 as? String })
        }

        // Embed synchronously so the snippet is semantically searchable right
        // away — `embed` runs on its own serial queue and returns a vector.
        if let emb = EmbeddingService.shared.embed(content) {
            item.embedding = emb.data
            item.embeddingLang = emb.language
        }

        context.insert(item)
        try? context.save()

        var lines = ["Created snippet \(item.id.uuidString)"]
        if let title = item.effectiveCustomTitle { lines.append("Title: \(title)") }
        if !item.tags.isEmpty { lines.append("Tags: \(item.tags.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    // MARK: list_rules / create_rule

    /// Rules live in UserDefaults, not SwiftData, and this process doesn't share
    /// the GUI's in-memory copy — so both tools go through the store's
    /// cross-process helpers.
    @MainActor
    private static func listRules() -> String {
        let rules = FilterSettingsStore.rulesFromDefaults()
        guard !rules.isEmpty else {
            return "No rules configured yet. Use create_rule to add one."
        }
        var lines = ["\(rules.count) rule(s), evaluated top-down (a drop halts the rest):"]
        for (index, rule) in rules.enumerated() {
            lines.append("\(index + 1). \(describe(rule))")
        }
        return lines.joined(separator: "\n")
    }

    /// Compact, agent-readable rendering of a rule. Shared by `list_rules` and
    /// the `create_rule` confirmation so an agent can verify what it just wrote.
    private static func describe(_ rule: ScriptingRule) -> String {
        var parts: [String] = [
            "\(rule.displayName) [\(rule.isEnabled ? "enabled" : "disabled")] id=\(rule.id.uuidString)"
        ]
        let triggers = RuleTrigger.allCases.filter { rule.triggers.contains($0) }.map(\.rawValue).joined(separator: "+")
        var conditions = ["on=\(triggers)"]
        if !rule.apps.isEmpty {
            conditions.append("apps=\(rule.apps.map(\.bundleId).joined(separator: ","))")
        }
        if !rule.matchCategories.isEmpty {
            let categories = RuleMatchCategory.allCases.filter { rule.matchCategories.contains($0) }.map(\.rawValue)
            conditions.append("types=\(categories.joined(separator: ","))")
        }
        if rule.contentMatch.isActive {
            conditions.append("content \(rule.contentMatch.mode.rawValue) \"\(rule.contentMatch.value)\"")
        }
        if rule.fileNameMatch.isActive {
            conditions.append("filename \(rule.fileNameMatch.mode.rawValue) \"\(rule.fileNameMatch.value)\"")
        }
        if !rule.fileExtensions.isEmpty {
            conditions.append("ext=\(rule.fileExtensions.joined(separator: ","))")
        }
        parts.append("   " + conditions.joined(separator: " | "))

        switch rule.action {
        case .drop:
            parts.append("   action: drop")
        case .replaceRegex(let pattern, let replacement):
            parts.append("   action: replaceRegex /\(pattern)/ -> \"\(replacement)\"")
        case .shell(let source):
            parts.append("   action: shell (\(source.count) chars) — \(firstLine(of: source))")
        case .javascript(let source):
            parts.append("   action: javascript (\(source.count) chars) — \(firstLine(of: source))")
        }
        return parts.joined(separator: "\n")
    }

    private static func firstLine(of source: String) -> String {
        let line = source.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// Build a rule from an agent-supplied spec.
    ///
    /// The parsing/validation lives in `RuleSpec` because the very same format
    /// is what the copy-paste prompt asks a model for — one grammar, one set of
    /// error messages, no drift between the two AI entry points.
    ///
    /// The rule is stored **disabled** no matter what the caller asks: arming
    /// one means letting it run against everything the user copies (and, for
    /// script actions, running code), which only the human can decide.
    @MainActor
    private static func createRule(arguments: [String: Any]) throws -> String {
        let rule: ScriptingRule
        do {
            rule = try RuleSpec.rule(from: arguments)
        } catch let failure as RuleSpec.Failure {
            throw MCPError.invalidParams(failure.message)
        }

        guard FilterSettingsStore.appendRuleToDefaults(rule) else {
            throw MCPError.invalidParams("failed to persist the rule")
        }

        return """
        Created rule (disabled, pending the user's approval):
        \(describe(rule))

        It will not run until the user enables it in Clipth → Settings → Rules. \
        Script rules additionally require an explicit "allow this rule to run code" confirmation there.
        """
    }

    // MARK: - Formatting helpers

    private static func formatResultRow(index: Int, item: ClipboardItem) -> String {
        let settings = ContentProtectionSettings.current()
        let snippet: String
        var protectedTag = ""
        if item.itemType == .image {
            snippet = "[Image, \(item.imageByteCount ?? 0) bytes]"
            // Search/list can match an image via its OCR text, so flag the row
            // when that OCR is protected — consistent with `get_clip` — without
            // surfacing the OCR snippet itself.
            if let ocr = item.ocrText, !ocr.isEmpty,
               ContentProtector.redact(ocr, settings: settings).isProtected {
                protectedTag = " [protected]"
            }
        } else {
            // Egress default: redact protected clips unless the user opted into
            // raw MCP output. Search still matched the raw content upstream.
            let protection = ContentProtector.redact(item.content, settings: settings)
            let shown = (settings.allowRawMCP || !protection.isProtected)
                ? item.content
                : protection.redactedText
            if protection.isProtected { protectedTag = " [protected]" }
            let collapsed = shown
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            if collapsed.count > 300 {
                snippet = String(collapsed.prefix(300)) + "..."
            } else {
                snippet = collapsed
            }
        }
        let source = item.sourceApp.isEmpty ? "unknown" : item.sourceApp
        return "[\(index)] [\(item.type)]\(protectedTag) (\(source), \(iso8601(item.createdAt))) — \(snippet)\nID: \(item.id.uuidString)"
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
