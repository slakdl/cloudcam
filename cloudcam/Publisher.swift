import Foundation
import Security

/// Publishes photos to the website: each one is uploaded into the GitHub repository at
/// `docs/photos/`, and added to the top of `docs/photos.json`, the list the gallery page
/// reads. GitHub Pages then rebuilds the site, usually within a minute.
///
/// Photos are first written to a queue on the phone, so nothing is lost without a signal:
/// whatever couldn't be sent is tried again next time you publish or open the app.
actor Publisher {
    static let shared = Publisher()

    private let repository = "slakdl/cloudcam"
    private let branch = "main"

    enum Failure: Error {
        case noToken
        case rejected(status: Int)
        /// GitHub said no, with its own explanation.
        case refused(status: Int, reason: String)
    }

    /// One photo waiting to go up.
    private struct Pending: Codable {
        var name: String  // e.g. 2026-10-03-091512.jpg
        var takenAt: Date
        var camera: String?  // which look took it, e.g. "Spider"
    }

    /// An entry in `photos.json`.
    private struct Entry: Codable {
        var src: String
        var takenAt: String
        var camera: String?
    }

    private var isSending = false

    // MARK: - Public

    /// Puts the photo in the queue and tries to send everything that's waiting.
    /// Returns how many photos are still waiting afterwards (0 means all published).
    func publish(_ jpeg: Data, takenAt: Date, camera: String) async throws -> Int {
        let name = Self.fileName(for: takenAt)
        try jpeg.write(to: queueFolder.appendingPathComponent(name))
        let info = try JSONEncoder.iso.encode(Pending(name: name, takenAt: takenAt, camera: camera))
        try info.write(to: queueFolder.appendingPathComponent(name + ".json"))
        return try await sendWaiting()
    }

    /// Tries to send whatever is waiting in the queue. Returns how many are still waiting.
    @discardableResult
    func sendWaiting() async throws -> Int {
        guard !isSending else { return waiting().count }
        isSending = true
        defer { isSending = false }

        guard let token = Keychain.token, !token.isEmpty else {
            if waiting().isEmpty { return 0 }
            throw Failure.noToken
        }

        for pending in waiting() {
            let file = queueFolder.appendingPathComponent(pending.name)
            let jpeg = try Data(contentsOf: file)
            try await upload(jpeg, to: "docs/photos/\(pending.name)", message: "Add photo \(pending.name)", token: token)
            try await addToList(pending, token: token)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("json"))
        }
        return waiting().count
    }

    /// Checks that a token works and can see the repository.
    func check(token: String) async -> Bool {
        var request = Self.request(path: "", token: token)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Queue

    private var queueFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PublishQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Everything waiting, oldest first, so the list on the site stays in order.
    private func waiting() -> [Pending] {
        let files = (try? FileManager.default.contentsOfDirectory(at: queueFolder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.iso.decode(Pending.self, from: Data(contentsOf: $0)) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    private static func fileName(for date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return format.string(from: date) + ".jpg"
    }

    // MARK: - GitHub

    private func upload(_ jpeg: Data, to path: String, message: String, token: String) async throws {
        // If an earlier attempt got this far before failing, the file is already there.
        if try await existingFile(at: path, token: token) != nil { return }
        try await put(path: path, content: jpeg, message: message, sha: nil, token: token)
    }

    /// Adds the photo to the top of photos.json. If someone else changed the list at the same
    /// moment, GitHub refuses the save, so read it again and retry.
    private func addToList(_ pending: Pending, token: String) async throws {
        let path = "docs/photos.json"
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            let existing = try await existingFile(at: path, token: token)
            var entries = (existing.flatMap { try? JSONDecoder().decode([Entry].self, from: $0.content) }) ?? []
            let src = "photos/\(pending.name)"
            guard !entries.contains(where: { $0.src == src }) else { return }

            entries.insert(Entry(src: src, takenAt: ISO8601DateFormatter().string(from: pending.takenAt), camera: pending.camera), at: 0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            do {
                try await put(path: path, content: try encoder.encode(entries),
                              message: "List photo \(pending.name)", sha: existing?.sha, token: token)
                return
            } catch Failure.rejected(let status) where status == 409 || status == 422 {
                continue
            }
        }
        throw Failure.rejected(status: 409)
    }

    private func existingFile(at path: String, token: String) async throws -> (content: Data, sha: String)? {
        var request = Self.request(path: "/contents/\(path)?ref=\(branch)", token: token)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.rejected(status: status) }

        struct File: Decodable { var sha: String; var content: String? }
        let file = try JSONDecoder().decode(File.self, from: data)
        let base64 = (file.content ?? "").replacingOccurrences(of: "\n", with: "")
        return (Data(base64Encoded: base64) ?? Data(), file.sha)
    }

    private func put(path: String, content: Data, message: String, sha: String?, token: String) async throws {
        var request = Self.request(path: "/contents/\(path)", token: token)
        request.httpMethod = "PUT"
        var body: [String: String] = ["message": message, "content": content.base64EncodedString(), "branch": branch]
        if let sha { body["sha"] = sha }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            if status == 401 || status == 403 || status == 404 {
                // 404 here means the token can't see the repository at all.
                struct Message: Decodable { var message: String }
                let reason = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? "HTTP \(status)"
                throw Failure.refused(status: status, reason: reason)
            }
            throw Failure.rejected(status: status)
        }
    }

    private static func request(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/slakdl/cloudcam\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 60
        // Never answer from the phone's cache: GitHub marks these as cacheable for a minute,
        // and an out-of-date photos.json makes the next save clash with the last one.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }
}

/// Keeps the GitHub token in the iPhone's Keychain, never in the code or the repository.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cloudcam.github",
        kSecAttrAccount as String: "token",
    ]

    static var token: String? {
        get {
            var search = query
            search[kSecReturnData as String] = true
            var result: AnyObject?
            guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(newValue.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
