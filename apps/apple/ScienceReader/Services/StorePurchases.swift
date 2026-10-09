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
    let grantReason: String?
    let supportReference: String?
    let diagnostic: StoreVerificationDiagnostic?

    private static let knownOutcomes: Set<String> = ["recorded", "updated", "already_recorded", "linked_to_another_account", "account_closed",
        "unknown_product", "unsupported", "unattributed", "invalid", "environment_unavailable", "verification_unavailable"]
    enum CodingKeys: String, CodingKey { case outcome, credits, grantReason = "grant_reason", supportReference = "support_reference", diagnostic }
    init(outcome: String, credits: Int64?, grantReason: String? = nil, supportReference: String? = nil, diagnostic: StoreVerificationDiagnostic? = nil) {
        self.outcome = Self.knownOutcomes.contains(outcome) ? outcome : "unknown"
        self.credits = credits
        self.grantReason = ["sandbox_monthly_cap", "sandbox_identity_missing", "subscription_not_eligible", "no_credit_grant"].contains(grantReason) ? grantReason : nil
        self.supportReference = supportReference.flatMap { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? $0 : nil }
        self.diagnostic = diagnostic
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(outcome: try c.decode(String.self, forKey: .outcome), credits: try c.decodeIfPresent(Int64.self, forKey: .credits),
                  grantReason: try c.decodeIfPresent(String.self, forKey: .grantReason),
                  supportReference: try c.decodeIfPresent(String.self, forKey: .supportReference),
                  diagnostic: try c.decodeIfPresent(StoreVerificationDiagnostic.self, forKey: .diagnostic))
    }

    /// After these the transaction is finished; anything else is reported again later.
    static let finalOutcomes: Set<String> = ["recorded", "updated", "already_recorded"]
    var isFinal: Bool { Self.finalOutcomes.contains(outcome) }

    /// Only fixed codes and an opaque account-bound reference enter support reports.
    var supportLine: String {
        ([outcome] + (grantReason.map { [$0] } ?? []) + (diagnostic?.codes ?? []) + (supportReference.map { ["reference " + $0] } ?? [])).joined(separator: " · ")
    }
}

struct StoreVerificationDiagnostic: Decodable, Equatable, Sendable {
    let codes: [String]
    enum CodingKeys: String, CodingKey { case stage, appleStatus = "apple_status", transportCode = "transport_code" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fields: [(CodingKeys, Set<String>)] = [
            (.stage, ["input", "environment", "certificate_chain", "revocation", "signature_or_payload", "application", "transaction_fields", "recording", "admission", "deferred"]),
            (.appleStatus, ["verification_failure", "retryable_verification_failure", "invalid_app_identifier", "invalid_environment", "invalid_chain_length", "invalid_certificate", "failure"]),
            (.transportCode, ["timeout", "dns", "connection", "tls", "network", "runtime", "other"]),
        ]
        codes = try fields.compactMap { key, allowed in
            guard let value = try c.decodeIfPresent(String.self, forKey: key), allowed.contains(value) else { return nil }
            return value
        }
    }
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
        let reference = result?.supportReference.map { " Support code: \($0.prefix(16))." } ?? ""
        switch result?.outcome {
        case "recorded", "updated", "already_recorded":
            if let credits = result?.credits, credits > 0 { return "Added \(credits.formatted()) credits." }
            if result?.grantReason == "sandbox_monthly_cap" {
                return "Purchase recorded, but the TestFlight Sandbox monthly credit limit has been reached. No credits were added."
            }
            if result?.grantReason == "sandbox_identity_missing" {
                return "Purchase recorded, but Apple’s Sandbox identity was unavailable. No credits were added; try Restore Purchases."
            }
            if result?.grantReason == "subscription_not_eligible" {
                return "Purchase recorded, but this subscription period did not add credits."
            }
            if result?.credits == 0 { return "Purchase recorded. No new credits were added." }
            return result?.outcome == "already_recorded" ? "This purchase was already recorded." : "Purchase recorded."
        case "linked_to_another_account":
            return "This purchase belongs to another account. Sign in to that account to use it."
        case "account_closed":
            return "This account can no longer receive purchases."
        case "verification_unavailable", nil:
            return "Purchase received. Credits are pending; the app will try again automatically." + reference
        case "invalid", "environment_unavailable":
            return "We couldn’t verify this purchase yet. Try Restore purchases or send a report so we can investigate." + reference
        case "unsupported", "unknown_product":
            return "This purchase isn’t supported by this app, so no credits were added. Send a report so we can investigate." + reference
        default:
            return "We couldn’t link this purchase to your account. Send a report so we can investigate." + reference
        }
    }
}
