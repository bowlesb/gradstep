import Foundation
import StoreKit

/// App Store products sold in the app. The credits each grants are set on the
/// server (migration 018); see docs/architecture/PURCHASES.md.
enum StoreProducts {
    static let pro = "com.sciencereader.ios.pro.monthly"
    static let standard = "com.sciencereader.ios.standard.monthly"
    static let pack = "com.sciencereader.ios.credits.400"
    static let all = [pro, standard, pack]
}

/// The server's verdict on one reported transaction.
struct StoreSyncResult: Decodable, Equatable, Sendable {
    let outcome: String
    let credits: Int64?

    /// After these the transaction is finished; anything else is reported again later.
    static let finalOutcomes: Set<String> = ["recorded", "updated", "already_recorded"]
    var isFinal: Bool { Self.finalOutcomes.contains(outcome) }
}

struct StoreSummary: Decodable, Equatable, Sendable {
    let plan: String?
    let expiresAt: Date?
    enum CodingKeys: String, CodingKey { case plan, expiresAt = "expires_at" }
    init(plan: String?, expiresAt: Date?) { self.plan = plan; self.expiresAt = expiresAt }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        // Postgres timestamps may carry microseconds; whole seconds are enough here.
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt).flatMap { value in
            ISO8601DateFormatter().date(from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
    }
    var planName: String? { plan.map { $0 == "pro" ? "Pro" : $0 == "standard" ? "Standard" : $0.capitalized } }
}

protocol StoreSyncTransport: Sendable {
    func syncStoreTransactions(_ signed: [String], accountID: UUID) async throws -> [StoreSyncResult]
}

extension BackendClient: StoreSyncTransport {}

/// One verified StoreKit transaction waiting for the server.
struct PendingStoreTransaction: Sendable {
    let id: UInt64
    let signed: String
    let finish: @Sendable () async -> Void

    init(id: UInt64, signed: String, finish: @escaping @Sendable () async -> Void) { self.id = id; self.signed = signed; self.finish = finish }

    /// Only transactions StoreKit verified on the device are reported; the
    /// server verifies them again.
    init?(_ verification: VerificationResult<Transaction>) {
        guard case .verified(let transaction) = verification else { return nil }
        self.init(id: transaction.id, signed: verification.jwsRepresentation, finish: { await transaction.finish() })
    }
}

enum StoreSync {
    static let batchSize = 25

    /// Reports transactions and finishes each one whose outcome is final, so
    /// nothing is lost while the server is unreachable or the purchase belongs
    /// to another account.
    static func report(_ pending: [PendingStoreTransaction], accountID: UUID, transport: any StoreSyncTransport) async throws -> [StoreSyncResult] {
        var unique: [PendingStoreTransaction] = [], seen = Set<UInt64>()
        for item in pending where seen.insert(item.id).inserted { unique.append(item) }
        var results: [StoreSyncResult] = []
        for start in stride(from: 0, to: unique.count, by: batchSize) {
            let batch = Array(unique[start..<min(start + batchSize, unique.count)])
            let answers = try await transport.syncStoreTransactions(batch.map(\.signed), accountID: accountID)
            guard answers.count == batch.count else { throw BackendError.unavailable }
            for (item, answer) in zip(batch, answers) where answer.isFinal { await item.finish() }
            results += answers
        }
        return results
    }

    /// What the reader is told about a purchase they just made.
    static func message(for result: StoreSyncResult?) -> String {
        switch result?.outcome {
        case "recorded", "updated", "already_recorded":
            if let credits = result?.credits, credits > 0 { return "Added \(credits.formatted()) credits." }
            return "Your purchase is active."
        case "linked_to_another_account":
            return "This purchase belongs to another account. Sign in to that account to use it."
        case "account_closed":
            return "This account can no longer receive purchases."
        default:
            return "Your purchase went through, but we couldn’t add the credits yet. The app will try again automatically."
        }
    }
}
