import CryptoKit
import Foundation

protocol SyncTransport: Sendable {
    var displayLocation: String { get }
    func prepare() async throws
    func readManifest() async throws -> SyncRemoteManifest?
    func writeManifest(_ data: Data, replacing revision: String?) async throws
    func readAttachment(named name: String) async throws -> Data
    func writeAttachmentIfNeeded(_ data: Data, named name: String) async throws
    func listAttachments() async throws -> [SyncRemoteObject]
    func deleteAttachment(named name: String) async throws
    func listJournalEntries() async throws -> [SyncRemoteObject]
    func readJournalEntry(named name: String) async throws -> Data
    func writeJournalEntryIfNeeded(_ data: Data, named name: String) async throws
    func deleteJournalEntry(named name: String) async throws
}

struct SyncRemoteObject: Equatable, Sendable {
    let name: String
    let modifiedAt: Date?
}

struct SyncRemoteManifest: Sendable {
    let data: Data
    /// Opaque compare-and-swap token. WebDAV uses an ETag where available;
    /// filesystem backends use the encrypted file's SHA-256 digest.
    let revision: String
}

struct FileSyncTransport: SyncTransport {
    let rootURL: URL
    let securityScoped: Bool

    var displayLocation: String { rootURL.path }

    func prepare() async throws {
        try await withRoot { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("attachments", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("journal", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func readManifest() async throws -> SyncRemoteManifest? {
        try await withRoot { root in
            let url = root.appendingPathComponent("manifest.cte")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try requestUbiquitousDownloadIfNeeded(url)
            let data = try Data(contentsOf: url)
            return SyncRemoteManifest(data: data, revision: "hash:\(SyncDigest.hash(data))")
        }
    }

    func writeManifest(_ data: Data, replacing revision: String?) async throws {
        try await withRoot { root in
            let url = root.appendingPathComponent("manifest.cte")
            let fileManager = FileManager.default
            if let revision {
                guard let current = try? Data(contentsOf: url),
                      revision == "hash:\(SyncDigest.hash(current))" else {
                    throw SyncTransportError.concurrentChange
                }
            } else if fileManager.fileExists(atPath: url.path) {
                throw SyncTransportError.concurrentChange
            }
            try data.write(to: url, options: .atomic)
        }
    }

    func readAttachment(named name: String) async throws -> Data {
        try await withRoot { root in
            var url = root
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(safeFileName(name))
            if !FileManager.default.fileExists(atPath: url.path) {
                let legacy = root.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent(legacySafeFileName(name))
                if FileManager.default.fileExists(atPath: legacy.path) { url = legacy }
            }
            try requestUbiquitousDownloadIfNeeded(url)
            return try Data(contentsOf: url)
        }
    }

    func writeAttachmentIfNeeded(_ data: Data, named name: String) async throws {
        try await withRoot { root in
            let url = root
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(safeFileName(name))
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try data.write(to: url, options: .atomic)
        }
    }

    func listAttachments() async throws -> [SyncRemoteObject] {
        try await listObjects(in: "attachments")
    }

    func deleteAttachment(named name: String) async throws {
        try await deleteObject(in: "attachments", named: name)
    }

    func listJournalEntries() async throws -> [SyncRemoteObject] {
        try await listObjects(in: "journal")
    }

    func readJournalEntry(named name: String) async throws -> Data {
        try await readObject(in: "journal", named: name)
    }

    func writeJournalEntryIfNeeded(_ data: Data, named name: String) async throws {
        try await writeObjectIfNeeded(data, in: "journal", named: name)
    }

    func deleteJournalEntry(named name: String) async throws {
        try await deleteObject(in: "journal", named: name)
    }

    private func listObjects(in directory: String) async throws -> [SyncRemoteObject] {
        try await withRoot { root in
            let url = root.appendingPathComponent(directory, isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return names.compactMap { file in
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return SyncRemoteObject(name: file.lastPathComponent, modifiedAt: values?.contentModificationDate)
            }.sorted { $0.name < $1.name }
        }
    }

    private func readObject(in directory: String, named name: String) async throws -> Data {
        try await withRoot { root in
            let url = root.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(safeFileName(name))
            try requestUbiquitousDownloadIfNeeded(url)
            return try Data(contentsOf: url)
        }
    }

    private func writeObjectIfNeeded(_ data: Data, in directory: String, named name: String) async throws {
        try await withRoot { root in
            let url = root.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(safeFileName(name))
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try data.write(to: url, options: .atomic)
        }
    }

    private func deleteObject(in directory: String, named name: String) async throws {
        try await withRoot { root in
            let url = root.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(safeFileName(name))
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func withRoot<T: Sendable>(_ operation: @escaping @Sendable (URL) throws -> T) async throws -> T {
        let rootURL = rootURL
        let securityScoped = securityScoped
        return try await Task.detached(priority: .utility) {
            let accessing = securityScoped && rootURL.startAccessingSecurityScopedResource()
            defer { if accessing { rootURL.stopAccessingSecurityScopedResource() } }
            return try operation(rootURL)
        }.value
    }

    private func requestUbiquitousDownloadIfNeeded(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func safeFileName(_ name: String) -> String {
        name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private func legacySafeFileName(_ name: String) -> String {
        name.filter { $0.isHexDigit || $0 == "." }
    }
}

struct WebDAVSyncTransport: SyncTransport {
    let baseURL: URL
    let username: String
    let password: String
    let session: URLSession

    init(
        baseURL: URL,
        username: String,
        password: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    private var rootURL: URL {
        baseURL.appendingPathComponent(".cliptrace-sync-v1", isDirectory: true)
    }

    var displayLocation: String { rootURL.absoluteString }

    func prepare() async throws {
        try await makeCollection(rootURL)
        try await makeCollection(rootURL.appendingPathComponent("attachments", isDirectory: true))
        try await makeCollection(rootURL.appendingPathComponent("journal", isDirectory: true))
    }

    func readManifest() async throws -> SyncRemoteManifest? {
        let (data, response) = try await send(
            method: "GET",
            url: rootURL.appendingPathComponent("manifest.cte")
        )
        if response.statusCode == 404 { return nil }
        try validate(response, accepted: 200...299)
        let revision = response.value(forHTTPHeaderField: "ETag").map { "etag:\($0)" }
            ?? "hash:\(SyncDigest.hash(data))"
        return SyncRemoteManifest(data: data, revision: revision)
    }

    func writeManifest(_ data: Data, replacing revision: String?) async throws {
        var headers: [String: String] = [:]
        if let revision, revision.hasPrefix("etag:") {
            headers["If-Match"] = String(revision.dropFirst("etag:".count))
        } else if let revision, revision.hasPrefix("hash:") {
            // A few WebDAV servers omit ETag. Re-read immediately before PUT
            // and compare the encrypted bytes so they still get optimistic
            // concurrency protection (with a smaller unavoidable race window).
            guard let current = try await readManifest(), current.revision == revision else {
                throw SyncTransportError.concurrentChange
            }
        } else {
            headers["If-None-Match"] = "*"
        }
        let (_, response) = try await send(
            method: "PUT",
            url: rootURL.appendingPathComponent("manifest.cte"),
            body: data,
            contentType: "application/octet-stream",
            headers: headers
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw SyncTransportError.concurrentChange
        }
        try validate(response, accepted: 200...299)
    }

    func readAttachment(named name: String) async throws -> Data {
        var (data, response) = try await send(method: "GET", url: attachmentURL(name))
        if response.statusCode == 404 {
            let legacyURL = legacyAttachmentURL(name)
            if legacyURL != attachmentURL(name) {
                (data, response) = try await send(method: "GET", url: legacyURL)
            }
        }
        try validate(response, accepted: 200...299)
        return data
    }

    func writeAttachmentIfNeeded(_ data: Data, named name: String) async throws {
        let url = attachmentURL(name)
        let (_, headResponse) = try await send(method: "HEAD", url: url)
        if (200...299).contains(headResponse.statusCode) { return }
        guard headResponse.statusCode == 404 || headResponse.statusCode == 405 else {
            try validate(headResponse, accepted: 200...299)
            return
        }

        let (_, response) = try await send(
            method: "PUT",
            url: url,
            body: data,
            contentType: "application/octet-stream"
        )
        try validate(response, accepted: 200...299)
    }

    func listAttachments() async throws -> [SyncRemoteObject] {
        try await listObjects(at: rootURL.appendingPathComponent("attachments", isDirectory: true))
    }

    func deleteAttachment(named name: String) async throws {
        try await deleteObject(at: attachmentURL(name))
    }

    func listJournalEntries() async throws -> [SyncRemoteObject] {
        try await listObjects(at: rootURL.appendingPathComponent("journal", isDirectory: true))
    }

    func readJournalEntry(named name: String) async throws -> Data {
        let (data, response) = try await send(method: "GET", url: journalURL(name))
        try validate(response, accepted: 200...299)
        return data
    }

    func writeJournalEntryIfNeeded(_ data: Data, named name: String) async throws {
        let (_, response) = try await send(
            method: "PUT",
            url: journalURL(name),
            body: data,
            contentType: "application/octet-stream",
            headers: ["If-None-Match": "*"]
        )
        guard response.statusCode != 412 else { return }
        try validate(response, accepted: 200...299)
    }

    func deleteJournalEntry(named name: String) async throws {
        try await deleteObject(at: journalURL(name))
    }

    private func listObjects(at collectionURL: URL) async throws -> [SyncRemoteObject] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await send(
            method: "PROPFIND",
            url: collectionURL,
            body: body,
            contentType: "application/xml; charset=utf-8",
            headers: ["Depth": "1"]
        )
        try validate(response, accepted: 200...299)
        return try WebDAVObjectListParser.parse(data, excluding: collectionURL.lastPathComponent)
    }

    private func deleteObject(at url: URL) async throws {
        let (_, response) = try await send(method: "DELETE", url: url)
        guard response.statusCode != 404 else { return }
        try validate(response, accepted: 200...299)
    }

    private func makeCollection(_ url: URL) async throws {
        let (_, response) = try await send(method: "MKCOL", url: url)
        // 405 is the common WebDAV response when the collection already exists.
        guard response.statusCode == 405 || (200...299).contains(response.statusCode) else {
            throw WebDAVSyncError.http(response.statusCode)
        }
    }

    private func attachmentURL(_ name: String) -> URL {
        rootURL
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(safeObjectName(name))
    }

    private func legacyAttachmentURL(_ name: String) -> URL {
        rootURL
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(name.filter { $0.isHexDigit || $0 == "." })
    }

    private func journalURL(_ name: String) -> URL {
        rootURL
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent(safeObjectName(name))
    }

    private func safeObjectName(_ name: String) -> String {
        name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private func send(
        method: String,
        url: URL,
        body: Data? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("ClipTrace/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if !username.isEmpty || !password.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVSyncError.invalidResponse
        }
        return (data, http)
    }

    private func validate(_ response: HTTPURLResponse, accepted: ClosedRange<Int>) throws {
        guard accepted.contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw WebDAVSyncError.authentication
            }
            throw WebDAVSyncError.http(response.statusCode)
        }
    }
}

private final class WebDAVObjectListParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var currentHref: String?
    private var currentModifiedAt: Date?
    private var objects: [SyncRemoteObject] = []

    static func parse(_ data: Data, excluding collectionName: String) throws -> [SyncRemoteObject] {
        let delegate = WebDAVObjectListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw WebDAVSyncError.invalidResponse }
        return delegate.objects.filter { $0.name != collectionName }.sorted { $0.name < $1.name }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""
        if currentElement.hasSuffix("response") {
            currentHref = nil
            currentModifiedAt = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if element.hasSuffix("href") {
            currentHref = value
        } else if element.hasSuffix("getlastmodified") {
            currentModifiedAt = Self.httpDateFormatter.date(from: value)
        } else if element.hasSuffix("response"), let href = currentHref {
            let decoded = href.removingPercentEncoding ?? href
            let name = URL(string: decoded)?.lastPathComponent ?? (decoded as NSString).lastPathComponent
            if !name.isEmpty {
                objects.append(SyncRemoteObject(name: name, modifiedAt: currentModifiedAt))
            }
        }
        currentElement = ""
        currentText = ""
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

struct S3SyncConfiguration: Sendable {
    let endpoint: URL
    let region: String
    let bucket: String
    let prefix: String
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String
    let pathStyle: Bool

    var isValid: Bool {
        let scheme = endpoint.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") &&
            endpoint.host != nil && !region.isEmpty && !bucket.isEmpty &&
            !accessKeyID.isEmpty && !secretAccessKey.isEmpty
    }
}

struct S3SyncTransport: SyncTransport {
    let configuration: S3SyncConfiguration
    let session: URLSession
    let now: @Sendable () -> Date

    init(
        configuration: S3SyncConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session
        self.now = now
    }

    var displayLocation: String {
        let prefix = normalizedPrefix
        return "s3://\(configuration.bucket)/\(prefix.isEmpty ? "" : "\(prefix)/").cliptrace-sync-v1"
    }

    func prepare() async throws {
        guard configuration.isValid else { throw S3SyncError.invalidConfiguration }
        _ = try await listObjects(in: "", maximumKeys: 1)
    }

    func readManifest() async throws -> SyncRemoteManifest? {
        let (data, response) = try await send(method: "GET", key: objectKey("manifest.cte"))
        if response.statusCode == 404 { return nil }
        try validate(response)
        let revision = response.value(forHTTPHeaderField: "ETag").map { "etag:\($0)" }
            ?? "hash:\(SyncDigest.hash(data))"
        return SyncRemoteManifest(data: data, revision: revision)
    }

    func writeManifest(_ data: Data, replacing revision: String?) async throws {
        var headers: [String: String] = [:]
        if let revision, revision.hasPrefix("etag:") {
            headers["If-Match"] = String(revision.dropFirst("etag:".count))
        } else if let revision, revision.hasPrefix("hash:") {
            guard let current = try await readManifest(), current.revision == revision else {
                throw SyncTransportError.concurrentChange
            }
        } else {
            headers["If-None-Match"] = "*"
        }
        let (_, response) = try await send(
            method: "PUT",
            key: objectKey("manifest.cte"),
            body: data,
            headers: headers
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw SyncTransportError.concurrentChange
        }
        try validate(response)
    }

    func readAttachment(named name: String) async throws -> Data {
        var (data, response) = try await send(method: "GET", key: objectKey("attachments/\(safeName(name))"))
        if response.statusCode == 404 {
            let legacy = name.filter { $0.isHexDigit || $0 == "." }
            if legacy != name {
                (data, response) = try await send(method: "GET", key: objectKey("attachments/\(legacy)"))
            }
        }
        try validate(response)
        return data
    }

    func writeAttachmentIfNeeded(_ data: Data, named name: String) async throws {
        try await writeImmutable(data, key: objectKey("attachments/\(safeName(name))"))
    }

    func listAttachments() async throws -> [SyncRemoteObject] {
        try await listObjects(in: "attachments/")
    }

    func deleteAttachment(named name: String) async throws {
        try await delete(key: objectKey("attachments/\(safeName(name))"))
    }

    func listJournalEntries() async throws -> [SyncRemoteObject] {
        try await listObjects(in: "journal/")
    }

    func readJournalEntry(named name: String) async throws -> Data {
        let (data, response) = try await send(method: "GET", key: objectKey("journal/\(safeName(name))"))
        try validate(response)
        return data
    }

    func writeJournalEntryIfNeeded(_ data: Data, named name: String) async throws {
        try await writeImmutable(data, key: objectKey("journal/\(safeName(name))"))
    }

    func deleteJournalEntry(named name: String) async throws {
        try await delete(key: objectKey("journal/\(safeName(name))"))
    }

    private var normalizedPrefix: String {
        configuration.prefix.split(separator: "/").map(String.init).joined(separator: "/")
    }

    private var rootKey: String {
        [normalizedPrefix, ".cliptrace-sync-v1"].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func objectKey(_ suffix: String) -> String {
        "\(rootKey)/\(suffix)"
    }

    private func safeName(_ name: String) -> String {
        name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private func writeImmutable(_ data: Data, key: String) async throws {
        let (_, response) = try await send(
            method: "PUT",
            key: key,
            body: data,
            headers: ["If-None-Match": "*"]
        )
        guard response.statusCode != 412 else { return }
        try validate(response)
    }

    private func delete(key: String) async throws {
        let (_, response) = try await send(method: "DELETE", key: key)
        guard response.statusCode != 404 else { return }
        try validate(response)
    }

    private func listObjects(in directory: String, maximumKeys: Int = 1_000) async throws -> [SyncRemoteObject] {
        let prefix = objectKey(directory)
        var continuationToken: String?
        var result: [SyncRemoteObject] = []
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "max-keys", value: String(maximumKeys)),
                URLQueryItem(name: "prefix", value: prefix)
            ]
            if let continuationToken {
                query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }
            let (data, response) = try await send(method: "GET", query: query)
            try validate(response)
            let page = try S3ObjectListParser.parse(data)
            result.append(contentsOf: page.objects.compactMap { object in
                guard object.key.hasPrefix(prefix) else { return nil }
                let name = String(object.key.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return name.isEmpty ? nil : SyncRemoteObject(name: name, modifiedAt: object.modifiedAt)
            })
            continuationToken = page.isTruncated ? page.nextContinuationToken : nil
        } while continuationToken != nil
        return result.sorted { $0.name < $1.name }
    }

    private func send(
        method: String,
        key: String? = nil,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try requestURL(key: key, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("ClipTrace/1", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request = try AWSSigV4Signer.sign(
            request,
            body: body ?? Data(),
            region: configuration.region,
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            sessionToken: configuration.sessionToken,
            date: now()
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3SyncError.invalidResponse }
        return (data, http)
    }

    private func requestURL(key: String?, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        guard components?.host != nil else { throw S3SyncError.invalidConfiguration }
        var pathSegments: [String] = []
        if configuration.pathStyle {
            pathSegments.append(configuration.bucket)
        } else if let host = components?.host {
            components?.host = "\(configuration.bucket).\(host)"
        }
        if let key { pathSegments.append(contentsOf: key.split(separator: "/").map(String.init)) }
        var url = components?.url
        for segment in pathSegments { url?.appendPathComponent(segment) }
        guard var final = url, var finalComponents = URLComponents(url: final, resolvingAgainstBaseURL: false) else {
            throw S3SyncError.invalidConfiguration
        }
        finalComponents.queryItems = query.isEmpty ? nil : query
        guard let completed = finalComponents.url else { throw S3SyncError.invalidConfiguration }
        final = completed
        return final
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw S3SyncError.authentication
            }
            throw S3SyncError.http(response.statusCode)
        }
    }
}

enum AWSSigV4Signer {
    static func sign(
        _ request: URLRequest,
        body: Data,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String,
        date: Date
    ) throws -> URLRequest {
        guard let url = request.url, let host = canonicalHost(for: url),
              let method = request.httpMethod else { throw S3SyncError.invalidConfiguration }
        var result = request
        let timestamp = amzDateFormatter.string(from: date)
        let dateStamp = shortDateFormatter.string(from: date)
        let payloadHash = SyncDigest.hash(body)
        result.setValue(host, forHTTPHeaderField: "Host")
        result.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        result.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if !sessionToken.isEmpty {
            result.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        var canonicalHeaders: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", timestamp)
        ]
        if !sessionToken.isEmpty {
            canonicalHeaders.append(("x-amz-security-token", sessionToken))
        }
        canonicalHeaders.sort { $0.0 < $1.0 }
        let signedHeaders = canonicalHeaders.map(\.0).joined(separator: ";")
        let headerBlock = canonicalHeaders.map { "\($0.0):\(normalizedHeader($0.1))\n" }.joined()
        let canonicalRequest = [
            method,
            canonicalURI(url),
            canonicalQuery(url),
            headerBlock,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            SyncDigest.hash(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), message: dateStamp)
        let regionKey = hmac(key: dateKey, message: region)
        let serviceKey = hmac(key: regionKey, message: "s3")
        let signingKey = hmac(key: serviceKey, message: "aws4_request")
        let signature = hmac(key: signingKey, message: stringToSign)
            .map { String(format: "%02x", $0) }.joined()
        result.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return result
    }

    private static func canonicalHost(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        guard let port = url.port else { return host }
        let defaultPort = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return defaultPort ? host : "\(host):\(port)"
    }

    private static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "" }
        let encoded: [(name: String, value: String)] = query.map { item in
            (name: awsEncode(item.name), value: awsEncode(item.value ?? ""))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func awsEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func normalizedHeader(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

private final class S3ObjectListParser: NSObject, XMLParserDelegate {
    struct Page {
        struct Object {
            let key: String
            let modifiedAt: Date?
        }
        let objects: [Object]
        let isTruncated: Bool
        let nextContinuationToken: String?
    }

    private var currentElement = ""
    private var currentText = ""
    private var currentKey: String?
    private var currentModifiedAt: Date?
    private var objects: [Page.Object] = []
    private var isTruncated = false
    private var nextContinuationToken: String?

    static func parse(_ data: Data) throws -> Page {
        let delegate = S3ObjectListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw S3SyncError.invalidResponse }
        return Page(
            objects: delegate.objects,
            isTruncated: delegate.isTruncated,
            nextContinuationToken: delegate.nextContinuationToken
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            currentKey = nil
            currentModifiedAt = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key": currentKey = value
        case "LastModified": currentModifiedAt = Self.isoFormatter.date(from: value)
        case "Contents":
            if let key = currentKey { objects.append(Page.Object(key: key, modifiedAt: currentModifiedAt)) }
        case "IsTruncated": isTruncated = value.lowercased() == "true"
        case "NextContinuationToken": nextContinuationToken = value.isEmpty ? nil : value
        default: break
        }
        currentElement = ""
        currentText = ""
    }

    private static let isoFormatter = ISO8601DateFormatter()
}

enum SyncTransportError: LocalizedError {
    case concurrentChange

    var errorDescription: String? {
        L("settings.sync.error.concurrentChange")
    }
}

enum WebDAVSyncError: LocalizedError {
    case invalidURL
    case invalidResponse
    case authentication
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("settings.sync.error.webdavURL")
        case .invalidResponse:
            return L("settings.sync.error.webdavResponse")
        case .authentication:
            return L("settings.sync.error.webdavAuth")
        case .http(let code):
            return L("settings.sync.error.webdavHTTP", code)
        }
    }
}

enum S3SyncError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case authentication
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L("settings.sync.error.s3Configuration")
        case .invalidResponse:
            return L("settings.sync.error.s3Response")
        case .authentication:
            return L("settings.sync.error.s3Auth")
        case .http(let code):
            return L("settings.sync.error.s3HTTP", code)
        }
    }
}
