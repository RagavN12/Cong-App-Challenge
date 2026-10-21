import Foundation
import LocalAuthentication
import Security

private enum Fixture {
    case success, providerError, temporaryProviderError, partialEOF, finishWithoutDone, doneWithoutFinish, empty, hold, timedOut, unauthorized, providerHTTP402
}

private final class HTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [Fixture] = []
    private var startedCount = 0

    func enqueue(_ fixture: Fixture) {
        lock.lock()
        defer { lock.unlock() }
        fixtures.append(fixture)
    }

    func take() -> Fixture {
        lock.lock()
        defer { lock.unlock() }
        startedCount += 1
        return fixtures.isEmpty ? .success : fixtures.removeFirst()
    }

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }
}

private final class MockHTTP: URLProtocol, @unchecked Sendable {
    static let state = HTTPState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.state.take()
        if case .timedOut = fixture {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let id = json?["request_id"] as? String ?? "missing-request-id"
        let delta = "data: {\"request_id\":\"\(id)\",\"delta\":\"Hello\",\"finish_reason\":null}\n\n"
        let finish = "data: {\"request_id\":\"\(id)\",\"delta\":\"\",\"finish_reason\":\"stop\"}\n\n"
        let usage = "data: {\"request_id\":\"\(id)\",\"delta\":\"\",\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15},\"energy_wh\":{\"input\":0.004,\"output\":0.002,\"total\":0.006}}\n\n"
        let done = "data: [DONE]\n\n"
        let text: String
        switch fixture {
        case .success: text = delta + finish + usage + done
        case .providerError: text = delta + "data: {\"request_id\":\"\(id)\",\"delta\":\"\",\"finish_reason\":\"error\",\"error\":\"Quota exceeded\"}\n\n"
        case .temporaryProviderError: text = "data: {\"request_id\":\"\(id)\",\"delta\":\"\",\"finish_reason\":\"error\",\"error\":\"Provider temporarily unavailable\",\"retryable\":true}\n\n"
        case .partialEOF: text = delta
        case .finishWithoutDone: text = delta + finish
        case .doneWithoutFinish: text = delta + done
        case .empty: text = finish + done
        case .hold: text = ""
        case .timedOut, .unauthorized: text = ""
        case .providerHTTP402: text = "{\"error\":\"OpenRouter request failed\",\"upstream_status\":402,\"detail\":\"This model requires credits\"}"
        }
        let status: Int
        if case .unauthorized = fixture { status = 401 }
        else if case .providerHTTP402 = fixture { status = 502 }
        else { status = 200 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!, cacheStoragePolicy: .notAllowed)
        if !text.isEmpty { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
        if case .hold = fixture { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SilentAuthenticationContext: LAContext {
    private var silent = false
    override var interactionNotAllowed: Bool {
        get { silent }
        set { silent = newValue }
    }
}

@main
private struct RegressionTests {
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    @MainActor static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CheckFailure(description: message)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecoai-regressions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let access = CloudflareAccessPoint(
            configuration: CloudflareConfiguration(workerBaseURL: URL(string: "https://test.invalid")!, streamTimeout: .seconds(5)),
            tokenProvider: PreviewAccessTokenProvider(), session: session
        )
        let wireRequest = LLMStreamRequest(requestID: UUID(), threadID: UUID(), messages: [])
        let wireData = try await access.encodedRequest(wireRequest)
        let wireObject = try JSONSerialization.jsonObject(with: wireData) as! [String: Any]
        try check(wireObject["model"] == nil, "Client still sends a selectable model")

        // Per-account isolation, persistence, no legacy adoption, and path safety.
        let legacy = root.appendingPathComponent("chat-history.json")
        let legacyData = Data("unowned legacy data".utf8)
        try legacyData.write(to: legacy)
        let accounts = AccountDataStore(accessPoint: access, storageRoot: root)
        accounts.activate(userID: "auth0|A")
        try await eventually("A did not open") { accounts.account?.userID == "auth0|A" }
        let a = accounts.account!
        await a.energy.load()
        await a.chats.load()
        let id = a.chats.sendMessage("A's private question", selectedChatID: nil)!
        try await eventually("A response did not finish") { !a.chats.isResponding(in: id) }
        a.energy.setLimit(wattHours: 0.5)
        try check(a.energy.snapshot.responseCount == 1, "Usage trailer was not counted: \(a.chats.chats.last?.messages.last?.content ?? "no response")")
        let aURL = AccountStorage.directory(for: "auth0|A", root: root).appendingPathComponent("chat-history.json")
        let energyAURL = AccountStorage.directory(for: "auth0|A", root: root).appendingPathComponent("energy-usage.json")
        try await eventually("A's files were not saved") {
            FileManager.default.fileExists(atPath: aURL.path) && FileManager.default.fileExists(atPath: energyAURL.path)
        }
        accounts.activate(userID: "auth0|B")
        try await eventually("B did not open") { accounts.account?.userID == "auth0|B" }
        let b = accounts.account!
        await b.energy.load()
        await b.chats.load()
        try check(b.energy.budget.dailyWattHours == 5, "B inherited A's energy limit")
        try check(b.chats.chats.isEmpty && b.energy.snapshot.responseCount == 0, "B inherited A's data")
        try check(a.chats.sendMessage("stale A send", selectedChatID: id) == nil, "Inactive store accepted a send")
        accounts.activate(userID: "auth0|A")
        try await eventually("A did not reopen") { accounts.account?.userID == "auth0|A" }
        let restored = accounts.account!
        await restored.energy.load()
        await restored.chats.load()
        try check(restored.chats.chat(withID: id)?.messages.last?.content == "Hello", "A's history did not restore")
        try check(restored.energy.budget.dailyWattHours == 0.5, "A's energy limit did not restore")
        try check(restored.energy.snapshot.responseCount == 1, "A's usage did not restore")
        try check(try Data(contentsOf: legacy) == legacyData, "Legacy shared file was modified")
        try check(AccountStorage.directory(for: "../A", root: root) != AccountStorage.directory(for: "A", root: root), "Account paths collide")
        let defaults = UserDefaults(suiteName: "ecoai-regressions-\(UUID())")!
        let defaultsKey = "ecoai.chat-history.v1"
        defaults.set(Data("[]".utf8), forKey: defaultsKey)
        let scopedRepo = ChatLocalRepository(
            storageURL: root.appendingPathComponent("scoped-no-migration.json"),
            legacyDefaults: defaults, migrateLegacyDefaults: false
        )
        let scopedHistory = try await scopedRepo.load()
        try check(scopedHistory == nil && defaults.data(forKey: defaultsKey) != nil, "Account adopted unowned UserDefaults history")
        defaults.removeObject(forKey: defaultsKey)
        print("PASS account history/usage isolation, restoration, and legacy preservation")

        // History loading gates mutations and a failed decode never permits saving.
        let historyURL = root.appendingPathComponent("corrupt-history.json")
        let corrupt = Data("corrupt but recoverable history".utf8)
        try corrupt.write(to: historyURL)
        let historyRepo = ChatLocalRepository(storageURL: historyURL, migrateLegacyDefaults: false)
        let testEnergy = EnergyUsageStore(repository: EnergyUsageRepository(storageURL: root.appendingPathComponent("test-usage.json")))
        await testEnergy.load()
        let store = ChatStore(accessPoint: access, repository: historyRepo, energyUsageStore: testEnergy, seedChats: [])
        try check(store.sendMessage("too early", selectedChatID: nil) == nil, "Send allowed before history loaded")
        let loading = Task { await store.load() }
        try check(store.sendMessage("during load", selectedChatID: nil) == nil, "Send allowed during load")
        await loading.value
        try check(store.loadState == .failed, "History failure was not exposed")
        try check(store.sendMessage("after failure", selectedChatID: nil) == nil, "Failed history accepted a send")
        try check(try Data(contentsOf: historyURL) == corrupt, "Failed history was overwritten")
        try await historyRepo.save([]) // Simulate external recovery, then use Retry.
        await store.load()
        try check(store.canSendMessages, "Retry did not recover history")
        print("PASS startup gating, corrupt-history preservation, and retry")

        let usageURL = root.appendingPathComponent("corrupt-usage.json")
        try corrupt.write(to: usageURL)
        let energy = EnergyUsageStore(repository: EnergyUsageRepository(storageURL: usageURL))
        await energy.load()
        energy.recordResponse(usage: LLMUsagePayload(promptTokens: 1, completionTokens: 1, totalTokens: 2), energy: nil)
        energy.resetToday()
        try check(energy.loadState == .failed, "Usage failure was not exposed")
        try check(try Data(contentsOf: usageURL) == corrupt, "Failed usage was overwritten")
        try FileManager.default.removeItem(at: usageURL)
        await energy.load()
        try check(energy.isReady, "Retry did not recover usage")
        print("PASS corrupt-usage preservation and retry")

        // Cancel an already-started HTTP stream, immediately replace it, and
        // allow the old task to finish cleanup while the replacement is live.
        MockHTTP.state.enqueue(.hold)
        let first = store.sendMessage("first", selectedChatID: nil)!
        let started = MockHTTP.state.started
        try await eventually("First stream never started") { MockHTTP.state.started > started }
        store.cancelResponse(in: first)
        try check(!store.chat(withID: first)!.messages.contains { $0.role == .assistant && $0.content.isEmpty }, "Cancelled placeholder remains")
        MockHTTP.state.enqueue(.hold)
        let beforeReplacement = MockHTTP.state.started
        try check(store.sendMessage("replacement", selectedChatID: first) != nil, "Replacement send rejected")
        try await eventually("Replacement never started") { MockHTTP.state.started > beforeReplacement }
        try await Task.sleep(for: .milliseconds(40))
        try check(store.isResponding(in: first), "Old cleanup cleared replacement state")
        store.cancelResponse(in: first)
        try check(!store.isResponding(in: first), "Replacement could not be cancelled")
        try check(!store.chat(withID: first)!.messages.contains { $0.role == .assistant && $0.content.isEmpty }, "Replacement placeholder remains")
        print("PASS cancellation ownership and empty-placeholder cleanup")

        MockHTTP.state.enqueue(.hold)
        let activeID = restored.chats.sendMessage("cancel at session end", selectedChatID: nil)!
        let beforeSessionEnd = MockHTTP.state.started
        try await eventually("Session stream never started") { MockHTTP.state.started > beforeSessionEnd }
        accounts.activate(userID: nil)
        try check(accounts.account == nil && !restored.chats.isResponding(in: activeID), "Session end did not cancel active responses")
        print("PASS session teardown cancels active streams")
        accounts.activate(userID: "auth0|A")
        accounts.activate(userID: "auth0|B")
        accounts.activate(userID: "auth0|A")
        try await eventually("Rapid switches opened the wrong account") { accounts.account?.userID == "auth0|A" }
        let rapid = accounts.account!
        await rapid.energy.load()
        await rapid.chats.load()
        try check(rapid.chats.chat(withID: id) != nil, "Rapid switches lost A's history")
        accounts.activate(userID: nil)
        print("PASS rapid account-switch ordering")

        // The real transport must reject provider errors, empty responses, and
        // truncation. It must still read usage after a valid finish_reason.
        for fixture in [Fixture.success, .providerError, .partialEOF, .finishWithoutDone, .doneWithoutFinish, .empty] {
            MockHTTP.state.enqueue(fixture)
            let request = LLMStreamRequest(requestID: UUID(), threadID: UUID(), messages: [])
            var content = ""
            var sawUsage = false
            var failure: Error?
            do {
                for try await event in await access.streamAIResponse(request: request) {
                    content += event.delta
                    sawUsage = sawUsage || event.usage != nil
                }
            } catch { failure = error }
            if case .success = fixture {
                try check(failure == nil && content == "Hello" && sawUsage, "Valid stream/usage trailer was rejected")
            } else {
                try check(failure != nil, "Incomplete/error stream was accepted: \(fixture)")
                if case .providerError = fixture {
                    try check(failure!.localizedDescription.contains("Quota exceeded"), "Provider explanation was lost")
                }
            }
        }
        print("PASS transport completion, error, empty-response, and usage-trailer checks")

        // An error must also become visible on the response through ChatStore.
        MockHTTP.state.enqueue(.providerError)
        let failedID = store.sendMessage("provider failure", selectedChatID: nil)!
        try await eventually("Failed response did not finalize") { !store.isResponding(in: failedID) }
        try check(store.chat(withID: failedID)!.messages.last!.content.contains("Quota exceeded"), "Response failure was not visible")
        print("PASS provider failure reaches the affected chat response")
        let immediateRetries = ResponseRetryPolicy(maximumAttempts: 10, initialDelay: .zero, maximumDelay: .zero)
        func retryStore(policy: ResponseRetryPolicy = immediateRetries) -> ChatStore {
            ChatStore(accessPoint: access,
                      repository: ChatLocalRepository(storageURL: root.appendingPathComponent("retry-\(UUID()).json"), migrateLegacyDefaults: false),
                      energyUsageStore: testEnergy, seedChats: [], retryPolicy: policy)
        }
        for failure in [Fixture.partialEOF, .timedOut, .temporaryProviderError] {
            let retrying = retryStore()
            await retrying.load()
            MockHTTP.state.enqueue(failure)
            MockHTTP.state.enqueue(.success)
            let before = MockHTTP.state.started
            let retryID = retrying.sendMessage("retry once", selectedChatID: nil)!
            try await eventually("Retry did not finish") { !retrying.isResponding(in: retryID) }
            try check(MockHTTP.state.started == before + 2, "Transient failure was not retried once")
            let messages = retrying.chat(withID: retryID)!.messages
            try check(messages.count == 2 && messages.last!.content == "Hello", "Retry duplicated partial text or messages")
            try check(retrying.lastError == nil && retrying.responseStatuses.isEmpty, "Recovered retry left a stale error/status")
            await retrying.flush()
        }
        print("PASS interrupted response, timeout, and temporary-provider retries without duplicates")

        let exhausted = retryStore()
        await exhausted.load()
        for _ in 0..<10 { MockHTTP.state.enqueue(.partialEOF) }
        let beforeExhaustion = MockHTTP.state.started
        let exhaustedID = exhausted.sendMessage("exhaust retries", selectedChatID: nil)!
        try await eventually("Retry limit did not finish") { !exhausted.isResponding(in: exhaustedID) }
        try check(MockHTTP.state.started == beforeExhaustion + 10, "Retries did not stop at ten attempts")
        try check(exhausted.lastError != nil, "Exhausted retries did not expose failure")
        exhausted.dismissError()
        try check(exhausted.lastError == nil, "Notification dismissal did not clear the error")
        await exhausted.flush()
        print("PASS ten-attempt limit and dismissible errors")

        let permanent = retryStore()
        await permanent.load()
        MockHTTP.state.enqueue(.unauthorized)
        let beforePermanent = MockHTTP.state.started
        let permanentID = permanent.sendMessage("auth failure", selectedChatID: nil)!
        try await eventually("Permanent error did not finish") { !permanent.isResponding(in: permanentID) }
        try check(MockHTTP.state.started == beforePermanent + 1, "Authentication error was retried")
        await permanent.flush()
        MockHTTP.state.enqueue(.providerHTTP402)
        let beforeCredits = MockHTTP.state.started
        let creditsID = permanent.sendMessage("provider requires credits", selectedChatID: nil)!
        try await eventually("Credits failure did not finish") { !permanent.isResponding(in: creditsID) }
        try check(MockHTTP.state.started == beforeCredits + 1, "Permanent provider status inside a 502 was retried")
        try check(permanent.lastError?.contains("requires credits") == true, "Provider HTTP explanation was lost")
        await permanent.flush()
        print("PASS permanent failures are not retried")

        let delayed = retryStore(policy: ResponseRetryPolicy(maximumAttempts: 10, initialDelay: .seconds(10), maximumDelay: .seconds(10)))
        await delayed.load()
        MockHTTP.state.enqueue(.partialEOF)
        let beforeDelay = MockHTTP.state.started
        let delayedID = delayed.sendMessage("cancel retry delay", selectedChatID: nil)!
        try await eventually("Retry never entered backoff") { delayed.responseStatuses[delayedID] != nil }
        delayed.cancelResponse(in: delayedID)
        try await Task.sleep(for: .milliseconds(40))
        try check(MockHTTP.state.started == beforeDelay + 1 && !delayed.isResponding(in: delayedID), "Cancel did not stop retry backoff")
        try check(delayed.chat(withID: delayedID)!.messages.count == 1, "Cancelled retry retained a placeholder")
        await delayed.flush()
        print("PASS cancellation stops retry backoff immediately")

        // Energy limits retain per-day usage so changing period never resets it.
        let iso = ISO8601DateFormatter()
        var clock = iso.date(from: "2026-10-21T16:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let budgetURL = root.appendingPathComponent("energy-budget.json")
        let budgetRepo = EnergyUsageRepository(storageURL: budgetURL)
        let budgetStore = EnergyUsageStore(repository: budgetRepo, calendar: calendar, now: { clock })
        await budgetStore.load()
        budgetStore.setLimit(wattHours: 0.5)
        let tokens = LLMUsagePayload(promptTokens: 100, completionTokens: 200, totalTokens: 300)
        func record(_ amount: Double) {
            budgetStore.recordResponse(usage: tokens, energy: LLMEnergyPayload(input: amount / 2, output: amount / 2, total: amount))
        }
        record(0.3)
        try check(abs(budgetStore.usedFraction - 0.6) < 0.000001, "Gauge did not reflect actual usage / limit")
        record(0.25)
        try check(budgetStore.isLimitReached && budgetStore.progress == 1 && budgetStore.usedFraction > 1,
                  "Overshoot was hidden or gauge was not clamped")
        let noticeID = budgetStore.limitNotice?.id
        try check(noticeID != nil, "Reaching the limit did not create a summary notice")
        let firstWindow = UUID()
        let otherWindow = UUID()
        try check(budgetStore.claimLimitNotice(owner: firstWindow), "Limit summary could not be presented")
        try check(!budgetStore.claimLimitNotice(owner: otherWindow), "Two windows claimed the same summary")
        budgetStore.refreshPeriod()
        try check(budgetStore.limitNotice?.id == noticeID, "Repeated refresh generated another modal")
        budgetStore.dismissLimitNotice(owner: otherWindow)
        try check(budgetStore.limitNotice != nil, "Another window dismissed a summary it did not own")
        budgetStore.dismissLimitNotice(owner: firstWindow)
        budgetStore.refreshPeriod()
        try check(budgetStore.limitNotice == nil, "Acknowledged summary reappeared in the same period")
        await budgetStore.flush()
        let acknowledged = EnergyUsageStore(repository: budgetRepo, calendar: calendar, now: { clock })
        await acknowledged.load()
        try check(acknowledged.isLimitReached && acknowledged.limitNotice == nil,
                  "Restart forgot acknowledgement or unblocked sending")
        acknowledged.deactivate()
        let limitedChat = ChatStore(accessPoint: access,
                                    repository: ChatLocalRepository(storageURL: root.appendingPathComponent("limited-chat.json"), migrateLegacyDefaults: false),
                                    energyUsageStore: budgetStore, seedChats: [])
        await limitedChat.load()
        let beforeBudgetBlock = MockHTTP.state.started
        try check(!limitedChat.canSendMessages && limitedChat.sendMessage("blocked by limit", selectedChatID: nil) == nil,
                  "An exhausted limit allowed a new message")
        try check(MockHTTP.state.started == beforeBudgetBlock, "Blocked send started an HTTP request")
        budgetStore.setLimit(wattHours: 1)
        try check(limitedChat.canSendMessages, "Increasing the limit did not unblock sending")
        budgetStore.setLimit(wattHours: 0)
        budgetStore.setLimit(wattHours: .nan)
        try check(budgetStore.budget.limitWattHours == 1, "Invalid energy limit was accepted")
        clock = iso.date(from: "2026-10-22T04:00:00Z")!
        budgetStore.refreshPeriod()
        try check(budgetStore.snapshot.responseCount == 0, "Daily totals did not reset at local midnight")
        try check(budgetStore.limitNotice == nil, "A stale summary survived a period reset")
        budgetStore.setPeriod(.weekly)
        try check(abs(budgetStore.usedWattHours - 0.55) < 0.000001 && budgetStore.snapshot.responseCount == 2,
                  "Weekly view discarded earlier days")
        budgetStore.setLimit(wattHours: 0.5)
        try check(!limitedChat.canSendMessages, "Weekly limit was not enforced")
        try check(budgetStore.limitNotice != nil, "A newly reached weekly limit did not create a summary")
        budgetStore.setPeriod(.daily)
        try check(budgetStore.budget.limitWattHours == 1 && budgetStore.usedWattHours == 0,
                  "Switching periods changed saved limits or daily totals")
        budgetStore.setPeriod(.weekly)
        clock = iso.date(from: "2026-10-25T16:00:00Z")!
        record(0.2)
        try check(abs(budgetStore.usedWattHours - 0.75) < 0.000001, "Weekly aggregation is incorrect")
        try check(budgetStore.nextReset == iso.date(from: "2026-10-26T04:00:00Z")!, "Weekly reset is not Monday local midnight")
        await budgetStore.flush()
        let reloadedBudget = EnergyUsageStore(repository: budgetRepo, calendar: calendar, now: { clock })
        await reloadedBudget.load()
        try check(reloadedBudget.budget == budgetStore.budget && abs(reloadedBudget.usedWattHours - 0.75) < 0.000001,
                  "Energy settings or ledger did not survive reload")
        clock = iso.date(from: "2026-10-26T04:00:00Z")!
        budgetStore.refreshPeriod()
        try check(budgetStore.usedWattHours == 0 && limitedChat.canSendMessages, "Monday reset did not resume sending")
        try check(budgetStore.nextReset == iso.date(from: "2026-11-02T05:00:00Z")!, "Weekly reset mishandles DST")
        budgetStore.setPeriod(.daily)
        clock = iso.date(from: "2026-11-01T04:00:00Z")!
        budgetStore.refreshPeriod()
        try check(budgetStore.nextReset.timeIntervalSince(clock) == 25 * 60 * 60, "Daily reset assumes a fixed 24-hour day")
        budgetStore.deactivate()
        reloadedBudget.deactivate()
        print("PASS budget percentage, daily/weekly aggregation, blocking, persistence, local resets, and DST")

        let migrationURL = root.appendingPathComponent("legacy-daily-usage.json")
        let legacySnapshot = EnergyUsageSnapshot.zero.adding(usage: tokens, energy: LLMEnergyPayload(input: 0.1, output: 0.15, total: 0.25))
        let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacySnapshot))
        let oldUsageData = try JSONSerialization.data(withJSONObject: ["dayKey": "2026-10-21", "snapshot": snapshotJSON])
        try oldUsageData.write(to: migrationURL)
        clock = iso.date(from: "2026-10-21T16:00:00Z")!
        let migrated = EnergyUsageStore(repository: EnergyUsageRepository(storageURL: migrationURL), calendar: calendar, now: { clock })
        await migrated.load()
        try check(abs(migrated.usedWattHours - 0.25) < 0.000001, "Legacy daily snapshot was lost during upgrade")
        migrated.setPeriod(.weekly)
        try check(abs(migrated.usedWattHours - 0.25) < 0.000001, "Legacy usage did not appear in the weekly budget")
        await migrated.flush()
        let upgradedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationURL)) as! [String: Any]
        try check(upgradedJSON["days"] != nil && upgradedJSON["budget"] != nil, "Upgraded ledger was not persisted")
        migrated.deactivate()
        print("PASS existing daily usage migrates without losing consumption")
        try check(abs(EnergyLimitContext(wattHours: 5).lightBulbSeconds - 1800) < 0.000001,
                  "Period-total analogy conversion is incorrect")
        try check(abs(EnergyLimitContext(wattHours: 35).lightBulbSeconds - 12600) < 0.000001,
                  "Weekly-total analogy conversion is incorrect")
        try check(EnergyLimitContext(wattHours: 0.0008).duration == "less than 1 second",
                  "Small-energy analogy overstates the duration")
        print("PASS limit-modal lifecycle, one-window ownership, persisted acknowledgement, and total-energy analogies")

        // No real Keychain access: inspect queries and simulate Security statuses.
        var queries: [[String: Any]] = []
        var reads = 0
        let data = Data("test credentials".utf8)
        let operations = CredentialVault.Operations(
            read: { query in queries.append(query); reads += 1; return (errSecSuccess, data) },
            update: { query, _ in queries.append(query); return errSecItemNotFound },
            add: { query in queries.append(query); return errSecSuccess },
            delete: { query in queries.append(query); return errSecSuccess },
            makeContext: { SilentAuthenticationContext() }
        )
        let vault = CredentialVault(service: "test.session.v2", persistent: true, operations: operations)
        _ = try vault.getEntry(forKey: "credentials")
        _ = try vault.getEntry(forKey: "credentials")
        try check(reads == 1, "Vault reread the Keychain despite having a cached value")
        try vault.setEntry(data, forKey: "credentials")
        try vault.deleteEntry(forKey: "credentials")
        try vault.deleteAllEntries()
        for query in queries {
            try check(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "Query targeted the legacy Keychain")
            try check((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true, "Query allowed a password dialog")
            try check(query[kSecAttrService as String] as? String == "test.session.v2", "Credential operation was not scoped to its service")
        }
        let queriesBeforeMemory = queries.count
        let memory = CredentialVault(persistent: false, operations: operations)
        try memory.setEntry(data, forKey: "credentials")
        try check(try memory.getEntry(forKey: "credentials") == data, "Development session memory storage failed")
        try memory.deleteAllEntries()
        try check(queries.count == queriesBeforeMemory, "Unsigned development storage accessed the Keychain")
        let denied = CredentialVault(persistent: true, operations: CredentialVault.Operations(
            read: { _ in (errSecInteractionNotAllowed, nil) }, update: operations.update,
            add: operations.add, delete: operations.delete, makeContext: { SilentAuthenticationContext() }
        ))
        do {
            _ = try denied.getEntry(forKey: "credentials")
            throw CheckFailure(description: "Locked Keychain was treated as success")
        } catch is CredentialVaultError { }
        print("PASS protected/noninteractive Keychain queries, caching, and memory-only development sessions")

        store.cancelAllResponses()
        await store.flush()
        await testEnergy.flush()
        await rapid.chats.flush()
        await rapid.energy.flush()
        print("All Swift regression checks passed.")
    }
}
