import Foundation
import TeamTasksContract

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the e-mails caught by the local Mailpit (`MAILPIT_URL`, API v1).
enum Mailpit {
    struct Summary: Decodable {
        struct Address: Decodable {
            let address: String

            enum CodingKeys: String, CodingKey {
                case address = "Address"
            }
        }

        let id: String
        let to: [Address]

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case to = "To"
        }
    }

    struct Listing: Decodable {
        let messages: [Summary]
    }

    struct Message: Decodable {
        let text: String?
        let html: String?

        enum CodingKeys: String, CodingKey {
            case text = "Text"
            case html = "HTML"
        }
    }

    /// Waits (bounded) for the newest message sent to `email` and returns the 6-digit code it contains.
    static func recoveryCode(for email: String, timeout: Duration = .seconds(20)) async throws -> String {
        guard let base = IntegrationEnvironment.mailpitURL else { throw ContractFailure("MAILPIT_URL is not set") }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let id = try await latestMessageID(to: email, base: base) {
                let message: Message = try await get(base.appendingPathComponent("api/v1/message/\(id)"))
                let body = [message.text, message.html].compactMap { $0 }.joined(separator: "\n")
                if let code = sixDigitCode(in: body) { return code }
                throw ContractFailure("no 6-digit code in the recovery e-mail: \(body)")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ContractFailure("no e-mail for \(email) in Mailpit after \(timeout)")
    }

    private static func latestMessageID(to email: String, base: URL) async throws -> String? {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: "to:\"\(email)\""), URLQueryItem(name: "limit", value: "5")]
        guard let url = components?.url else { throw ContractFailure("invalid Mailpit URL") }
        let listing: Listing = try await get(url)
        // Newest first; the search is a full-text one, so check the recipient exactly.
        return listing.messages.first { $0.to.contains { $0.address.lowercased() == email.lowercased() } }?.id
    }

    static func sixDigitCode(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])[0-9]{6}(?![0-9])") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let codeRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[codeRange])
    }

    private static func get<Value: Decodable>(_ url: URL) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ContractFailure("Mailpit answered \(response) for \(url)")
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
