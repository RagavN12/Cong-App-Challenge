import AppKit
import SwiftUI

struct FriendsView: View {
    @ObservedObject var store: FriendsStore
    let user: AuthenticatedUser?
    let weeklyUsage: EnergyUsageSnapshot

    @State private var inviteCode = ""
    @State private var copiedCode = false

    private var leaderboard: [LeaderboardRow] {
        let ownRow = LeaderboardRow(
            id: user?.id ?? "you",
            name: user?.displayName ?? "You",
            wattHours: weeklyUsage.electricityWattHours.total,
            isCurrentUser: true
        )
        return ([ownRow] + (store.dashboard?.friends ?? []).map {
            LeaderboardRow(id: $0.userID, name: $0.displayName, wattHours: $0.wattHours, isCurrentUser: false)
        })
        .sorted {
            if $0.wattHours == $1.wattHours { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.wattHours < $1.wattHours
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Friends & leaderboard")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Compare this week’s energy use")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isLoading || store.isWorking)
                .help("Refresh friends")
            }
            .padding(20)

            Divider()

            if store.isLoading && store.dashboard == nil {
                ProgressView("Loading friends…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        inviteCard

                        if let requests = store.dashboard?.incomingRequests, !requests.isEmpty {
                            requestsSection(requests)
                        }

                        leaderboardSection

                        Text("Weekly energy totals are shared only with accepted friends.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 560, height: 680)
        .task {
            await store.load()
        }
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add a friend", systemImage: "person.badge.plus")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                TextField("Friend’s invite code", text: $inviteCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendRequest)

                Button("Send request", action: sendRequest)
                    .buttonStyle(.borderedProminent)
                    .disabled(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
            }

            if let statusMessage = store.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            HStack {
                Text("Your invite code")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(store.dashboard?.inviteCode ?? "…")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button(copiedCode ? "Copied" : "Copy") {
                    guard let code = store.dashboard?.inviteCode else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copiedCode = true
                }
                .buttonStyle(.borderless)
                .disabled(store.dashboard?.inviteCode == nil)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func requestsSection(_ requests: [FriendRequest]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Friend requests", count: requests.count)
            ForEach(requests) { request in
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(request.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Accept") {
                        Task { await store.accept(request) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isWorking)
                }
                .padding(10)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("This week", count: leaderboard.count)

            if (store.dashboard?.friends.isEmpty ?? true) {
                ContentUnavailableView(
                    "No friends yet",
                    systemImage: "person.2",
                    description: Text("Share your invite code or enter a friend’s code to start comparing weekly energy use.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                HStack {
                    Text("LOWEST ENERGY USE RANKS FIRST")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Watt-hours")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                ForEach(Array(leaderboard.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(index == 0 ? Color.green : Color.secondary)
                            .frame(width: 25, height: 25)
                            .background((index == 0 ? Color.green : Color.secondary).opacity(0.1), in: Circle())

                        Image(systemName: row.isCurrentUser ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(row.isCurrentUser ? Color.accentColor : Color.secondary)

                        Text(row.isCurrentUser ? "\(row.name) (You)" : row.name)
                            .font(.system(size: 13, weight: row.isCurrentUser ? .semibold : .regular))
                            .lineLimit(1)

                        Spacer()

                        Text(row.wattHours, format: .number.precision(.fractionLength(3))) + Text(" Wh")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(10)
                    .background(
                        row.isCurrentUser ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .contextMenu {
                        if !row.isCurrentUser,
                           let friend = store.dashboard?.friends.first(where: { $0.userID == row.id }) {
                            Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                                Task { await store.remove(friend) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func sendRequest() {
        let code = inviteCode
        Task {
            await store.sendRequest(inviteCode: code)
            if store.statusMessage != nil { inviteCode = "" }
        }
    }
}

private struct LeaderboardRow {
    let id: String
    let name: String
    let wattHours: Double
    let isCurrentUser: Bool
}
