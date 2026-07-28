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

// MARK: - One-click client setup
//
// Hand-pasting JSON into an agent's config file is the biggest friction point
// in wiring Clipth up, so Settings detects the agents installed on this Mac and
// writes the entry for them. Two things make that harder than "parse JSON,
// mutate, save":
//
//   * Not every client speaks JSON — Codex configures MCP servers in TOML.
//   * Of the ones that do, several allow comments (Zed's settings.json ships a
//     comment header) and some files are large piles of unrelated state
//     (`~/.claude.json` also holds session history). A JSONSerialization round
//     trip would silently drop the comments and reorder every key in the file.
//
// So we never re-serialize a client's config: we splice our entry into the
// original *text* and leave every other byte alone, then re-parse our own
// output to prove it still contains what we intended before overwriting.

/// How an agent app stores MCP servers. The JSON cases differ only in the
/// container key and entry shape; `codexTOML` is a different language entirely.
enum MCPClientFormat: String, Sendable {
    /// `{ "mcpServers": { "clipth": { command, args } } }` — the de-facto standard.
    case mcpServers
    /// Same, plus the explicit `"type": "stdio"` Claude Code writes itself.
    case mcpServersStdio
    /// VS Code keys the map `servers`, not `mcpServers`.
    case vscodeServers
    /// Zed calls them context servers and marks user-defined ones `custom`.
    case zedContextServers
    /// opencode nests the binary and its arguments in one `command` array.
    case opencodeMCP
    /// Codex: `[mcp_servers.clipth]` in `~/.codex/config.toml`.
    case codexTOML

    /// Top-level key holding the server map (JSON formats only).
    var containerKey: String {
        switch self {
        case .mcpServers, .mcpServersStdio: return "mcpServers"
        case .vscodeServers: return "servers"
        case .zedContextServers: return "context_servers"
        case .opencodeMCP: return "mcp"
        case .codexTOML: return ""
        }
    }

    var isTOML: Bool { self == .codexTOML }

    /// Badge shown next to a client so the user can tell at a glance which
    /// syntax the copy button will hand them.
    var badge: String { isTOML ? "TOML" : "JSON" }

    /// Our server entry on its own — the value spliced in under `clipth`.
    func entryLiteral(executablePath: String) -> String {
        let cmd = MCPClientFormat.jsonQuoted(executablePath)
        switch self {
        case .mcpServers:
            return "{\n  \"command\": \(cmd),\n  \"args\": [\"--mcp\"]\n}"
        case .mcpServersStdio, .vscodeServers:
            return "{\n  \"type\": \"stdio\",\n  \"command\": \(cmd),\n  \"args\": [\"--mcp\"]\n}"
        case .zedContextServers:
            return "{\n  \"source\": \"custom\",\n  \"command\": \(cmd),\n  \"args\": [\"--mcp\"]\n}"
        case .opencodeMCP:
            return "{\n  \"type\": \"local\",\n  \"command\": [\(cmd), \"--mcp\"],\n  \"enabled\": true\n}"
        case .codexTOML:
            return "command = \(cmd)\nargs = [\"--mcp\"]"
        }
    }

    /// A complete example document — what the copy button puts on the pasteboard
    /// and what we write when the client has no config file yet.
    func fileSnippet(executablePath: String) -> String {
        let entry = entryLiteral(executablePath: executablePath)
        if isTOML {
            return "[\(MCPClientConfigurator.tomlTableName)]\n\(entry)"
        }
        let key = MCPClientConfigurator.serverKey
        return "{\n  \"\(containerKey)\": {\n    \"\(key)\": \(MCPClientFormat.indent(entry, by: "    "))\n  }\n}"
    }

    /// Pulls the executable path back out of a parsed entry, so the UI can tell
    /// "already imported" apart from "imported, but pointing at an old bundle".
    func command(from entry: Any) -> String? {
        guard let dict = entry as? [String: Any] else { return nil }
        if self == .opencodeMCP {
            return (dict["command"] as? [Any])?.first as? String
        }
        return dict["command"] as? String
    }

    /// Indents every line but the first, so a multi-line literal keeps its shape
    /// once it is spliced in after `"clipth": `.
    static func indent(_ text: String, by prefix: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return text }
        return ([first] + lines.dropFirst().map { prefix + $0 }).joined(separator: "\n")
    }

    static func jsonQuoted(_ value: String) -> String {
        var out = "\""
        for ch in value.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}

/// One agent app we know how to configure.
struct MCPClientTarget: Identifiable, Sendable {
    let id: String
    let name: String
    /// Last-resort SF Symbol, used only if the bundled art ever goes missing.
    let symbol: String
    /// Bundled brand mark in `Assets.xcassets`. Most of these agents are CLIs
    /// with no app bundle to borrow an icon from, so each one's mark is checked
    /// in from its vendor's own artwork.
    let iconAsset: String
    /// The brand's color, muted to sit in the paper palette. Paints the symbol
    /// chip so every row still reads as a distinct product.
    let tintHex: String
    /// Bundle ids used to find the real app icon and to detect GUI clients.
    let bundleIDs: [String]
    let format: MCPClientFormat
    /// The config file we read and write (absolute, `~` already expanded).
    let configPath: String
    /// Any of these existing means the client is installed even if it has never
    /// written a config file.
    let markerPaths: [String]
    /// Binaries to look for in the usual install dirs (CLI agents).
    let cliNames: [String]

    /// Home-relative path for display, e.g. `~/.codex/config.toml`.
    var displayPath: String {
        let home = NSHomeDirectory()
        guard configPath.hasPrefix(home) else { return configPath }
        return "~" + configPath.dropFirst(home.count)
    }
}

/// The agents we support, most commonly used first.
enum MCPClientCatalog {
    static let all: [MCPClientTarget] = [
        MCPClientTarget(
            id: "claude-code",
            name: "Claude Code",
            symbol: "terminal",
            iconAsset: "AgentClaudeCode",
            tintHex: "C96442",
            bundleIDs: [],
            format: .mcpServersStdio,
            configPath: home(".claude.json"),
            markerPaths: [home(".claude.json"), home(".claude")],
            cliNames: ["claude"]
        ),
        MCPClientTarget(
            id: "codex",
            name: "Codex CLI",
            symbol: "chevron.left.forwardslash.chevron.right",
            iconAsset: "AgentCodex",
            tintHex: "5A5A56",
            bundleIDs: [],
            format: .codexTOML,
            configPath: home(".codex/config.toml"),
            markerPaths: [home(".codex")],
            cliNames: ["codex"]
        ),
        MCPClientTarget(
            id: "claude-desktop",
            name: "Claude Desktop",
            symbol: "bubble.left.and.bubble.right",
            iconAsset: "AgentClaudeDesktop",
            tintHex: "C96442",
            bundleIDs: ["com.anthropic.claudefordesktop"],
            format: .mcpServers,
            configPath: home("Library/Application Support/Claude/claude_desktop_config.json"),
            markerPaths: [home("Library/Application Support/Claude")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "cursor",
            name: "Cursor",
            symbol: "cursorarrow.rays",
            iconAsset: "AgentCursor",
            tintHex: "6E6A63",
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            format: .mcpServers,
            configPath: home(".cursor/mcp.json"),
            markerPaths: [home(".cursor")],
            cliNames: ["cursor-agent"]
        ),
        // OpenClaw itself has no MCP block: it runs MCP servers through the
        // mcporter runtime, so its servers live in mcporter's config.
        MCPClientTarget(
            id: "openclaw",
            name: "OpenClaw",
            symbol: "point.3.connected.trianglepath.dotted",
            iconAsset: "AgentOpenClaw",
            tintHex: "C4553A",
            bundleIDs: [],
            format: .mcpServers,
            configPath: home(".mcporter/config.json"),
            markerPaths: [home(".openclaw"), home(".mcporter")],
            cliNames: ["openclaw", "mcporter"]
        ),
        MCPClientTarget(
            id: "vscode",
            name: "VS Code",
            symbol: "chevron.left.slash.chevron.right",
            iconAsset: "AgentVSCode",
            tintHex: "4A7FA8",
            bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            format: .vscodeServers,
            configPath: home("Library/Application Support/Code/User/mcp.json"),
            markerPaths: [home("Library/Application Support/Code/User")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "zed",
            name: "Zed",
            symbol: "bolt",
            iconAsset: "AgentZed",
            tintHex: "6B72C4",
            bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
            format: .zedContextServers,
            configPath: home(".config/zed/settings.json"),
            markerPaths: [home(".config/zed")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "windsurf",
            name: "Windsurf",
            symbol: "wind",
            iconAsset: "AgentWindsurf",
            tintHex: "3F9A85",
            bundleIDs: ["com.exafunction.windsurf"],
            format: .mcpServers,
            configPath: home(".codeium/windsurf/mcp_config.json"),
            markerPaths: [home(".codeium/windsurf")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "gemini-cli",
            name: "Gemini CLI",
            symbol: "sparkle",
            iconAsset: "AgentGeminiCLI",
            tintHex: "7A81C9",
            bundleIDs: [],
            format: .mcpServers,
            configPath: home(".gemini/settings.json"),
            markerPaths: [home(".gemini")],
            cliNames: ["gemini"]
        ),
        MCPClientTarget(
            id: "opencode",
            name: "opencode",
            symbol: "square.stack.3d.up",
            iconAsset: "AgentOpenCode",
            tintHex: "5E6B5A",
            bundleIDs: [],
            format: .opencodeMCP,
            configPath: home(".config/opencode/opencode.json"),
            markerPaths: [home(".config/opencode")],
            cliNames: ["opencode"]
        ),
        MCPClientTarget(
            id: "qwen-code",
            name: "Qwen Code",
            symbol: "text.bubble",
            iconAsset: "AgentQwenCode",
            tintHex: "8068B8",
            bundleIDs: [],
            format: .mcpServers,
            configPath: home(".qwen/settings.json"),
            markerPaths: [home(".qwen")],
            cliNames: ["qwen"]
        ),
        MCPClientTarget(
            id: "cline",
            name: "Cline",
            symbol: "puzzlepiece.extension",
            iconAsset: "AgentCline",
            tintHex: "5E8C7D",
            bundleIDs: [],
            format: .mcpServers,
            configPath: home("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
            markerPaths: [home("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "kiro",
            name: "Kiro",
            symbol: "wand.and.stars",
            iconAsset: "AgentKiro",
            tintHex: "7B5FBF",
            bundleIDs: ["dev.kiro.desktop"],
            format: .mcpServers,
            configPath: home(".kiro/settings/mcp.json"),
            markerPaths: [home(".kiro")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "lmstudio",
            name: "LM Studio",
            symbol: "cpu",
            iconAsset: "AgentLMStudio",
            tintHex: "6E5BB5",
            bundleIDs: ["ai.elementlabs.lmstudio"],
            format: .mcpServers,
            configPath: home(".lmstudio/mcp.json"),
            markerPaths: [home(".lmstudio")],
            cliNames: []
        ),
        MCPClientTarget(
            id: "amazon-q",
            name: "Amazon Q CLI",
            symbol: "q.circle",
            iconAsset: "AgentAmazonQ",
            tintHex: "C98A3E",
            bundleIDs: ["com.amazon.codewhisperer"],
            format: .mcpServers,
            configPath: home(".aws/amazonq/mcp.json"),
            markerPaths: [home(".aws/amazonq")],
            cliNames: ["q"]
        ),
    ]

    /// `appLookup` is injected because resolving a bundle id needs AppKit, which
    /// this file deliberately stays clear of (it also runs in the headless
    /// `--mcp` process).
    static func isInstalled(_ target: MCPClientTarget, appLookup: (String) -> Bool) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.configPath) { return true }
        if target.markerPaths.contains(where: { fm.fileExists(atPath: $0) }) { return true }
        if target.cliNames.contains(where: { binaryExists($0) }) { return true }
        return target.bundleIDs.contains(where: appLookup)
    }

    /// A GUI app never inherits the user's shell PATH, so probe the dirs package
    /// managers actually install agent CLIs into.
    private static let binDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        home(".local/bin"),
        home(".bun/bin"),
        home(".deno/bin"),
        home(".cargo/bin"),
        home(".volta/bin"),
        home(".npm-global/bin"),
        home(".npm-user-global/bin"),
    ]

    private static func binaryExists(_ name: String) -> Bool {
        let fm = FileManager.default
        return binDirs.contains { fm.isExecutableFile(atPath: $0 + "/" + name) }
    }

    private static func home(_ suffix: String) -> String {
        NSHomeDirectory() + "/" + suffix
    }
}

/// Where a client stands with respect to our entry.
enum MCPClientConfigState: Equatable, Sendable {
    case notConfigured
    case current
    /// Registered, but pointing at a different binary (app moved, or a stale
    /// entry from a previous install location).
    case outdated(String)
    /// The file exists but we can't read or make sense of it — offer the manual
    /// snippet instead of guessing.
    case unreadable
}

/// The slice of a client's config file that importing would touch, so the user
/// can see the exact edit in that file's own syntax before agreeing to it.
struct MCPConfigPreview: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        /// Line number in the file *after* the edit (1-based).
        let number: Int
        let text: String
        let isAdded: Bool
    }

    let lines: [Line]
    /// The client has no config file yet — we'd create one.
    let createsFile: Bool
    /// A `clipth` entry is already there and would be rewritten in place.
    let replacesEntry: Bool

    /// Lines of unchanged file kept around the edit for orientation.
    private static let context = 3

    init(original: String?, updated: String, createsFile: Bool, entryKey: String) {
        self.createsFile = createsFile

        let before = (original ?? "").components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")

        // Our edits are always one contiguous span, so trimming the common head
        // and tail isolates exactly what changed — no real diff needed.
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }

        var changed = head..<max(head, after.count - tail)
        self.replacesEntry = (original ?? "").contains("\"\(entryKey)\"")
            || (original ?? "").contains(".\(entryKey)]")

        // Nothing changed (already imported and pointing at this build): show
        // the existing entry rather than an empty preview.
        if changed.isEmpty, let hit = after.firstIndex(where: { $0.contains(entryKey) }) {
            changed = hit..<(hit + 1)
        }

        let start = max(0, changed.lowerBound - Self.context)
        let end = min(after.count, changed.upperBound + Self.context)
        // A trailing newline leaves an empty last element; don't show it.
        let trimmedEnd = (end == after.count && after.last?.isEmpty == true) ? end - 1 : end

        var lines: [Line] = []
        for index in start..<max(start, trimmedEnd) {
            lines.append(
                Line(
                    id: index,
                    number: index + 1,
                    text: after[index],
                    isAdded: changed.contains(index)
                )
            )
        }
        self.lines = lines
    }
}

enum MCPClientInstallError: LocalizedError {
    case unreadable
    case unsupportedShape
    case verificationFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return L("settings.mcp.error.unreadable")
        case .unsupportedShape: return L("settings.mcp.error.shape")
        case .verificationFailed: return L("settings.mcp.error.verify")
        case .writeFailed(let detail): return L("settings.mcp.error.write", detail)
        }
    }
}

/// Reads and rewrites third-party agent config files.
enum MCPClientConfigurator {
    /// The server name we register ourselves under.
    static let serverKey = "clipth"
    static let tomlTableName = "mcp_servers.\(serverKey)"

    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Clipth.app/Contents/MacOS/Clipth"
    }

    static func state(for target: MCPClientTarget) -> MCPClientConfigState {
        guard FileManager.default.fileExists(atPath: target.configPath) else { return .notConfigured }
        guard let text = try? String(contentsOfFile: target.configPath, encoding: .utf8) else {
            return .unreadable
        }
        if target.format.isTOML {
            guard let command = TOMLConfigText.command(in: text, table: tomlTableName) else {
                return .notConfigured
            }
            return command == executablePath ? .current : .outdated(command)
        }
        guard let root = JSONConfigText.parse(text) else { return .unreadable }
        guard let container = root[target.format.containerKey] as? [String: Any],
              let entry = container[serverKey],
              let command = target.format.command(from: entry) else {
            return .notConfigured
        }
        return command == executablePath ? .current : .outdated(command)
    }

    static func install(into target: MCPClientTarget) throws {
        let original = try readConfig(target)
        let updated = try updatedText(for: target, original: original)
        try write(updated, to: target.configPath, hadOriginal: original != nil)
    }

    /// What `install` would write, without writing it. Shares the exact code
    /// path, so the preview can't drift from the real edit.
    static func preview(for target: MCPClientTarget) throws -> MCPConfigPreview {
        let original = try readConfig(target)
        let updated = try updatedText(for: target, original: original)
        return MCPConfigPreview(
            original: original,
            updated: updated,
            createsFile: original == nil,
            entryKey: serverKey
        )
    }

    private static func readConfig(_ target: MCPClientTarget) throws -> String? {
        guard FileManager.default.fileExists(atPath: target.configPath) else { return nil }
        guard let text = try? String(contentsOfFile: target.configPath, encoding: .utf8) else {
            throw MCPClientInstallError.unreadable
        }
        return text
    }

    private static func updatedText(for target: MCPClientTarget, original: String?) throws -> String {
        let entry = target.format.entryLiteral(executablePath: executablePath)
        let updated: String
        if target.format.isTOML {
            updated = TOMLConfigText.setTable(in: original ?? "", table: tomlTableName, body: entry)
        } else if let base = original, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let edited = JSONConfigText.setEntry(
                in: base,
                container: target.format.containerKey,
                entry: serverKey,
                literal: entry
            ) else {
                throw MCPClientInstallError.unsupportedShape
            }
            updated = edited
        } else {
            updated = target.format.fileSnippet(executablePath: executablePath) + "\n"
        }

        // Never hand a client a file we just broke: re-read our own output and
        // confirm the entry survived before anyone sees it.
        guard command(in: updated, target: target) == executablePath else {
            throw MCPClientInstallError.verificationFailed
        }
        return updated
    }

    static func remove(from target: MCPClientTarget) throws {
        let path = target.configPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw MCPClientInstallError.unreadable
        }

        let updated: String
        if target.format.isTOML {
            updated = TOMLConfigText.removeTable(in: text, table: tomlTableName)
        } else {
            guard let edited = JSONConfigText.removeEntry(
                in: text,
                container: target.format.containerKey,
                entry: serverKey
            ) else {
                throw MCPClientInstallError.unsupportedShape
            }
            updated = edited
        }

        guard command(in: updated, target: target) == nil else {
            throw MCPClientInstallError.verificationFailed
        }
        try write(updated, to: path, hadOriginal: true)
    }

    /// Parses `text` the way the client would and returns our registered command.
    private static func command(in text: String, target: MCPClientTarget) -> String? {
        if target.format.isTOML {
            return TOMLConfigText.command(in: text, table: tomlTableName)
        }
        guard let root = JSONConfigText.parse(text),
              let container = root[target.format.containerKey] as? [String: Any],
              let entry = container[serverKey] else { return nil }
        return target.format.command(from: entry)
    }

    private static func write(_ text: String, to path: String, hadOriginal: Bool) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MCPClientInstallError.writeFailed(error.localizedDescription)
        }

        // These files hold API keys and session state and are often mode 0600.
        // An atomic write replaces the inode with a fresh 0644 file, so capture
        // the original mode and put it back.
        var mode: NSNumber?
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            mode = attrs[.posixPermissions] as? NSNumber
        }

        if hadOriginal {
            let backup = path + ".clipth.bak"
            try? fm.removeItem(atPath: backup)
            try? fm.copyItem(atPath: path, toPath: backup)
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MCPClientInstallError.writeFailed(error.localizedDescription)
        }

        if let mode {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }
}

/// Surgical edits on a JSON (or JSON-with-comments) document.
///
/// Everything works on UTF-8 bytes and returns the original text with one span
/// replaced, so comments, key order, indentation style and any unrelated
/// megabytes of the file survive untouched — which a parse/re-encode round trip
/// would not manage.
enum JSONConfigText {
    /// Sets `root[container][entry] = literal`, creating either level if absent.
    /// Returns nil when the document isn't shaped like we expect (not an
    /// object, or the container key holds something other than an object).
    static func setEntry(in text: String, container: String, entry: String, literal: String) -> String? {
        let bytes = Array(text.utf8)
        guard let rootStart = objectStart(bytes, from: 0),
              let root = members(bytes, objectStart: rootStart) else { return nil }
        let entryKey = "\"\(entry)\""

        guard let holder = root.list.first(where: { $0.name == container }) else {
            // No server map at all — add the whole block at the top of the file.
            let rootIndent = lineIndent(bytes, at: rootStart)
            let keyIndent = rootIndent + "  "
            let valueIndent = keyIndent + "  "
            let block = "{\n\(valueIndent)\(entryKey): "
                + MCPClientFormat.indent(literal, by: valueIndent)
                + "\n\(keyIndent)}"
            if root.list.isEmpty {
                let document = "{\n\(keyIndent)\"\(container)\": \(block)\n\(rootIndent)}"
                return replacing(bytes, rootStart..<(root.closeIndex + 1), with: document)
            }
            let insertion = "\n\(keyIndent)\"\(container)\": \(block),"
            return replacing(bytes, (rootStart + 1)..<(rootStart + 1), with: insertion)
        }

        guard bytes[holder.valueStart] == 0x7B,
              let inner = members(bytes, objectStart: holder.valueStart) else { return nil }
        let holderIndent = lineIndent(bytes, at: holder.keyStart)
        let entryIndent = holderIndent + "  "

        if let existing = inner.list.first(where: { $0.name == entry }) {
            let value = MCPClientFormat.indent(literal, by: entryIndent)
            return replacing(bytes, existing.valueStart..<existing.valueEnd, with: value)
        }
        if inner.list.isEmpty {
            let block = "{\n\(entryIndent)\(entryKey): "
                + MCPClientFormat.indent(literal, by: entryIndent)
                + "\n\(holderIndent)}"
            return replacing(bytes, holder.valueStart..<(inner.closeIndex + 1), with: block)
        }
        let insertion = "\n\(entryIndent)\(entryKey): "
            + MCPClientFormat.indent(literal, by: entryIndent)
            + ","
        let at = holder.valueStart + 1
        return replacing(bytes, at..<at, with: insertion)
    }

    /// Deletes `root[container][entry]` along with the comma and blank line it
    /// leaves behind. A no-op (returns `text`) when the entry isn't there.
    static func removeEntry(in text: String, container: String, entry: String) -> String? {
        let bytes = Array(text.utf8)
        guard let rootStart = objectStart(bytes, from: 0),
              let root = members(bytes, objectStart: rootStart) else { return nil }
        guard let holder = root.list.first(where: { $0.name == container }) else { return text }
        guard bytes[holder.valueStart] == 0x7B,
              let inner = members(bytes, objectStart: holder.valueStart) else { return nil }
        guard let existing = inner.list.first(where: { $0.name == entry }) else { return text }

        var start = existing.keyStart
        var end = existing.valueEnd

        var probe = end
        while probe < bytes.count, isBlank(bytes[probe]) { probe += 1 }
        if probe < bytes.count, bytes[probe] == 0x2C {
            // Followed by a sibling: take our comma with us.
            end = probe + 1
            while end < bytes.count, isBlank(bytes[end]) { end += 1 }
        } else {
            // Last member: take the *previous* comma instead, otherwise the
            // sibling before us is left with a dangling one.
            var back = start - 1
            while back >= 0, isWhitespace(bytes[back]) { back -= 1 }
            if back >= 0, bytes[back] == 0x2C { start = back }
        }
        // Swallow the leftover indentation and the now-empty line.
        while start > 0, isBlank(bytes[start - 1]) { start -= 1 }
        if start > 0, bytes[start - 1] == 0x0A { start -= 1 }

        return replacing(bytes, start..<end, with: "")
    }

    /// Parses a config the way its owner would, tolerating comments and trailing
    /// commas (Zed and VS Code both ship JSONC).
    static func parse(_ text: String) -> [String: Any]? {
        guard let data = stripped(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Scanning

    private struct Member {
        let name: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    private static func objectStart(_ b: [UInt8], from index: Int) -> Int? {
        var i = index
        skipTrivia(b, &i)
        guard i < b.count, b[i] == 0x7B else { return nil }
        return i
    }

    private static func members(_ b: [UInt8], objectStart: Int) -> (list: [Member], closeIndex: Int)? {
        guard objectStart < b.count, b[objectStart] == 0x7B else { return nil }
        var i = objectStart + 1
        var list: [Member] = []
        while true {
            skipTrivia(b, &i)
            guard i < b.count else { return nil }
            if b[i] == 0x7D { return (list, i) }
            if b[i] == 0x2C { i += 1; continue }
            guard b[i] == 0x22 else { return nil }
            let keyStart = i
            var cursor = i
            guard let name = scanString(b, &cursor) else { return nil }
            i = cursor
            skipTrivia(b, &i)
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            var valueStart = i
            skipTrivia(b, &valueStart)
            guard let valueEnd = valueEnd(b, from: valueStart) else { return nil }
            list.append(Member(name: name, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            i = valueEnd
        }
    }

    /// Advances past whitespace and `//` / `/* */` comments.
    private static func skipTrivia(_ b: [UInt8], _ i: inout Int) {
        while i < b.count {
            if isWhitespace(b[i]) { i += 1; continue }
            guard b[i] == 0x2F, i + 1 < b.count else { return }
            if b[i + 1] == 0x2F {
                i += 2
                while i < b.count, b[i] != 0x0A { i += 1 }
                continue
            }
            if b[i + 1] == 0x2A {
                i += 2
                while i + 1 < b.count, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                i = min(i + 2, b.count)
                continue
            }
            return
        }
    }

    /// `i` points at the opening quote; leaves it just past the closing one.
    /// The returned name keeps its escapes — fine, since the keys we match on
    /// (`mcpServers`, `clipth`, …) contain none.
    private static func scanString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, b[i] == 0x22 else { return nil }
        var j = i + 1
        var raw: [UInt8] = []
        while j < b.count {
            let c = b[j]
            if c == 0x5C {
                guard j + 1 < b.count else { return nil }
                raw.append(c)
                raw.append(b[j + 1])
                j += 2
                continue
            }
            if c == 0x22 {
                i = j + 1
                return String(decoding: raw, as: UTF8.self)
            }
            raw.append(c)
            j += 1
        }
        return nil
    }

    private static func valueEnd(_ b: [UInt8], from start: Int) -> Int? {
        var i = start
        skipTrivia(b, &i)
        guard i < b.count else { return nil }
        let c = b[i]
        if c == 0x22 {
            var j = i
            guard scanString(b, &j) != nil else { return nil }
            return j
        }
        if c == 0x7B || c == 0x5B {
            let open = c
            let close: UInt8 = (c == 0x7B) ? 0x7D : 0x5D
            var depth = 0
            var j = i
            while j < b.count {
                skipTrivia(b, &j)
                guard j < b.count else { return nil }
                let ch = b[j]
                if ch == 0x22 {
                    var k = j
                    guard scanString(b, &k) != nil else { return nil }
                    j = k
                    continue
                }
                if ch == open { depth += 1; j += 1; continue }
                if ch == close {
                    depth -= 1
                    j += 1
                    if depth == 0 { return j }
                    continue
                }
                j += 1
            }
            return nil
        }
        // Number / true / false / null: runs until a delimiter.
        var j = i
        while j < b.count {
            let ch = b[j]
            if ch == 0x2C || ch == 0x7D || ch == 0x5D || ch == 0x2F || isWhitespace(ch) { break }
            j += 1
        }
        return j > i ? j : nil
    }

    /// Leading whitespace of the line containing `index`.
    private static func lineIndent(_ b: [UInt8], at index: Int) -> String {
        var start = index
        while start > 0, b[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < b.count, isBlank(b[end]) { end += 1 }
        return String(decoding: b[start..<min(end, index)], as: UTF8.self)
    }

    private static func replacing(_ b: [UInt8], _ range: Range<Int>, with text: String) -> String {
        var out = Array(b[0..<range.lowerBound])
        out.append(contentsOf: Array(text.utf8))
        out.append(contentsOf: Array(b[range.upperBound...]))
        return String(decoding: out, as: UTF8.self)
    }

    /// Removes comments and trailing commas so `JSONSerialization` (strict JSON)
    /// can read a JSONC file.
    private static func stripped(_ text: String) -> String {
        let b = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x22 {
                out.append(c)
                i += 1
                while i < b.count {
                    let ch = b[i]
                    out.append(ch)
                    if ch == 0x5C, i + 1 < b.count {
                        out.append(b[i + 1])
                        i += 2
                        continue
                    }
                    i += 1
                    if ch == 0x22 { break }
                }
                continue
            }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2F {
                while i < b.count, b[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2A {
                i += 2
                while i + 1 < b.count, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                i = min(i + 2, b.count)
                continue
            }
            if c == 0x2C {
                var j = i + 1
                while j < b.count, isWhitespace(b[j]) { j += 1 }
                if j < b.count, b[j] == 0x7D || b[j] == 0x5D { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    /// Whitespace that isn't a line break.
    private static func isBlank(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D
    }
}

/// Line-level edits on Codex's `config.toml`.
///
/// Line-based rather than a real TOML parse for the same reason as the JSON
/// side: `~/.codex/config.toml` is the user's own hand-written file, and a
/// round trip through a serializer would reflow all of it.
enum TOMLConfigText {
    static func setTable(in text: String, table: String, body: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let block = ["[\(table)]"] + body.components(separatedBy: "\n")
        if let range = tableRange(lines, table: table) {
            lines.replaceSubrange(range, with: block)
            return lines.joined(separator: "\n")
        }
        var prefix = text
        if !prefix.isEmpty {
            while prefix.hasSuffix("\n") { prefix.removeLast() }
            prefix += "\n\n"
        }
        return prefix + block.joined(separator: "\n") + "\n"
    }

    static func removeTable(in text: String, table: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let range = tableRange(lines, table: table) else { return text }
        lines.replaceSubrange(range, with: [])
        // Collapse the blank line the table used to be separated by.
        if range.lowerBound > 0, range.lowerBound < lines.count,
           lines[range.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty,
           lines[range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: range.lowerBound)
        }
        return lines.joined(separator: "\n")
    }

    /// The `command = "…"` value inside the table, if the table exists.
    static func command(in text: String, table: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = tableRange(lines, table: table) else { return nil }
        for line in lines[range] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.count >= 2, value.hasSuffix("\"") else { continue }
            let inner = value.dropFirst().dropLast()
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    /// The table header line through the last line before the next table that
    /// isn't one of ours (`[mcp_servers.clipth.env]` stays inside).
    private static func tableRange(_ lines: [String], table: String) -> Range<Int>? {
        let quoted = quotedHeader(table)
        let headers = ["[\(table)]", quoted]
        guard let start = lines.firstIndex(where: {
            headers.contains($0.trimmingCharacters(in: .whitespaces))
        }) else { return nil }

        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let isChild = trimmed.hasPrefix("[\(table).") || trimmed.hasPrefix("[[\(table).")
                if !isChild { break }
            }
            end += 1
        }
        // Don't drag the blank line before the next table along.
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return start..<end
    }

    /// Codex also accepts `[mcp_servers."clipth"]`, so match that spelling too.
    private static func quotedHeader(_ table: String) -> String {
        guard let dot = table.lastIndex(of: ".") else { return "[\"\(table)\"]" }
        let parent = table[table.startIndex..<dot]
        let leaf = table[table.index(after: dot)...]
        return "[\(parent).\"\(leaf)\"]"
    }
}
