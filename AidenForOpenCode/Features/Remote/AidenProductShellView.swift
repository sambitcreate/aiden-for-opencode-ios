import SwiftUI
import UIKit

enum AidenChromeSymbols {
    static let overflowMenu = "ellipsis"
    static let productSwitcherDisclosure = "chevron.down"
}

// MARK: - Product areas

/// The two top-level product surfaces. Workspaces is the stacked/split home;
/// Settings is presented as a sheet from the profile chip, matching Aiden On The Go.
enum AidenProductArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case workspaces
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "folder.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// Routes pushed inside the Workspaces surface. `directory` carries the raw
/// server directory path (the "workspace" identity); `session` carries a
/// session id.
enum AidenWorkspacesRoute: Hashable, Sendable {
    case allSessions
    case agents
    case directory(String)
    case session(String)

    /// The directory id when this route is a directory, used by the persisted
    /// navigation projection.
    var directoryID: String? {
        if case .directory(let directory) = self { return directory }
        return nil
    }

    /// Stable UserDefaults token for the full compact path, including sessions.
    var persistenceToken: String {
        switch self {
        case .allSessions: return "allSessions"
        case .agents: return "agents"
        case .directory(let directory): return "dir:\(directory)"
        case .session(let sessionID): return "ses:\(sessionID)"
        }
    }

    init?(persistenceToken: String) {
        if persistenceToken == "allSessions" {
            self = .allSessions
            return
        }
        if persistenceToken == "agents" {
            self = .agents
            return
        }
        if persistenceToken.hasPrefix("dir:") {
            self = .directory(String(persistenceToken.dropFirst(4)))
            return
        }
        if persistenceToken.hasPrefix("ses:") {
            self = .session(String(persistenceToken.dropFirst(4)))
            return
        }
        return nil
    }
}

// MARK: - Relative timestamps

/// Short bounded label ("just now", "5m ago", …) for list rows that do not
/// need the older "mins/hrs" wording.
enum AidenRelativeTime {
    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded(.down))
        if seconds < 60 { return String(localized: "just now") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes)m ago") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h ago") }
        let days = hours / 24
        if days < 7 { return String(localized: "\(days)d ago") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

enum AidenRelativeTimeFormatter {
    /// Converts an epoch-milliseconds timestamp into a bounded label.
    static func label(epochMilliseconds milliseconds: Double?, now: Date = Date()) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return AidenRelativeTime.label(for: Date(timeIntervalSince1970: milliseconds / 1_000), now: now)
    }
}

/// Hero-home wording ("1 min ago", "2 hrs ago"), ported verbatim from the old
/// app's home rows.
enum AidenRelativeTimestamp {
    static func text(for date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "just now" }

        let minutes = Int(elapsed / 60)
        if minutes < 60 { return minutes == 1 ? "1 min ago" : "\(minutes) mins ago" }

        let hours = Int(elapsed / 3_600)
        if hours < 24 { return hours == 1 ? "1 hr ago" : "\(hours) hrs ago" }

        let days = Int(elapsed / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

/// Live-updating timestamp rendered from a 30-second periodic timeline so row
/// labels age without per-row timers.
struct AidenRelativeTimestampView: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(AidenRelativeTimestamp.text(for: date, now: context.date))
        }
    }
}

// MARK: - Workspace projection

/// Client-side projection of `SessionInfo` rows into the Workspaces home:
/// one card per distinct `location.directory`, plus the recent-chat stream.
enum AidenWorkspaceProjection {
    struct DirectoryGroup: Equatable {
        let directory: String
        let sessions: [SessionInfo]

        var sessionCount: Int { sessions.count }

        var latestUpdatedMilliseconds: Double? {
            sessions.map(\.time.updated).max()
        }

        var projectID: String? {
            sessions.first?.projectID
        }
    }

    /// Deduplicates by session id (cursor windows may overlap) and sorts
    /// newest-first.
    static func recentChats(from sessions: [SessionInfo]) -> [SessionInfo] {
        var seen = Set<String>()
        return sessions
            .sorted { $0.time.updated > $1.time.updated }
            .filter { seen.insert($0.id).inserted }
    }

    /// Groups by `location.directory`, directories ordered by their most
    /// recent session.
    static func groups(from sessions: [SessionInfo]) -> [DirectoryGroup] {
        let unique = recentChats(from: sessions)
        let byDirectory = Dictionary(grouping: unique, by: \.location.directory)
        return byDirectory
            .map { DirectoryGroup(directory: $0.key, sessions: $0.value.sorted { $0.time.updated > $1.time.updated }) }
            .sorted { ($0.latestUpdatedMilliseconds ?? 0) > ($1.latestUpdatedMilliseconds ?? 0) }
    }

    /// Leaf-name fallback chain: `lastPathComponent`, then the project id,
    /// then "Server Root" (covers `/` and empty paths).
    static func displayName(directory: String, projectID: String) -> String {
        if directory != "/" {
            let leaf = (directory as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !leaf.isEmpty { return leaf }
        }
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { return project }
        return String(localized: "Server Root")
    }

    /// Placeholder titles ("", "New session - …") fall back to a stable label;
    /// real titles pass through untouched.
    static func displayTitle(_ raw: String) -> String {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Untitled session")
        }
        if raw.hasPrefix("New session - ") {
            return String(localized: "Untitled session")
        }
        return raw
    }

    /// Directory-card subtitle: "N sessions · latest Xh ago" (time part
    /// omitted when the window carries no usable timestamp).
    static func cardSubtitle(sessionCount: Int, latestUpdatedMilliseconds: Double?, now: Date) -> String {
        let countPart = sessionCount == 1
            ? String(localized: "1 session")
            : String(localized: "\(sessionCount) sessions")
        guard let milliseconds = latestUpdatedMilliseconds, milliseconds > 0 else { return countPart }
        let time = AidenRelativeTime.label(
            for: Date(timeIntervalSince1970: milliseconds / 1_000),
            now: now
        )
        return String(localized: "\(countPart) · latest \(time)")
    }

    /// Client-side home search across title, agent, and directory leaf.
    static func filteredRecent(_ sessions: [SessionInfo], query: String) -> [SessionInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { session in
            displayTitle(session.title).localizedCaseInsensitiveContains(needle)
                || (session.agent ?? "").localizedCaseInsensitiveContains(needle)
                || displayName(directory: session.location.directory, projectID: session.projectID)
                    .localizedCaseInsensitiveContains(needle)
        }
    }
}

// MARK: - Shared formatting helpers

/// Single-line, user-presentable transport error text. Credentials never
/// appear in any branch.
func aidenFriendlyErrorMessage(_ error: Error) -> String {
    if let apiError = error as? OpenCodeAPIError {
        if case .unauthorized = apiError {
            return String(localized: "Session expired — reconnect from Settings.")
        }
        return apiError.debugSummary
    }
    return error.localizedDescription
}

/// Parses `#rrggbb` agent colors into normalized RGB components; nil when the
/// value is absent or malformed.
func aidenNormalizedHexRGB(_ value: String?) -> (red: Double, green: Double, blue: Double)? {
    guard var hex = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    func component(_ range: Range<String.Index>) -> Double? {
        guard let byte = UInt8(hex[range], radix: 16) else { return nil }
        return Double(byte) / 255.0
    }
    let start = hex.startIndex
    guard let red = component(start..<hex.index(start, offsetBy: 2)),
          let green = component(hex.index(start, offsetBy: 2)..<hex.index(start, offsetBy: 4)),
          let blue = component(hex.index(start, offsetBy: 4)..<hex.index(start, offsetBy: 6)) else { return nil }
    return (red, green, blue)
}

// MARK: - Navigation reconciliation

/// Size-class reconciliation math, ported from the old product shell and
/// re-targeted from workspace ids to directory ids.
enum AidenWorkspaceNavigation {
    static func reconciledSelection(current: String?, directoryIDs: [String]) -> String? {
        guard !directoryIDs.isEmpty else { return nil }
        if let current, directoryIDs.contains(current) { return current }
        return directoryIDs.first
    }

    static func reconciledCompactPath(current: [String], directoryIDs: [String]) -> [String] {
        guard let directoryID = current.last, directoryIDs.contains(directoryID) else { return [] }
        return [directoryID]
    }

    static func compactPath(
        enteringFromSplit: Bool,
        current: [String],
        selectedDirectoryID: String?,
        directoryIDs: [String]
    ) -> [String] {
        let current = reconciledCompactPath(current: current, directoryIDs: directoryIDs)
        if !current.isEmpty { return current }
        guard enteringFromSplit,
              let selectedDirectoryID,
              directoryIDs.contains(selectedDirectoryID) else { return [] }
        return [selectedDirectoryID]
    }
}

// MARK: - Per-installation navigation persistence

/// Persists `{selectedArea, selectedDirectory, compactDirectoryPath}` per
/// installation in UserDefaults. Directory ids are raw server paths, so the
/// sanitizer admits `/` in addition to the usual id characters.
@Observable
final class AidenProductNavigationStore {
    private struct Snapshot: Codable {
        var areasByInstance: [String: AidenProductArea] = [:]
        var selectedDirectoryByInstance: [String: String] = [:]
        var compactDirectoryPathByInstance: [String: [String]] = [:]
        var compactRoutePathByInstance: [String: [String]] = [:]
    }

    private static let snapshotKey = "aiden.product-navigation.v2"
    @ObservationIgnored private let defaults: UserDefaults
    private var snapshot: Snapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.snapshotKey),
           data.count <= 1_048_576,
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = Self.sanitized(decoded)
        } else {
            snapshot = Snapshot()
        }
    }

    func area(for instanceID: String?) -> AidenProductArea {
        guard let instanceID = Self.safeID(instanceID) else { return .workspaces }
        return snapshot.areasByInstance[instanceID] ?? .workspaces
    }

    func select(_ area: AidenProductArea, for instanceID: String?) {
        guard let instanceID = Self.safeID(instanceID) else { return }
        guard snapshot.areasByInstance[instanceID] != area else { return }
        snapshot.areasByInstance[instanceID] = area
        persist()
    }

    func selectedDirectory(for instanceID: String?) -> String? {
        guard let instanceID = Self.safeID(instanceID) else { return nil }
        return snapshot.selectedDirectoryByInstance[instanceID]
    }

    func compactDirectoryPath(for instanceID: String?) -> [String] {
        guard let instanceID = Self.safeID(instanceID) else { return [] }
        return snapshot.compactDirectoryPathByInstance[instanceID] ?? []
    }

    func compactRoutePath(for instanceID: String?) -> [AidenWorkspacesRoute] {
        guard let instanceID = Self.safeID(instanceID) else { return [] }
        if let tokens = snapshot.compactRoutePathByInstance[instanceID], !tokens.isEmpty {
            return tokens.compactMap(AidenWorkspacesRoute.init(persistenceToken:))
        }
        return (snapshot.compactDirectoryPathByInstance[instanceID] ?? [])
            .map { AidenWorkspacesRoute.directory($0) }
    }

    /// Writes the compact path; the selected directory trails the last directory route.
    func setCompactDirectoryPath(_ path: [String], for instanceID: String?) {
        setCompactPath(path.map { AidenWorkspacesRoute.directory($0) }, for: instanceID)
    }

    func setCompactPath(_ path: [AidenWorkspacesRoute], for instanceID: String?) {
        guard let instanceID = Self.safeID(instanceID) else { return }
        let sanitized = Array(path.prefix(16).compactMap { route -> AidenWorkspacesRoute? in
            switch route {
            case .allSessions, .agents:
                return route
            case .directory(let directory):
                return Self.safeID(directory).map { .directory($0) }
            case .session(let sessionID):
                return Self.safeID(sessionID).map { .session($0) }
            }
        })
        let directories = Array(sanitized.compactMap(\.directoryID))
        if sanitized.isEmpty {
            snapshot.compactRoutePathByInstance.removeValue(forKey: instanceID)
            snapshot.compactDirectoryPathByInstance.removeValue(forKey: instanceID)
            snapshot.selectedDirectoryByInstance.removeValue(forKey: instanceID)
        } else {
            snapshot.compactRoutePathByInstance[instanceID] = sanitized.map(\.persistenceToken)
            if directories.isEmpty {
                snapshot.compactDirectoryPathByInstance.removeValue(forKey: instanceID)
                snapshot.selectedDirectoryByInstance.removeValue(forKey: instanceID)
            } else {
                snapshot.compactDirectoryPathByInstance[instanceID] = directories
                snapshot.selectedDirectoryByInstance[instanceID] = directories[directories.count - 1]
            }
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 1_048_576 else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    private static func sanitized(_ value: Snapshot) -> Snapshot {
        let instanceIDs = Set(
            value.areasByInstance.keys.compactMap(safeID)
                + value.selectedDirectoryByInstance.keys.compactMap(safeID)
                + value.compactDirectoryPathByInstance.keys.compactMap(safeID)
                + value.compactRoutePathByInstance.keys.compactMap(safeID)
        )
        return instanceIDs.prefix(64).reduce(into: Snapshot()) { result, instanceID in
            if let area = value.areasByInstance[instanceID] {
                result.areasByInstance[instanceID] = area
            }
            if let directoryID = safeID(value.selectedDirectoryByInstance[instanceID]) {
                result.selectedDirectoryByInstance[instanceID] = directoryID
            }
            let path = Array(
                (value.compactDirectoryPathByInstance[instanceID] ?? []).compactMap(safeID).suffix(16)
            )
            if !path.isEmpty {
                result.compactDirectoryPathByInstance[instanceID] = path
                if result.selectedDirectoryByInstance[instanceID] == nil {
                    result.selectedDirectoryByInstance[instanceID] = path[path.count - 1]
                }
            }
            let routes = Array((value.compactRoutePathByInstance[instanceID] ?? []).prefix(16).compactMap { token -> String? in
                guard let route = AidenWorkspacesRoute(persistenceToken: token) else { return nil }
                switch route {
                case .allSessions, .agents:
                    return route.persistenceToken
                case .directory(let directory):
                    return safeID(directory).map { AidenWorkspacesRoute.directory($0).persistenceToken }
                case .session(let sessionID):
                    return safeID(sessionID).map { AidenWorkspacesRoute.session($0).persistenceToken }
                }
            })
            if !routes.isEmpty {
                result.compactRoutePathByInstance[instanceID] = routes
            }
        }
    }

    private static func safeID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.unicodeScalars.count <= 160,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "._:/-".unicodeScalars.contains(scalar)
              }) else { return nil }
        return value
    }
}

// MARK: - Glass chrome (ported verbatim from the old app)

private struct AidenLiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            content.background(tint, in: Capsule())
        }
    }
}

private struct AidenChromeGlassModifier<GlassShape: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aidenPalette) private var palette

    let isInteractive: Bool
    let shape: GlassShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            if isInteractive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else if reduceTransparency {
            content
                .background(palette.raised, in: shape)
                .overlay(shape.stroke(palette.foreground.opacity(0.14), lineWidth: 0.5))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(palette.foreground.opacity(0.10), lineWidth: 0.5))
        }
    }
}

private struct AidenProminentGlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aidenPalette) private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.buttonStyle(.glass)
        } else if reduceTransparency {
            content
                .buttonStyle(.plain)
                .background(palette.raised, in: Capsule())
                .overlay(Capsule().stroke(palette.foreground.opacity(0.16), lineWidth: 0.5))
        } else {
            content
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(palette.foreground.opacity(0.10), lineWidth: 0.5))
        }
    }
}

private extension View {
    func aidenLiquidGlassCapsule(tint: Color) -> some View {
        modifier(AidenLiquidGlassCapsuleModifier(tint: tint))
    }

    func aidenChromeGlass<GlassShape: InsettableShape>(
        isInteractive: Bool = false,
        in shape: GlassShape
    ) -> some View {
        modifier(AidenChromeGlassModifier(isInteractive: isInteractive, shape: shape))
    }

    func aidenProminentGlassButton() -> some View {
        modifier(AidenProminentGlassButtonModifier())
    }
}

// MARK: - Skeleton

/// A single raised placeholder block with a slow shimmer sweep, gated on the
/// Reduce Motion preference.
struct AidenSkeletonBlock: View {
    @Environment(\.aidenPalette) private var palette
    let width: CGFloat?
    let height: CGFloat
    let radius: CGFloat
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette.raised)
                .overlay {
                    if !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            let duration = 1.6
                            let elapsed = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: duration)
                            let progress = elapsed / duration
                            LinearGradient(
                                colors: [
                                    .clear,
                                    palette.foreground.opacity(0.12),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(24, proxy.size.width * 0.7))
                            .offset(x: (-proxy.size.width * 0.85) + (proxy.size.width * 1.7 * progress))
                            .mask {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Shell

struct AidenProductShellView: View {
    @Bindable var coordinator: AidenRemoteCoordinator
    @Binding var navigationRequest: AidenNavigationRequest?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var navigationStore = AidenProductNavigationStore()

    @State private var selectedArea: AidenProductArea = .workspaces
    /// Single navigation truth for the Workspaces surface: the iPhone stack
    /// path, whose trailing entry also resolves the iPad detail pane.
    @State private var compactPath: [AidenWorkspacesRoute] = []
    @State private var isNewSessionPresented = false
    @State private var isShowingAppSettings = false
    @State private var directoryIDs: [String] = []
    @State private var hasLoadedDirectories = false

    private var usesSplitNavigation: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if usesSplitNavigation {
                sidebarLayout
            } else {
                tabLayout
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .offline(let message) = coordinator.connectionState {
                AidenOfflineBanner(message: message) {
                    Task { await coordinator.connectActiveInstallation() }
                }
            }
        }
        .overlay {
            if coordinator.connectionState == .connecting {
                ProgressView(String(localized: "Connecting to OpenCode…"))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            String(localized: "Aiden for OpenCode"),
            isPresented: Binding(
                get: { coordinator.presentedError != nil },
                set: { if !$0 { coordinator.presentedError = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { coordinator.presentedError = nil }
        } message: {
            Text(coordinator.presentedError ?? String(localized: "The operation could not be completed."))
        }
        .sheet(isPresented: $isShowingAppSettings) {
            AidenSettingsAreaView(coordinator: coordinator)
        }
        .sheet(isPresented: $isNewSessionPresented) {
            AidenNewSessionSheet(coordinator: coordinator, directory: nil) { created in
                openSession(created.id)
            }
        }
        .onChange(of: navigationRequest) { _, request in
            guard request != nil else { return }
            resolveNavigation(request)
        }
        .onChange(of: selectedArea) { _, area in
            navigationStore.select(area, for: coordinator.instanceId)
        }
        .onChange(of: compactPath) { _, path in
            navigationStore.setCompactPath(path, for: coordinator.instanceId)
        }
        .onChange(of: usesSplitNavigation) { wasSplit, isSplit in
            reconcileSizeClassChange(wasSplit: wasSplit, isSplit: isSplit)
        }
        .task(id: coordinator.instanceId) { restorePersistedNavigation() }
    }

    // MARK: Layouts

    private var tabLayout: some View {
        NavigationStack(path: $compactPath) {
            AidenWorkspaceHomeView(
                coordinator: coordinator,
                embedsInStack: true,
                onOpenSettings: { isShowingAppSettings = true },
                onOpenRoute: { compactPath.append($0) },
                onDirectoryIDsChanged: { reconcileKnownDirectories($0) }
            )
            .navigationDestination(for: AidenWorkspacesRoute.self) { route in
                workspacesDestination(route)
            }
        }
    }

    private var sidebarLayout: some View {
        NavigationSplitView {
            AidenWorkspaceHomeView(
                coordinator: coordinator,
                embedsInStack: false,
                onOpenSettings: { isShowingAppSettings = true },
                onOpenRoute: { replaceOrAppendRoute($0) },
                onDirectoryIDsChanged: { reconcileKnownDirectories($0) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            NavigationStack {
                workspacesDetail
                    .navigationDestination(for: AidenWorkspacesRoute.self) { route in
                        workspacesDestination(route)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var workspacesDetail: some View {
        switch compactPath.last {
        case .session(let sessionID):
            AidenChatDetailView(coordinator: coordinator, sessionID: sessionID)
        case .directory(let directory):
            AidenDirectoryDetailView(coordinator: coordinator, directory: directory, onOpenSession: { openSession($0) })
        case .allSessions:
            AidenAllSessionsView(coordinator: coordinator, onOpenSession: { openSession($0) })
        case .agents:
            AidenAgentsAreaView(coordinator: coordinator, onOpenSession: { openSession($0) })
        case nil:
            ContentUnavailableView(
                String(localized: "Choose a Workspace"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(String(localized: "Select a workspace to see its sessions."))
            )
        }
    }

    @ViewBuilder
    private func workspacesDestination(_ route: AidenWorkspacesRoute) -> some View {
        switch route {
        case .session(let sessionID):
            AidenChatDetailView(coordinator: coordinator, sessionID: sessionID)
        case .directory(let directory):
            AidenDirectoryDetailView(coordinator: coordinator, directory: directory, onOpenSession: { openSession($0) })
        case .allSessions:
            AidenAllSessionsView(coordinator: coordinator, onOpenSession: { openSession($0) })
        case .agents:
            AidenAgentsAreaView(coordinator: coordinator, onOpenSession: { openSession($0) })
        }
    }

    // MARK: Navigation plumbing

    /// Directory ids referenced by the current compact path, in order.
    static func directoryIDs(in path: [AidenWorkspacesRoute]) -> [String] {
        path.compactMap(\.directoryID)
    }

    private func openSession(_ sessionID: String) {
        selectedArea = .workspaces
        if case .session = compactPath.last {
            compactPath[compactPath.count - 1] = .session(sessionID)
        } else if compactPath.last != .session(sessionID) {
            compactPath.append(.session(sessionID))
        }
    }

    /// iPad sidebar taps replace the detail instead of stacking.
    private func replaceOrAppendRoute(_ route: AidenWorkspacesRoute) {
        if case .session = route, !compactPath.isEmpty {
            compactPath.append(route)
        } else {
            compactPath = [route]
        }
    }

    /// Consumes a deep-link request routed through ContentView. The request is
    /// cleared immediately so opening the same link twice still re-triggers.
    private func resolveNavigation(_ request: AidenNavigationRequest?) {
        guard let request else { return }
        navigationRequest = nil
        selectedArea = .workspaces
        switch request.destination {
        case .session(let sessionID):
            openSession(sessionID)
        case .newSession:
            isNewSessionPresented = true
        }
    }

    private func restorePersistedNavigation() {
        directoryIDs = []
        hasLoadedDirectories = false
        guard let instanceId = coordinator.instanceId else {
            selectedArea = .workspaces
            compactPath = []
            return
        }
        selectedArea = navigationStore.area(for: instanceId)
        compactPath = navigationStore.compactRoutePath(for: instanceId)
    }

    /// Drops stale directory ids from the navigation state once the home list
    /// reports the authoritative window. Runs only after a real load so a cold
    /// start cannot wipe a restored path before data arrives.
    private func reconcileKnownDirectories(_ ids: [String]) {
        directoryIDs = ids
        guard hasLoadedDirectories || !ids.isEmpty else { return }
        hasLoadedDirectories = true
        guard !ids.isEmpty else { return }

        let current = Self.directoryIDs(in: compactPath)
        if let last = current.last, !ids.contains(last) {
            compactPath = compactPath.compactMap { route in
                if let directory = route.directoryID {
                    return ids.contains(directory) ? route : nil
                }
                return route
            }
        }
    }

    private func reconcileSizeClassChange(wasSplit: Bool, isSplit: Bool) {
        if isSplit || !compactPath.isEmpty { return }
        compactPath = AidenWorkspaceNavigation.compactPath(
            enteringFromSplit: wasSplit,
            current: [],
            selectedDirectoryID: navigationStore.selectedDirectory(for: coordinator.instanceId),
            directoryIDs: directoryIDs
        )
        .map { AidenWorkspacesRoute.directory($0) }
    }
}

// MARK: - Workspaces hero home

/// One presented sheet at a time on the home surface.
private enum AidenHomeSheet: Hashable, Identifiable {
    case newSession(agent: String?, directory: String?)
    case directoryPicker
    case agentPicker

    var id: Self { self }
}

/// Restores the old app's hero home: brand chip + search capsule header,
/// quick-nav rows, workspace directory cards, and the recent-chat stream.
struct AidenWorkspaceHomeView: View {
    @Bindable var coordinator: AidenRemoteCoordinator
    /// True when rows can push via `NavigationLink(value:)` (compact stack);
    /// false in the iPad sidebar, where rows report through `onOpenRoute`.
    let embedsInStack: Bool
    let onOpenSettings: () -> Void
    let onOpenRoute: (AidenWorkspacesRoute) -> Void
    let onDirectoryIDsChanged: ([String]) -> Void

    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenReduceMotion) private var reduceMotion

    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var activeSessionIDs: Set<String> = []
    @State private var pendingAskSessionIDs: Set<String> = []
    @State private var isHomeVisible = false
    @State private var isCreating = false
    @State private var creationStatus = ""
    @State private var isShowingNewSessionChoices = false
    @State private var presentedSheet: AidenHomeSheet?
    @FocusState private var searchFieldIsFocused: Bool
    @Namespace private var fabTransition

    private var isConnected: Bool {
        if case .connected = coordinator.connectionState { return true }
        return false
    }

    private var groups: [AidenWorkspaceProjection.DirectoryGroup] {
        AidenWorkspaceProjection.groups(from: sessions)
    }

    private var recentChats: [SessionInfo] {
        if isSearching {
            return AidenWorkspaceProjection.filteredRecent(
                AidenWorkspaceProjection.recentChats(from: sessions),
                query: searchText
            )
        }
        return AidenWorkspaceProjection.recentChats(from: sessions)
    }

    private var serverRootDirectory: String? {
        if case .connected(server: let server) = coordinator.connectionState {
            return server.directory
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            homeList
            if !isSearching {
                newSessionButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.24, extraBounce: 0), value: isSearching)
        .background(palette.canvas.ignoresSafeArea())
        // The hero header replaces the system bar; pushed pages keep theirs.
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if isCreating {
                creationCapsule
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            presentedSheetView(sheet)
        }
        .onAppear { isHomeVisible = true }
        .onDisappear { isHomeVisible = false }
        .task(id: ReloadKey(instanceId: coordinator.instanceId, isConnected: isConnected)) {
            await reload()
        }
        .task(id: PresencePollKey(instanceId: coordinator.instanceId, isConnected: isConnected, isVisible: isHomeVisible)) {
            await pollPresence()
        }
    }

    // MARK: Home list

    private var homeList: some View {
        List {
            homeHeader
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if isLoading, sessions.isEmpty {
                AidenWorkspaceHomeSkeleton(reduceMotion: reduceMotion)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                if !isSearching {
                        homeNavigationRows
                        .padding(.top, 10)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(palette.canvas)
                }

                if !isSearching {
                    sectionHeader("Workspaces")
                    directoryCards
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !isSearching {
                    sectionHeader("Recent Chats")
                }

                chatRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentMargins(.bottom, 104, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: Header

    private var homeHeader: some View {
        HStack(spacing: isSearching ? 0 : 16) {
            // OLD product-switcher visual, static now that tabs own switching.
            HStack(spacing: 4) {
                Image("AidenAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Image(systemName: AidenChromeSymbols.productSwitcherDisclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(minHeight: 40)
            .aidenChromeGlass(isInteractive: false, in: Capsule())
            .frame(width: isSearching ? 0 : 68, height: 68, alignment: .leading)
            .opacity(isSearching ? 0 : 1)
            .clipped()
            .accessibilityHidden(true)

            searchChrome
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .animation(.smooth(duration: 0.24, extraBounce: 0), value: isSearching)
    }

    private var searchChrome: some View {
        HStack(spacing: isSearching ? 8 : 2) {
            Button {
                openSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSearching ? palette.secondary : palette.foreground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSearching ? String(localized: "Focus chat search") : String(localized: "Search chats"))

            if isSearching {
                TextField(String(localized: "Search chats"), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFieldIsFocused)
                    .submitLabel(.done)

                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close search"))
            } else {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Profile and app settings"))
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: isSearching ? .infinity : nil, alignment: .trailing)
        .aidenChromeGlass(isInteractive: true, in: Capsule())
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    private func openSearch() {
        if isSearching {
            searchFieldIsFocused = true
            return
        }

        withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
            isSearching = true
        }
        Task { @MainActor in
            await Task.yield()
            searchFieldIsFocused = true
        }
    }

    private func closeSearch() {
        searchText = ""
        searchFieldIsFocused = false
        withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
            isSearching = false
        }
    }

    // MARK: Quick nav rows

    private var homeNavigationRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            routeButton(.allSessions) {
                homeNavigationRow(
                    title: String(localized: "All Sessions"),
                    systemImage: "bubble.left.and.bubble.right"
                )
            }

            routeButton(.agents) {
                homeNavigationRow(
                    title: String(localized: "Agents"),
                    systemImage: "sparkles"
                )
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func routeButton<Content: View>(
        _ route: AidenWorkspacesRoute,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if embedsInStack {
            NavigationLink(value: route) { content() }
                .buttonStyle(.plain)
                .disabled(!isConnected)
        } else {
            Button { onOpenRoute(route) } label: { content() }
                .buttonStyle(.plain)
                .disabled(!isConnected)
        }
    }

    private func homeNavigationRow(
        title: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 28)

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 24)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Directory cards

    @ViewBuilder
    private var directoryCards: some View {
        if groups.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.directory) { group in
                    directoryRow(group)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func directoryRow(_ group: AidenWorkspaceProjection.DirectoryGroup) -> some View {
        // Button (not row-root NavigationLink): a List auto-chevron would land
        // on top of the card's count chip — OLD card skins never showed one.
        Button { onOpenRoute(.directory(group.directory)) } label: {
            AidenWorkspaceCard(group: group)
        }
        .buttonStyle(.plain)
    }

    // MARK: Recent chats

    @ViewBuilder
    private var chatRows: some View {
        if let errorMessage, sessions.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Couldn't Load Sessions"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(String(localized: "Try Again")) { Task { await reload() } }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
        } else if sessions.isEmpty, !isLoading, isConnected {
            ContentUnavailableView(
                String(localized: "No Sessions Yet"),
                systemImage: "bubble.left",
                description: Text(String(localized: "Start a session to see it here."))
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
        } else if sessions.isEmpty, !isLoading {
            ContentUnavailableView {
                Label(String(localized: "Offline"), systemImage: "wifi.slash")
            } description: {
                Text(String(localized: "Connect to your OpenCode server to browse sessions."))
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
        } else if recentChats.isEmpty {
            ContentUnavailableView(
                isSearching ? String(localized: "No Matching Chats") : String(localized: "No Chats Yet"),
                systemImage: isSearching ? "magnifyingglass" : "bubble.left",
                description: Text(isSearching
                    ? String(localized: "Try a different search term.")
                    : String(localized: "Start a new session to begin."))
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(palette.canvas)
        } else {
            ForEach(recentChats, id: \.id) { session in
                chatRow(session)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(palette.canvas)
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ session: SessionInfo) -> some View {
        let row = AidenRecentChatRow(
            session: session,
            isRunning: activeSessionIDs.contains(session.id),
            needsAttention: pendingAskSessionIDs.contains(session.id)
        )
        if embedsInStack {
            NavigationLink(value: AidenWorkspacesRoute.session(session.id)) { row }
                .buttonStyle(.plain)
        } else {
            Button { onOpenRoute(.session(session.id)) } label: { row }
                .buttonStyle(.plain)
        }
    }

    // MARK: New-session FAB

    private var newSessionButton: some View {
        Button { isShowingNewSessionChoices = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .frame(width: 42, height: 50)
                .contentShape(Rectangle())
        }
        .aidenProminentGlassButton()
        .disabled(!isConnected || isCreating)
        .accessibilityLabel(String(localized: "New Session"))
        .accessibilityHint(String(localized: "Choose how to begin."))
        .matchedTransitionSource(id: "AidenNewSessionOptions", in: fabTransition)
        .popover(isPresented: $isShowingNewSessionChoices, arrowEdge: .bottom) {
            AidenNewSessionPopover(onSelect: selectNewSessionChoice)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
                .navigationTransition(.zoom(sourceID: "AidenNewSessionOptions", in: fabTransition))
        }
    }

    private func selectNewSessionChoice(_ choice: AidenNewSessionChoice) {
        isShowingNewSessionChoices = false
        Task { @MainActor in
            await Task.yield()
            switch choice {
            case .here:
                await createSession(directory: nil, status: String(localized: "Creating session…"))
            case .otherDirectory:
                presentedSheet = .directoryPicker
            case .chooseAgent:
                presentedSheet = .agentPicker
            }
        }
    }

    private var creationCapsule: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(creationStatus)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .foregroundStyle(palette.canvas)
        .aidenLiquidGlassCapsule(tint: palette.foreground)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sheets

    @ViewBuilder
    private func presentedSheetView(_ sheet: AidenHomeSheet) -> some View {
        switch sheet {
        case .newSession(let agent, let directory):
            AidenNewSessionSheet(coordinator: coordinator, agent: agent, directory: directory) { created in
                presentedSheet = nil
                onOpenRoute(.session(created.id))
                Task { await reload() }
            }
        case .directoryPicker:
            NavigationStack {
                directoryPickerList
            }
        case .agentPicker:
            NavigationStack {
                AidenAgentPickerView(coordinator: coordinator) { agentID in
                    presentedSheet = nil
                    Task { @MainActor in
                        await Task.yield()
                        presentedSheet = .newSession(agent: agentID, directory: nil)
                    }
                }
            }
        }
    }

    private var directoryPickerList: some View {
        List {
            if let root = serverRootDirectory {
                Section(String(localized: "Default")) {
                    pickerRow(
                        title: AidenWorkspaceProjection.displayName(directory: root, projectID: ""),
                        subtitle: root,
                        systemImage: "folder"
                    ) {
                        chooseDirectory(root)
                    }
                }
            }

            let known = groups.filter { $0.directory != serverRootDirectory }
            if !known.isEmpty {
                Section(String(localized: "Directories")) {
                    ForEach(known, id: \.directory) { group in
                        pickerRow(
                            title: AidenWorkspaceProjection.displayName(
                                directory: group.directory,
                                projectID: group.projectID ?? ""
                            ),
                            subtitle: group.directory,
                            systemImage: "folder"
                        ) {
                            chooseDirectory(group.directory)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Other Directory"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { presentedSheet = nil }
            }
        }
    }

    private func pickerRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 38, height: 38)
                    .background(palette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseDirectory(_ directory: String) {
        presentedSheet = nil
        Task { @MainActor in
            await Task.yield()
            await createSession(
                directory: directory,
                status: String(localized: "Creating session…")
            )
        }
    }

    // MARK: Data

    private struct ReloadKey: Equatable {
        let instanceId: String?
        let isConnected: Bool
    }

    private struct PresencePollKey: Equatable {
        let instanceId: String?
        let isConnected: Bool
        let isVisible: Bool
    }

    @MainActor
    private func reload() async {
        guard isConnected, let instanceId = coordinator.instanceId else {
            isLoading = false
            return
        }
        isLoading = sessions.isEmpty
        defer { isLoading = false }
        do {
            // Initial home window: up to 200 recent sessions (2 pages × 100).
            let fetched = try await coordinator.client().allSessions(
                query: SessionsQuery(order: .desc),
                limit: 100,
                maxPages: 2
            )
            guard coordinator.isCurrent(instanceId) else { return }
            sessions = fetched
            errorMessage = nil
            onDirectoryIDsChanged(AidenWorkspaceProjection.groups(from: fetched).map(\.directory))
            recordIntentCatalog(instanceId: instanceId)
        } catch is CancellationError {
        } catch {
            guard coordinator.isCurrent(instanceId) else { return }
            errorMessage = aidenFriendlyErrorMessage(error)
        }
    }

    /// Polls running sessions and pending approvals/questions every 5 seconds
    /// while the home surface is visible; the task cancels via its identity
    /// key when the view disappears.
    @MainActor
    private func pollPresence() async {
        guard isHomeVisible, isConnected else { return }
        while !Task.isCancelled {
            await refreshPresence()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                break
            }
        }
    }

    @MainActor
    private func refreshPresence() async {
        guard let instanceId = coordinator.instanceId, let client = try? coordinator.client() else { return }
        async let active = try? client.activeSessions()
        async let permissions = try? client.permissionRequests()
        async let questions = try? client.questionRequests()
        let (running, permissionList, questionList) = await (active, permissions, questions)
        guard coordinator.isCurrent(instanceId) else { return }
        activeSessionIDs = running ?? []
        pendingAskSessionIDs = Set(
            (permissionList?.map(\.sessionID) ?? []) + (questionList?.map(\.sessionID) ?? [])
        )
    }

    @MainActor
    private func createSession(directory: String?, status: String) async {
        guard !isCreating else { return }
        isCreating = true
        creationStatus = status
        defer {
            isCreating = false
            creationStatus = ""
        }
        do {
            let created = try await coordinator.client().createSession(directory: directory)
            sessions.insert(created, at: 0)
            onDirectoryIDsChanged(AidenWorkspaceProjection.groups(from: sessions).map(\.directory))
            onOpenRoute(.session(created.id))
        } catch {
            coordinator.presentedError = aidenFriendlyErrorMessage(error)
        }
    }

    /// Feeds the App Group intent catalog (ids and titles only).
    private func recordIntentCatalog(instanceId: String) {
        Task {
            await AidenIntentCatalogStore.shared.update(
                sessions: AidenWorkspaceProjection.recentChats(from: sessions)
                    .prefix(20)
                    .map { session in
                        AidenIntentSessionRecord(
                            instanceId: instanceId,
                            sessionId: session.id,
                            title: session.title
                        )
                    },
                for: instanceId
            )
        }
    }
}

/// Cold-load skeleton: header bar plus four row placeholders.
private struct AidenWorkspaceHomeSkeleton: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AidenSkeletonBlock(width: 74, height: 16, radius: 8, reduceMotion: reduceMotion)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 14) {
                    AidenSkeletonBlock(width: 44, height: 44, radius: 12, reduceMotion: reduceMotion)
                    VStack(alignment: .leading, spacing: 8) {
                        AidenSkeletonBlock(width: 120, height: 15, radius: 7.5, reduceMotion: reduceMotion)
                        AidenSkeletonBlock(width: 60, height: 12, radius: 6, reduceMotion: reduceMotion)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading sessions"))
    }
}

// MARK: - Directory card

struct AidenWorkspaceCard: View {
    @Environment(\.aidenPalette) private var palette

    let group: AidenWorkspaceProjection.DirectoryGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("\(group.sessionCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(palette.sidebar, in: Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(palette.foreground.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        AidenWorkspaceProjection.displayName(
            directory: group.directory,
            projectID: group.projectID ?? ""
        )
    }

    private var subtitle: String {
        AidenWorkspaceProjection.cardSubtitle(
            sessionCount: group.sessionCount,
            latestUpdatedMilliseconds: group.latestUpdatedMilliseconds,
            now: Date()
        )
    }
}

// MARK: - Recent chat row

struct AidenRecentChatRow: View {
    @Environment(\.aidenPalette) private var palette

    let session: SessionInfo
    let isRunning: Bool
    let needsAttention: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AidenWorkspaceProjection.displayTitle(session.title))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if needsAttention {
                    Label(String(localized: "Approval needed"), systemImage: "checkmark.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
                if isRunning {
                    Label(String(localized: "Working"), systemImage: "waveform")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
                timestamp
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let agent = session.agent, !agent.isEmpty { return agent }
        return AidenWorkspaceProjection.displayName(
            directory: session.location.directory,
            projectID: session.projectID
        )
    }

    private var timestamp: some View {
        Group {
            if let date = timestampDate {
                AidenRelativeTimestampView(date: date)
            } else {
                Text(String(localized: "recently"))
            }
        }
    }

    private var timestampDate: Date? {
        guard session.time.updated > 0 else { return nil }
        return Date(timeIntervalSince1970: session.time.updated / 1_000)
    }
}

// MARK: - New-session popover

enum AidenNewSessionChoice: CaseIterable, Identifiable {
    case here
    case otherDirectory
    case chooseAgent

    var id: Self { self }

    var title: String {
        switch self {
        case .here: "Start Here"
        case .otherDirectory: "Other Directory…"
        case .chooseAgent: "Choose Agent…"
        }
    }

    var detail: String {
        switch self {
        case .here: "Create a session in the server's default directory."
        case .otherDirectory: "Pick one of this server's known project directories."
        case .chooseAgent: "Start with a specific agent."
        }
    }

    var symbol: String {
        switch self {
        case .here: "plus.bubble"
        case .otherDirectory: "folder.badge.plus"
        case .chooseAgent: "sparkles"
        }
    }
}

private struct AidenNewSessionPopover: View {
    @Environment(\.aidenPalette) private var palette

    let onSelect: (AidenNewSessionChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "New Session"))
                    .font(.title3.bold())
                    .foregroundStyle(palette.foreground)

                Text(String(localized: "Choose how to begin."))
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ForEach(Array(AidenNewSessionChoice.allCases.enumerated()), id: \.element.id) { index, choice in
                Button {
                    onSelect(choice)
                } label: {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 38, height: 38)
                            .background(palette.accent.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.foreground)
                                .lineLimit(1)

                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 6)

                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(choice.detail))

                if index < AidenNewSessionChoice.allCases.count - 1 {
                    Divider()
                        .overlay(palette.secondary.opacity(0.18))
                        .padding(.leading, 69)
                }
            }
        }
        .padding(.bottom, 8)
        .background(palette.canvas.opacity(0.001))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Agent picker sheet

private struct AidenAgentPickerView: View {
    @Bindable var coordinator: AidenRemoteCoordinator
    let onSelect: (String) -> Void

    @Environment(\.aidenPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var agents: [AgentInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView(String(localized: "Loading agents…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label(String(localized: "Couldn't Load Agents"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(String(localized: "Try Again")) { Task { await load() } }
                }
            } else {
                list
            }
        }
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle(String(localized: "Choose Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            ForEach(agents.filter { !$0.hidden }, id: \.id) { agent in
                Button { onSelect(agent.id) } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(agentColor(agent))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.id)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.foreground)
                            if let description = agent.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }

    private func agentColor(_ agent: AgentInfo) -> Color {
        if let rgb = aidenNormalizedHexRGB(agent.color) {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return palette.accent
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await coordinator.client().agents(scope: LocationScope(directory: nil))
            errorMessage = nil
        } catch {
            errorMessage = aidenFriendlyErrorMessage(error)
        }
    }
}

// MARK: - Directory detail

/// Authoritative paginated listing for one workspace directory.
struct AidenDirectoryDetailView: View {
    @Bindable var coordinator: AidenRemoteCoordinator
    let directory: String
    var onOpenSession: (String) -> Void = { _ in }

    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenCodeTypography) private var codeTypography

    @State private var sessions: [SessionInfo] = []
    @State private var nextCursor: String?
    @State private var isLoadingFirstPage = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var isNewSessionPresented = false

    private static let pageSize = 50

    private var isConnected: Bool {
        if case .connected = coordinator.connectionState { return true }
        return false
    }

    private var title: String {
        AidenWorkspaceProjection.displayName(directory: directory, projectID: sessions.first?.projectID ?? "")
    }

    var body: some View {
        Group {
            if isLoadingFirstPage, sessions.isEmpty {
                ProgressView(String(localized: "Loading sessions…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, sessions.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Couldn't Load Sessions"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(String(localized: "Try Again")) { Task { await reload() } }
                }
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Sessions"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(String(localized: "Start a session in this directory to see it here."))
                )
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(String(localized: "Search in directory")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isNewSessionPresented = true
                    } label: {
                        Label(String(localized: "New Session in Directory"), systemImage: "square.and.pencil")
                    }

                    Button {
                        UIPasteboard.general.string = directory
                    } label: {
                        Label(String(localized: "Copy Path"), systemImage: "doc.on.doc")
                    }

                    ShareLink(item: directory) {
                        Label(String(localized: "Share Path"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: AidenChromeSymbols.overflowMenu)
                        .font(.body.weight(.semibold))
                        .contentShape(Circle())
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text(String(localized: "Directory options")))
            }
        }
        .sheet(isPresented: $isNewSessionPresented) {
            AidenNewSessionSheet(coordinator: coordinator, directory: directory) { _ in
                Task { await reload() }
            }
        }
        .task(id: TaskKey(directory: directory, isConnected: isConnected)) { await reload() }
        .refreshable { await reload() }
        .onChange(of: searchText) { _, _ in scheduleSearchReload() }
    }

    private struct TaskKey: Equatable {
        let directory: String
        let isConnected: Bool
    }

    private var list: some View {
        List {
            ForEach(sessions, id: \.id) { session in
                Button {
                    onOpenSession(session.id)
                } label: {
                    AidenSessionRow(session: session)
                }
            }

            if nextCursor != nil {
                Section {
                    if isLoadingMore {
                        HStack(spacing: 10) {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Button(String(localized: "Load more")) {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let projectID = sessions.first?.projectID {
                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(projectID)
                        Text(directory)
                    }
                    .font(codeTypography.swiftUIFont(relativeTo: .caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 104, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
    }

    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        searchDebounce?.cancel()
        guard isConnected else { return }
        isLoadingFirstPage = sessions.isEmpty || !searchText.isEmpty
        defer { isLoadingFirstPage = false }
        do {
            let page = try await coordinator.client().sessions(query: currentQuery(cursor: nil))
            sessions = page.data
            nextCursor = page.cursor.next
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = aidenFriendlyErrorMessage(error)
        }
    }

    @MainActor
    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, isConnected else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await coordinator.client().sessions(query: currentQuery(cursor: cursor))
            let knownIDs = Set(sessions.map(\.id))
            sessions.append(contentsOf: page.data.filter { !knownIDs.contains($0.id) })
            nextCursor = page.cursor.next
        } catch {
            coordinator.presentedError = aidenFriendlyErrorMessage(error)
        }
    }

    private func currentQuery(cursor: String?) -> SessionsQuery {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionsQuery(
            directory: directory,
            limit: Self.pageSize,
            order: .desc,
            search: search.isEmpty ? nil : search,
            cursor: cursor
        )
    }
}

// MARK: - All Sessions area

/// Flat paginated session list pushed from the home quick-nav row.
struct AidenAllSessionsView: View {
    @Bindable var coordinator: AidenRemoteCoordinator
    var onOpenSession: (String) -> Void = { _ in }
    @Environment(\.aidenPalette) private var palette

    @State private var sessions: [SessionInfo] = []
    @State private var nextCursor: String?
    @State private var isLoadingFirstPage = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?

    private static let pageSize = 50

    private var isConnected: Bool {
        if case .connected = coordinator.connectionState { return true }
        return false
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !isConnected {
                offlineView
            } else if isLoadingFirstPage, sessions.isEmpty {
                ProgressView(String(localized: "Loading sessions…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, sessions.isEmpty {
                errorView(errorMessage)
            } else if sessions.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle(String(localized: "Sessions"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(String(localized: "Search sessions")))
        .task(id: coordinator.connectionState) { await reload() }
        .refreshable { await reload() }
        .onChange(of: searchText) { _, _ in scheduleSearchReload() }
    }

    private var listView: some View {
        List {
            ForEach(sessions, id: \.id) { session in
                Button {
                    onOpenSession(session.id)
                } label: {
                    AidenSessionRow(session: session)
                }
            }

            if nextCursor != nil {
                Section {
                    if isLoadingMore {
                        HStack(spacing: 10) {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Button(String(localized: "Load more")) {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(
                isSearching ? String(localized: "No Matches") : String(localized: "No Sessions"),
                systemImage: isSearching ? "magnifyingglass" : "bubble.left.and.bubble.right"
            )
        } description: {
            Text(isSearching
                ? String(localized: "No sessions match your search.")
                : String(localized: "Start a session to see it here."))
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(String(localized: "Couldn't Load Sessions"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(String(localized: "Try Again")) { Task { await reload() } }
        }
    }

    private var offlineView: some View {
        ContentUnavailableView {
            Label(String(localized: "Offline"), systemImage: "wifi.slash")
        } description: {
            Text(String(localized: "Connect to your OpenCode server to browse sessions."))
        } actions: {
            if coordinator.connectionState != .needsPairing {
                Button(String(localized: "Reconnect")) {
                    Task { await coordinator.connectActiveInstallation() }
                }
            }
        }
    }

    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        searchDebounce?.cancel()
        guard isConnected else { return }
        let query = currentQuery(cursor: nil)
        isLoadingFirstPage = sessions.isEmpty || !isSearching
        defer { isLoadingFirstPage = false }
        do {
            let page = try await coordinator.client().sessions(query: query)
            sessions = page.data
            nextCursor = page.cursor.next
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = aidenFriendlyErrorMessage(error)
        }
    }

    @MainActor
    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, isConnected else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await coordinator.client().sessions(query: currentQuery(cursor: cursor))
            let knownIDs = Set(sessions.map(\.id))
            sessions.append(contentsOf: page.data.filter { !knownIDs.contains($0.id) })
            nextCursor = page.cursor.next
        } catch {
            coordinator.presentedError = aidenFriendlyErrorMessage(error)
        }
    }

    private func currentQuery(cursor: String?) -> SessionsQuery {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionsQuery(
            limit: Self.pageSize,
            order: .desc,
            search: search.isEmpty ? nil : search,
            cursor: cursor
        )
    }
}

struct AidenSessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AidenWorkspaceProjection.displayTitle(session.title))
                .font(.body.weight(.medium))
                .lineLimit(1)

            HStack(spacing: 6) {
                if let agent = session.agent, !agent.isEmpty {
                    Text(agent)
                    Text("·")
                }
                Text(updatedLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var updatedLabel: String {
        AidenRelativeTimeFormatter.label(epochMilliseconds: session.time.updated)
            ?? String(localized: "recently")
    }
}

// MARK: - Agents area

struct AidenAgentsAreaView: View {
    private struct PresentedAgent: Identifiable {
        let id: String
    }

    @Bindable var coordinator: AidenRemoteCoordinator
    var onOpenSession: (String) -> Void = { _ in }
    @State private var agents: [AgentInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var presentedAgent: PresentedAgent?
    @Environment(\.aidenPalette) private var palette

    private var isConnected: Bool {
        if case .connected = coordinator.connectionState { return true }
        return false
    }

    var body: some View {
        Group {
            if isLoading, agents.isEmpty {
                ProgressView(String(localized: "Loading agents…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, agents.isEmpty {
                retryView(errorMessage)
            } else if visibleAgents.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Agents"),
                    systemImage: "sparkles",
                    description: Text(String(localized: "This server has no agents configured."))
                )
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle(String(localized: "Agents"))
        .task(id: coordinator.connectionState) { await load() }
        .sheet(item: $presentedAgent) { agent in
            AidenNewSessionSheet(coordinator: coordinator, agent: agent.id, directory: nil) { created in
                onOpenSession(created.id)
            }
        }
    }

    private var visibleAgents: [AgentInfo] {
        agents.filter { !$0.hidden }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 12)],
                spacing: 12
            ) {
                ForEach(visibleAgents, id: \.id) { agent in
                    Button {
                        presentedAgent = PresentedAgent(id: agent.id)
                    } label: {
                        AidenAgentCard(agent: agent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func retryView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(String(localized: "Couldn't Load Agents"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(String(localized: "Try Again")) { Task { await load() } }
        }
    }

    @MainActor
    private func load() async {
        guard isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await coordinator.client().agents(scope: LocationScope(directory: nil))
            errorMessage = nil
        } catch {
            errorMessage = aidenFriendlyErrorMessage(error)
        }
    }
}

private struct AidenAgentCard: View {
    @Environment(\.aidenPalette) private var palette

    let agent: AgentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)

                Text(agent.id)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let description = agent.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.foreground.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var accentColor: Color {
        if let rgb = aidenNormalizedHexRGB(agent.color) {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return palette.accent
    }
}

// MARK: - Settings area

struct AidenSettingsAreaView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var installationPendingRemoval: OpenCodeInstallation?
    @Bindable var coordinator: AidenRemoteCoordinator
    @Environment(AidenAppearanceStore.self) private var appearance
    @State private var isPairingPresented = false
    @State private var isShowingAppearance = false

    var body: some View {
        NavigationStack {
            Form {
                connectionsSection
                addServerSection
                appearanceSection
                aboutSection
            }
            .navigationTitle(String(localized: "App Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "Forget this server?"),
                isPresented: Binding(
                    get: { installationPendingRemoval != nil },
                    set: { if !$0 { installationPendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: installationPendingRemoval
            ) { installation in
                Button(String(localized: "Forget \(installation.name)"), role: .destructive) {
                    Task { await coordinator.removeInstallation(id: installation.id) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: { installation in
                Text(String(localized: "This device loses access to \(installation.endpoint.absoluteString). You can pair again at any time."))
            }
        }
        .sheet(isPresented: $isPairingPresented) {
            AidenPairingView(
                coordinator: coordinator,
                showsIntroduction: false,
                onPaired: { isPairingPresented = false }
            )
        }
        .sheet(isPresented: $isShowingAppearance) {
            AidenAppearanceSettingsView(appearance: appearance)
        }
    }

    private var connectionsSection: some View {
        Section {
            ForEach(coordinator.installationStore.installations) { installation in
                Button {
                    guard installation.id != coordinator.activeInstallationId else { return }
                    Task { await coordinator.switchInstallation(to: installation.id) }
                } label: {
                    AidenInstallationRow(
                        installation: installation,
                        isActive: installation.id == coordinator.activeInstallationId,
                        identityHint: Self.identityHint(
                            for: installation,
                            in: coordinator.installationStore.installations
                        )
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        installationPendingRemoval = installation
                    } label: {
                        Label(String(localized: "Remove"), systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("Tap a server to make it active. Swipe to remove it.")
        }
    }

    private static func identityHint(for installation: OpenCodeInstallation, in installations: [OpenCodeInstallation]) -> String? {
        let duplicateExists = installations.contains {
            $0.id != installation.id && $0.name == installation.name
        }
        guard duplicateExists || installations.count > 1 else { return nil }
        return "Identity \(String(installation.id.suffix(6)))"
    }

    private var addServerSection: some View {
        Section {
            Button {
                isPairingPresented = true
            } label: {
                Label(String(localized: "Add Server…"), systemImage: "plus")
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Button {
                isShowingAppearance = true
            } label: {
                Label(String(localized: "Appearance"), systemImage: "circle.lefthalf.filled")
            }
        } header: {
            Text("Global Defaults")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(String(localized: "App"), value: "Aiden for OpenCode")
            LabeledContent(String(localized: "Version"), value: Self.appVersion)
            LabeledContent(String(localized: "License"), value: "MIT")
            Link(destination: AppConfig.privacyPolicyURL) {
                Label(String(localized: "Privacy Policy"), systemImage: "hand.raised")
            }
            Link(destination: AppConfig.supportURL) {
                Label(String(localized: "Support"), systemImage: "questionmark.circle")
            }
        } header: {
            Text("About")
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct AidenInstallationRow: View {
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenCodeTypography) private var codeTypography
    let installation: OpenCodeInstallation
    let isActive: Bool
    /// Short monospaced id fragment shown when several servers share a name.
    var identityHint: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    installation.name.isEmpty ? installation.endpoint.host ?? installation.id : installation.name,
                    systemImage: "desktopcomputer"
                )
                .lineLimit(1)

                Text(installation.endpoint.absoluteString)
                    .font(codeTypography.swiftUIFont(relativeTo: .caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(lastConnectedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let identityHint {
                    Text(identityHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel(Text("Active"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            [
                isActive ? String(localized: "Selected") : nil,
                lastConnectedLabel,
                identityHint,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .padding(.vertical, 2)
    }

    private var lastConnectedLabel: String {
        if let lastConnectedAt = installation.lastConnectedAt {
            return String(localized: "Last connected \(AidenRelativeTime.label(for: lastConnectedAt))")
        }
        return String(localized: "Never connected")
    }
}

// MARK: - Connectivity chrome

private struct AidenOfflineBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(String(localized: "Retry"), action: retry)
                .font(.footnote.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AidenAppearanceRoot(appearance: AidenAppearanceStore()) {
        AidenProductShellView(coordinator: AidenRemoteCoordinator(), navigationRequest: .constant(nil))
    }
    .environment(AidenAppearanceStore())
}
