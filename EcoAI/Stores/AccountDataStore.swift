import Combine
import Foundation

@MainActor
final class AccountDataStore: ObservableObject {
    struct Account {
        let userID: String
        let chats: ChatStore
        let energy: EnergyUsageStore
        let friends: FriendsStore
    }

    @Published private(set) var account: Account?
    private let accessPoint: CloudflareAccessPoint
    private let storageRoot: URL?
    private var requestedUserID: String?
    private var generation = 0
    private var activationTask: Task<Void, Never>?

    init(accessPoint: CloudflareAccessPoint, storageRoot: URL? = nil) {
        self.accessPoint = accessPoint
        self.storageRoot = storageRoot
    }

    func activate(userID: String?, displayName: String = "EcoAI User") {
        guard requestedUserID != userID else { return }
        requestedUserID = userID
        generation += 1
        let currentGeneration = generation
        let previousAccount = account
        previousAccount?.chats.deactivate()
        previousAccount?.energy.deactivate()
        account = nil
        let previousActivation = activationTask
        activationTask = Task { [weak self] in
            await previousActivation?.value
            await previousAccount?.chats.flush()
            await previousAccount?.energy.flush()
            guard let self, self.generation == currentGeneration, let userID else { return }
            self.openAccount(userID: userID, displayName: displayName)
        }
    }

    private func openAccount(userID: String, displayName: String) {
        let directory = AccountStorage.directory(for: userID, root: storageRoot)
        let energy = EnergyUsageStore(repository: EnergyUsageRepository(
            storageURL: directory.appendingPathComponent("energy-usage.json")
        ))
        let chats = ChatStore(
            accessPoint: accessPoint,
            repository: ChatLocalRepository(
                storageURL: directory.appendingPathComponent("chat-history.json"),
                migrateLegacyDefaults: false
            ),
            energyUsageStore: energy,
            seedChats: []
        )
        account = Account(
            userID: userID,
            chats: chats,
            energy: energy,
            friends: FriendsStore(
                accessPoint: accessPoint,
                displayName: displayName,
                weekStart: energy.weekStartKey
            )
        )
    }
}
