import Foundation

struct LegacyConversationRecoverySnapshot: Codable {
    static let fileName = "conversation-recovery.json"

    var conversations: [Conversation]
    var exportedAt: Date
    var source: String
}
