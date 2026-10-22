import Combine
import Foundation

@MainActor
final class EnergyUsageStore: ObservableObject {
    @Published private(set) var snapshot: EnergyUsageSnapshot = .zero
    @Published private(set) var budget = EnergyBudget()
    @Published private(set) var nextReset: Date
    @Published private(set) var lastError: String?
    @Published private(set) var loadState: StorageLoadState = .notLoaded
    @Published private(set) var limitNotice: EnergyLimitNotice?
    private var noticeOwner: UUID?
    private var acknowledgedLimitPeriod: String?

    private let repository: EnergyUsageRepository
    private let now: () -> Date
    private var calendar: Calendar
    private var days: [String: EnergyUsageSnapshot] = [:]
    private var isActive = true
    private var persistenceTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?

    var isReady: Bool { isActive && loadState == .loaded }
    var usedWattHours: Double { max(snapshot.electricityWattHours.total, 0) }
    var usedFraction: Double { usedWattHours / budget.limitWattHours }
    var progress: Double { min(max(usedFraction, 0), 1) }
    var remainingWattHours: Double { max(budget.limitWattHours - usedWattHours, 0) }
    var isLimitReached: Bool { usedWattHours >= budget.limitWattHours }
    var weeklySnapshot: EnergyUsageSnapshot {
        let date = now()
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        let first = dayKey(for: interval.start)
        let today = dayKey(for: date)
        let selected = days.keys.filter { $0 >= first && $0 <= today }.sorted()
        return .combining(selected.compactMap { days[$0] })
    }
    var weekStartKey: String {
        dayKey(for: calendar.dateInterval(of: .weekOfYear, for: now())!.start)
    }

    init(
        repository: EnergyUsageRepository,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
        self.nextReset = calendar.dateInterval(of: .day, for: now())!.end
    }

    deinit { rolloverTask?.cancel() }

    func load() async {
        guard isActive, loadState != .loaded, loadState != .loading else { return }
        loadState = .loading
        lastError = nil
        do {
            let persisted = try await repository.load()
            guard isActive else { return }
            if let persisted {
                budget = persisted.budget
                days = persisted.days
                acknowledgedLimitPeriod = persisted.acknowledgedLimitPeriod
            }
            loadState = .loaded
            refreshPeriod()
            scheduleRollover()
        } catch {
            loadState = .failed
            lastError = "Energy usage could not be loaded. Your saved file has been preserved. Retry to continue."
        }
    }

    func recordResponse(usage: LLMUsagePayload, energy: LLMEnergyPayload?) {
        guard isReady else { return }
        let key = dayKey(for: now())
        days[key] = (days[key] ?? .zero).adding(usage: usage, energy: energy)
        refreshPeriod()
        persistSoon()
    }

    func setPeriod(_ period: EnergyBudgetPeriod) {
        guard isReady else { return }
        budget.period = period
        refreshPeriod()
        persistSoon()
    }

    func setLimit(wattHours: Double) {
        guard isReady, EnergyBudget.isValidLimit(wattHours) else { return }
        if budget.period == .daily { budget.dailyWattHours = wattHours }
        else { budget.weeklyWattHours = wattHours }
        refreshPeriod()
        persistSoon()
    }

    func refreshPeriod() {
        guard isReady else { return }
        let date = now()
        let interval = calendar.dateInterval(of: budget.period == .daily ? .day : .weekOfYear, for: date)!
        let first = dayKey(for: interval.start)
        let today = dayKey(for: date)
        let selected = days.keys.filter { $0 >= first && $0 <= today }.sorted()
        snapshot = .combining(selected.compactMap { days[$0] })
        nextReset = interval.end
        // Keep enough daily history to switch periods without losing this week.
        let cutoff = dayKey(for: calendar.date(byAdding: .day, value: -31, to: date)!)
        days = days.filter { $0.key >= cutoff }
        let periodKey = "\(budget.period.rawValue):\(first):\(budget.limitWattHours)"
        if isLimitReached && acknowledgedLimitPeriod != periodKey {
            if limitNotice?.periodKey != periodKey {
                noticeOwner = nil
                limitNotice = EnergyLimitNotice(periodKey: periodKey)
            }
        } else {
            noticeOwner = nil
            limitNotice = nil
        }
    }

    func claimLimitNotice(owner: UUID) -> Bool {
        guard limitNotice != nil, noticeOwner == nil || noticeOwner == owner else { return false }
        noticeOwner = owner
        return true
    }

    func dismissLimitNotice(owner: UUID) {
        guard noticeOwner == owner, let notice = limitNotice else { return }
        acknowledgedLimitPeriod = notice.periodKey
        noticeOwner = nil
        limitNotice = nil
        persistSoon()
    }

    private func scheduleRollover() {
        rolloverTask?.cancel()
        rolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.secondsUntilMidnight else { return }
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.refreshPeriod()
            }
        }
    }

    private var secondsUntilMidnight: TimeInterval {
        max(calendar.dateInterval(of: .day, for: now())!.end.timeIntervalSince(now()), 1)
    }

    private func persistSoon() {
        guard isReady else { return }
        let previousSave = persistenceTask
        let value = PersistedEnergyUsage(budget: budget, days: days, acknowledgedLimitPeriod: acknowledgedLimitPeriod)
        persistenceTask = Task { [weak self, repository] in
            await previousSave?.value
            do { try await repository.save(value) }
            catch { self?.lastError = "Energy usage and limits could not be saved." }
        }
    }

    func resetToday() {
        guard isReady else { return }
        days.removeValue(forKey: dayKey(for: now()))
        refreshPeriod()
        persistSoon()
    }

    func deactivate() {
        isActive = false
        rolloverTask?.cancel()
    }

    func flush() async { await persistenceTask?.value }
    func dismissError() { lastError = nil }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
