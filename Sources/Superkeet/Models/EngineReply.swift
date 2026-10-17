import Foundation

struct EngineReply: Decodable, Equatable {
    let status: String
    let state: String?
    let sessionID: String?
    let protocolVersion: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, state, message
        case sessionID = "session_id"
        case protocolVersion = "protocol_version"
    }

    init?(decoding response: String?) {
        guard let data = response?.data(using: .utf8),
              let reply = try? JSONDecoder().decode(EngineReply.self, from: data) else { return nil }
        self = reply
    }

    var isOK: Bool { status == "ok" }

    /// The engine answered but refused the command, so it is alive and must not be restarted.
    var rejection: String? {
        guard status == "error" else { return nil }
        let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "The speech engine refused the request." : reason
    }
}
