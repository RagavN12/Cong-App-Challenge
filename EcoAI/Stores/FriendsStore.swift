import Combine
import Foundation

@MainActor
final class FriendsStore: ObservableObject {
    @Published private(set) var dashboard: FriendsDashboard?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage: String?

    private let accessPoint: CloudflareAccessPoint
    private let displayName: String
    private var weekStart: String
    private var lastPublishedWeek: String?
    private var lastPublishedWattHours: Double?
    private var lastPublishedTokens: Int?
    private var isPublishingEnergy = false
    private var pendingEnergyUpdate: FriendEnergyUpdate?

    init(accessPoint: CloudflareAccessPoint, displayName: String, weekStart: String) {
        self.accessPoint = accessPoint
        self.displayName = displayName
        self.weekStart = weekStart
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            dashboard = try await accessPoint.loadFriends(displayName: displayName, weekStart: weekStart)
        } catch {
            lastError = "Friends could not be loaded. Check your connection and try again."
        }
    }

    func sendRequest(inviteCode: String) async {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            lastError = "Enter a friend invite code."
            return
        }
        await perform(successMessage: "Friend request sent.") {
            try await accessPoint.sendFriendRequest(inviteCode: code)
            dashboard = try await accessPoint.loadFriends(displayName: displayName, weekStart: weekStart)
        }
    }

    func accept(_ request: FriendRequest) async {
        await perform(successMessage: "Friend added.") {
            try await accessPoint.acceptFriendRequest(requestID: request.id)
            dashboard = try await accessPoint.loadFriends(displayName: displayName, weekStart: weekStart)
        }
    }

    func remove(_ friend: FriendLeaderboardEntry) async {
        await perform(successMessage: "Friend removed.") {
            try await accessPoint.removeFriend(userID: friend.userID)
            dashboard = try await accessPoint.loadFriends(displayName: displayName, weekStart: weekStart)
        }
    }

    func publishEnergy(weekStart: String, wattHours: Double, tokens: Double) async {
        self.weekStart = weekStart
        guard wattHours.isFinite, (0...1_000_000).contains(wattHours),
              tokens.isFinite, (0...1_000_000_000).contains(tokens) else {
            lastError = "Your energy total is outside the range that can be shared."
            return
        }
        pendingEnergyUpdate = FriendEnergyUpdate(
            weekStart: weekStart,
            wattHours: wattHours,
            tokens: Int(tokens.rounded())
        )
        guard !isPublishingEnergy else { return }

        isPublishingEnergy = true
        defer { isPublishingEnergy = false }
        while let update = pendingEnergyUpdate {
            pendingEnergyUpdate = nil
            if lastPublishedWeek == update.weekStart,
               lastPublishedWattHours == update.wattHours,
               lastPublishedTokens == update.tokens {
                continue
            }
            do {
                try await accessPoint.publishFriendEnergy(update)
                lastPublishedWeek = update.weekStart
                lastPublishedWattHours = update.wattHours
                lastPublishedTokens = update.tokens
            } catch {
                lastError = "Your energy total could not be shared with friends. It will retry when your usage changes."
                break
            }
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func perform(successMessage: String, _ action: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        statusMessage = nil
        defer { isWorking = false }
        do {
            try await action()
            statusMessage = successMessage
        } catch {
            lastError = "That friends action could not be completed. Check your connection and try again."
        }
    }
}
