import Foundation
import Security

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Talks to the Aibo Worker. Signing in (Apple or an email code) returns a session token,
/// kept in the Keychain; every request after that reaches the user's own cloud agent.
final class API: @unchecked Sendable {
    static let shared = API()
    /// Posted when the server no longer accepts the session (signed out elsewhere, account deleted).
    static let sessionEnded = Notification.Name("AiboSessionEnded")

    let base: URL
    private let session: URLSession
    private var token: String?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        base = URL(string: (info["AiboAPIBase"] as? String) ?? "http://localhost:8799")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
        token = Keychain.read("session")
    }

    var isSignedIn: Bool { token != nil }

    private func adopt(_ auth: AuthResult) -> AuthResult {
        Keychain.write("session", auth.token)
        token = auth.token
        return auth
    }

    /// Forgets the session on this device (the server session is revoked separately).
    func forget() {
        Keychain.delete("session")
        token = nil
    }

    // MARK: sign-in

    func sendCode(to email: String) async throws {
        try await call("/v1/auth/email/start", method: "POST", body: ["email": email])
    }

    func verify(email: String, code: String) async throws -> AuthResult {
        adopt(try await send("/v1/auth/email/verify", method: "POST", body: ["email": email, "code": code]))
    }

    func signInWithApple(identityToken: String, name: String?) async throws -> AuthResult {
        struct Body: Encodable { let identityToken: String; let name: String? }
        return adopt(try await send("/v1/auth/apple", method: "POST", body: Body(identityToken: identityToken, name: name)))
    }

    func me() async throws -> Account {
        struct R: Decodable { let user: Account }
        return try await send("/v1/auth/me", as: R.self).user
    }

    func signOut() async {
        try? await call("/v1/auth/signout", method: "POST")
        forget()
    }

    func deleteAccount() async throws {
        try await call("/v1/account", method: "DELETE")
        forget()
    }

    // MARK: requests

    private func request(_ path: String, method: String = "GET", body: Encodable? = nil) throws -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        req.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "X-Locale")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func check(_ res: URLResponse, _ data: Data) throws {
        guard let http = res as? HTTPURLResponse else { return }
        if http.statusCode == 401, token != nil {
            forget()
            NotificationCenter.default.post(name: Self.sessionEnded, object: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError(status: http.statusCode, message: msg ?? "Request failed (\(http.statusCode))")
        }
    }

    func send<T: Decodable>(_ path: String, method: String = "GET", body: Encodable? = nil, as: T.Type = T.self) async throws -> T {
        let (data, res) = try await session.data(for: request(path, method: method, body: body))
        try check(res, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func call(_ path: String, method: String, body: Encodable? = nil) async throws {
        let (data, res) = try await session.data(for: request(path, method: method, body: body))
        try check(res, data)
    }

    // MARK: endpoints

    func state() async throws -> AppState { try await send("/v1/state") }

    func messages(before: Int? = nil) async throws -> [ChatMessage] {
        struct R: Decodable { let messages: [ChatMessage] }
        let q = before.map { "?before=\($0)" } ?? ""
        return try await send("/v1/messages\(q)", as: R.self).messages
    }

    func today(refresh: Bool = false) async throws -> TodayBrief {
        try await send("/v1/today\(refresh ? "?refresh=1" : "")")
    }

    func insights() async throws -> Insights { try await send("/v1/insights", method: "POST") }

    func updateProfile(_ fields: [String: String?]) async throws {
        try await call("/v1/profile", method: "PUT", body: fields)
    }

    func addMemory(_ text: String, origin: String) async throws -> Memory {
        try await send("/v1/memories", method: "POST", body: ["text": text, "origin": origin])
    }

    func pushSource(_ id: String, snapshot: Encodable) async throws {
        struct Body: Encodable { let snapshot: AnyEncodable }
        try await call("/v1/sources/\(id)", method: "PUT", body: Body(snapshot: AnyEncodable(snapshot)))
    }

    /// Streams one chat turn as server-sent events.
    func chat(_ text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request("/v1/chat", method: "POST", body: ["text": text])
                    let (bytes, res) = try await session.bytes(for: req)
                    if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        try self.check(res, Data())
                        throw APIError(status: http.statusCode, message: "Chat failed (\(http.statusCode))")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                        if let event = Self.decode(payload) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decode(_ data: Data) -> ChatEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        func sub<T: Decodable>(_ key: String, _: T.Type) -> T? {
            guard let v = obj[key], let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
        switch type {
        case "ack": return .ack(userMessageId: obj["userMessageId"] as? Int ?? 0)
        case "stage": return (obj["state"] as? String).map(ChatEvent.stage)
        case "text": return (obj["delta"] as? String).map(ChatEvent.text)
        case "tool": return (obj["name"] as? String).map(ChatEvent.tool)
        case "memory": return sub("memory", Memory.self).map(ChatEvent.memory)
        case "memory_removed": return (obj["id"] as? String).map(ChatEvent.memoryRemoved)
        case "list": return (obj["listId"] as? String).map(ChatEvent.list)
        case "done": return sub("message", ChatMessage.self).map(ChatEvent.done)
        case "error": return .error(obj["message"] as? String ?? "Something went wrong")
        default: return nil
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

enum Keychain {
    private static let service = "dev.aibo.ios"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
