import Foundation

nonisolated struct FriendsDashboard: Decodable, Sendable {
    let inviteCode: String
    let friends: [FriendLeaderboardEntry]
    let incomingRequests: [FriendRequest]
}

nonisolated struct FriendLeaderboardEntry: Decodable, Identifiable, Sendable {
    let userID: String
    let displayName: String
    let wattHours: Double
    let tokens: Int

    var id: String { userID }
}

nonisolated struct FriendRequest: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

nonisolated struct FriendEnergyUpdate: Encodable, Sendable {
    let weekStart: String
    let wattHours: Double
    let tokens: Int
}

nonisolated struct FriendInviteCode: Encodable, Sendable {
    let inviteCode: String
}

nonisolated struct FriendRequestAcceptance: Encodable, Sendable {
    let requestID: String
}

nonisolated struct FriendRemoval: Encodable, Sendable {
    let userID: String
}

nonisolated struct FriendProfileUpdate: Encodable, Sendable {
    let displayName: String
    let weekStart: String
}

nonisolated struct FriendsActionResult: Decodable, Sendable {
    let ok: Bool
}
