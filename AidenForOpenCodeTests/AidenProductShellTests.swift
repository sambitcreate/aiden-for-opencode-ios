import Foundation
import XCTest
@testable import AidenForOpenCode

final class AidenProductShellTests: XCTestCase {
    // MARK: - Product areas

    func testProductAreasAreStableAndWellFormed() {
        XCTAssertEqual(AidenProductArea.allCases, [.workspaces, .settings])
        XCTAssertEqual(AidenProductArea.workspaces.symbol, "folder.fill")
        XCTAssertEqual(AidenProductArea.settings.symbol, "gearshape.fill")
        for area in AidenProductArea.allCases {
            XCTAssertEqual(area.id, area.rawValue)
            XCTAssertFalse(area.title.isEmpty)
            XCTAssertFalse(area.symbol.isEmpty)
        }
        let titles = Set(AidenProductArea.allCases.map(\.title))
        let symbols = Set(AidenProductArea.allCases.map(\.symbol))
        XCTAssertEqual(titles.count, AidenProductArea.allCases.count)
        XCTAssertEqual(symbols.count, AidenProductArea.allCases.count)
    }

    // MARK: - Deep links

    func testDeepLinkBuildsAndParsesSessionRoute() {
        let url = AidenDeepLink.sessionURL(instanceId: "inst-1", sessionID: "ses_abc.1")
        XCTAssertNotNil(url)
        let request = AidenDeepLink.request(from: url!)
        XCTAssertEqual(
            request,
            AidenNavigationRequest(destination: .session("ses_abc.1"), instanceId: "inst-1")
        )
    }

    func testDeepLinkSessionWithoutInstanceUsesActiveInstallation() {
        let url = AidenDeepLink.sessionURL(instanceId: nil, sessionID: "ses_abc")
        XCTAssertEqual(
            AidenDeepLink.request(from: url!),
            AidenNavigationRequest(destination: .session("ses_abc"), instanceId: nil)
        )
    }

    func testDeepLinkNewRouteRoundTrips() {
        let url = AidenDeepLink.newSessionURL
        XCTAssertEqual(AidenDeepLink.scheme.lowercased(), "aiden-opencode")
        XCTAssertEqual(
            AidenDeepLink.request(from: url!),
            AidenNavigationRequest(destination: .newSession, instanceId: nil)
        )
    }

    func testDeepLinkRejectsForeignSchemesCredentialsAndUnknownRoutes() {
        func make(_ string: String) -> URL { URL(string: string)! }

        XCTAssertNil(AidenDeepLink.request(from: make("https://session/ses_abc")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://u@session/ses_abc")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://session:4040/ses_abc")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://session/ses_abc#frag")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://workspace/ses_abc")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://new?workspace=w1")))
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://new?instance=a&instance=b")))
        // Path traversal and malformed session ids fail closed.
        XCTAssertNil(AidenDeepLink.request(from: make("aiden-opencode://session/one/two")))
        XCTAssertNil(AidenDeepLink.sessionURL(instanceId: nil, sessionID: ""))
        XCTAssertNil(AidenDeepLink.sessionURL(instanceId: "bad id", sessionID: "ses_ok"))
    }

    // MARK: - Relative time

    func testRelativeTimeLabelsUseBoundedGranularity() {
        let now = Date(timeIntervalSince1970: 10_000_000)

        XCTAssertEqual(AidenRelativeTime.label(for: now.addingTimeInterval(-5), now: now), String(localized: "just now"))
        XCTAssertEqual(AidenRelativeTime.label(for: now.addingTimeInterval(-90), now: now), String(localized: "1m ago"))
        XCTAssertEqual(AidenRelativeTime.label(for: now.addingTimeInterval(-2 * 3_600), now: now), String(localized: "2h ago"))
        XCTAssertEqual(AidenRelativeTime.label(for: now.addingTimeInterval(-3 * 86_400), now: now), String(localized: "3d ago"))

        let calendarLabel = AidenRelativeTime.label(for: now.addingTimeInterval(-30 * 86_400), now: now)
        XCTAssertFalse(calendarLabel.isEmpty)
        XCTAssertFalse(calendarLabel.hasSuffix("ago"))
    }

    func testEpochMillisecondFormatterGuardsInvalidValues() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertEqual(
            AidenRelativeTimeFormatter.label(epochMilliseconds: (now.timeIntervalSince1970 * 1_000) - 59_999, now: now),
            String(localized: "just now")
        )
        XCTAssertNil(AidenRelativeTimeFormatter.label(epochMilliseconds: nil, now: now))
        XCTAssertNil(AidenRelativeTimeFormatter.label(epochMilliseconds: -1, now: now))
    }

    // MARK: - Error presentation

    func testUnauthorizedErrorsMapToReconnectionGuidance() {
        let message = aidenFriendlyErrorMessage(OpenCodeAPIError.unauthorized)
        XCTAssertTrue(message.contains("Settings"))
        XCTAssertNotEqual(message, OpenCodeAPIError.unauthorized.debugSummary)

        XCTAssertFalse(aidenFriendlyErrorMessage(
            OpenCodeAPIError.server(status: 500, message: "boom")
        ).isEmpty)
    }

    // MARK: - Live Activity sanitizers

    func testLiveActivityStringsAreSingleLineAndBounded() {
        XCTAssertEqual(
            AgentRunActivitySanitizer.sessionTitle("  fix \n\n login  bug "),
            "fix login bug"
        )

        let longTitle = String(repeating: "x", count: 100)
        let clampedTitle = AgentRunActivitySanitizer.sessionTitle(longTitle)
        XCTAssertEqual(clampedTitle.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
        XCTAssertTrue(clampedTitle.hasSuffix("..."))

        let stateText = AgentRunActivitySanitizer.stateText("running\ttests\nnow")
        XCTAssertEqual(stateText, "running tests now")
        XCTAssertEqual(
            AgentRunActivitySanitizer.stateText(String(repeating: "y", count: 200)).count,
            AgentRunActivitySanitizer.maximumStateTextCharacters
        )

        let fallback = AgentRunActivitySanitizer.sessionTitle("   ")
        XCTAssertFalse(fallback.isEmpty)
        XCTAssertLessThanOrEqual(fallback.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
    }

    func testLiveActivityPhaseMapsToolsAndPausesElapsedTimer() {
        XCTAssertEqual(AgentRunActivitySanitizer.toolKind(name: "bash"), .command)
        XCTAssertEqual(AgentRunActivitySanitizer.toolKind(name: "grep"), .search)
        XCTAssertEqual(AgentRunActivitySanitizer.toolKind(name: "read"), .files)

        let startedAt = Date(timeIntervalSince1970: 1_000)
        let initial = AgentRunActivityStateReducer.initialState(
            sessionID: "ses_1",
            sessionTitle: "Fix login",
            startedAt: startedAt
        )
        XCTAssertEqual(initial.status, .starting)
        XCTAssertNil(initial.timerPauseTime)
        XCTAssertTrue(initial.isRunning)

        let tool = AgentRunActivityStateReducer.toolStarted(name: "read_file", state: initial)
        XCTAssertEqual(tool.status, .readingFiles)

        let stale = AgentRunActivityStateReducer.stale(state: tool)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.timerPauseTime, stale.updatedAt)

        let finished = AgentRunActivityStateReducer.final(
            status: .complete,
            activity: "Response complete",
            state: tool
        )
        XCTAssertTrue(finished.isFinal)
        XCTAssertFalse(finished.isRunning)
        XCTAssertEqual(finished.timerPauseTime, finished.updatedAt)

        let elapsed = AgentRunElapsedTimeFormatter.label(
            startedAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(75)
        )
        XCTAssertEqual(elapsed, "01:15")

        let thinking = AgentRunActivityProgress.snapshot(
            waitingForApproval: false,
            runningToolName: nil,
            hasLiveText: false,
            isThinking: true
        )
        XCTAssertEqual(thinking.status, .thinking)

        XCTAssertEqual(AgentRunActivityStatus.waitingForApproval.compactTitle, "Approve")
        XCTAssertTrue(
            AidenRemoteLiveActivityManager.matches(
                AgentRunActivityAttributes(
                    instanceID: "inst-1",
                    sessionID: "ses_abc",
                    sessionTitle: "Chat",
                    startedAt: startedAt
                ),
                instanceID: "inst-1",
                sessionID: "ses_abc"
            )
        )
    }

    // MARK: - Agent colors

    func testAgentHexColorsParseTolerantlyButFailClosed() {
        XCTAssertEqual(aidenNormalizedHexRGB("#00FF88")?.red ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(aidenNormalizedHexRGB("#00FF88")?.green ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(aidenNormalizedHexRGB("#00FF88")?.blue ?? -1, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(aidenNormalizedHexRGB("ff8000")?.red ?? -1, 1, accuracy: 0.001)

        XCTAssertNil(aidenNormalizedHexRGB(nil))
        XCTAssertNil(aidenNormalizedHexRGB(""))
        XCTAssertNil(aidenNormalizedHexRGB("#fff"))
        XCTAssertNil(aidenNormalizedHexRGB("#GGHHII"))
        XCTAssertNil(aidenNormalizedHexRGB("#00ff88 extra"))
    }

    // MARK: - App Group intent catalog

    private func makeStore() -> (AidenIntentCatalogStore, String) {
        let suiteName = "test.intent-catalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AidenIntentCatalogStore(defaults: defaults), suiteName)
    }

    func testIntentCatalogStoresOnlySanitizedRecentSessions() async {
        let (store, suiteName) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        await store.update(
            sessions: [
                AidenIntentSessionRecord(instanceId: "inst-1", sessionId: "ses-a", title: "Fix login"),
                AidenIntentSessionRecord(instanceId: "inst-1", sessionId: "", title: "Dropped"),
                AidenIntentSessionRecord(instanceId: "other", sessionId: "ses-b", title: "Wrong instance"),
            ],
            for: "inst-1"
        )

        let snapshot = store.load()
        XCTAssertEqual(snapshot.sessionsByInstance["inst-1"]?.map(\.sessionId), ["ses-a"])
        XCTAssertNil(snapshot.sessionsByInstance["other"])

        await store.update(sessions: [], for: "inst-1")
        XCTAssertTrue(store.load().sessionsByInstance.isEmpty)
    }

    func testIntentCatalogCapsSessionsPerInstallation() async {
        let (store, suiteName) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let sessions = (0..<40).map { index in
            AidenIntentSessionRecord(instanceId: "inst-1", sessionId: "ses-\(index)", title: "S\(index)")
        }
        await store.update(sessions: sessions, for: "inst-1")

        XCTAssertEqual(store.load().sessionsByInstance["inst-1"]?.count, 20)
    }

    // MARK: - Workspace projection fixtures

    private func makeSession(
        id: String,
        directory: String,
        updatedMilliseconds: Double,
        title: String = "Session",
        agent: String? = nil,
        projectID: String = "proj-1"
    ) -> SessionInfo {
        SessionInfo(
            id: id,
            parentID: nil,
            projectID: projectID,
            agent: agent,
            model: nil,
            cost: 0,
            tokens: TokenUsage(input: 0, output: 0, reasoning: 0, cache: TokenCacheUsage(read: 0, write: 0)),
            time: SessionTiming(created: updatedMilliseconds, updated: updatedMilliseconds, archived: nil),
            title: title,
            location: LocationRef(directory: directory, workspaceID: nil),
            subpath: nil,
            revert: nil
        )
    }

    // MARK: - Directory grouping projection

    func testDirectoryGroupsProjectByLatestActivityAndDedupeSessions() {
        let groups = AidenWorkspaceProjection.groups(from: [
            makeSession(id: "a", directory: "/Users/x/api", updatedMilliseconds: 1_000),
            makeSession(id: "b", directory: "/Users/x/web", updatedMilliseconds: 9_000),
            makeSession(id: "c", directory: "/Users/x/api", updatedMilliseconds: 5_000),
            // Duplicate id from an overlapping cursor window — dropped.
            makeSession(id: "b", directory: "/Users/x/web", updatedMilliseconds: 4_000),
        ])

        XCTAssertEqual(groups.map(\.directory), ["/Users/x/web", "/Users/x/api"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["b"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["c", "a"])
        XCTAssertEqual(groups.map(\.sessionCount), [1, 2])
        XCTAssertEqual(groups[1].latestUpdatedMilliseconds, 5_000)
        XCTAssertEqual(groups[1].projectID, "proj-1")
    }

    func testDirectoryGroupingHandlesEmptyInput() {
        XCTAssertTrue(AidenWorkspaceProjection.groups(from: []).isEmpty)
        XCTAssertTrue(AidenWorkspaceProjection.recentChats(from: []).isEmpty)
    }

    func testRecentChatsSortNewestFirstRegardlessOfInputOrder() {
        let chats = AidenWorkspaceProjection.recentChats(from: [
            makeSession(id: "old", directory: "/w", updatedMilliseconds: 100),
            makeSession(id: "new", directory: "/w", updatedMilliseconds: 300),
            makeSession(id: "mid", directory: "/w", updatedMilliseconds: 200),
        ])
        XCTAssertEqual(chats.map(\.id), ["new", "mid", "old"])
    }

    // MARK: - Leaf-name fallback chain

    func testWorkspaceDisplayNamePrefersLeafName() {
        XCTAssertEqual(
            AidenWorkspaceProjection.displayName(directory: "/Users/dev/opencode", projectID: "proj"),
            "opencode"
        )
        XCTAssertEqual(AidenWorkspaceProjection.displayName(directory: "relative/path", projectID: "proj"), "path")
    }

    func testWorkspaceDisplayNameFallsBackToProjectThenServerRoot() {
        // "/" root and empty paths have no leaf component.
        XCTAssertEqual(
            AidenWorkspaceProjection.displayName(directory: "/", projectID: "opencode-core"),
            "opencode-core"
        )
        XCTAssertEqual(AidenWorkspaceProjection.displayName(directory: "", projectID: "proj"), "proj")
        XCTAssertEqual(AidenWorkspaceProjection.displayName(directory: "/", projectID: ""), "Server Root")
        XCTAssertEqual(AidenWorkspaceProjection.displayName(directory: "", projectID: ""), "Server Root")
        XCTAssertEqual(AidenWorkspaceProjection.displayName(directory: "   ", projectID: "  "), "Server Root")
    }

    // MARK: - Card subtitle / count formatting

    func testWorkspaceCardSubtitleFormatsCountAndRecency() {
        let now = Date(timeIntervalSince1970: 10_000_000)

        XCTAssertEqual(
            AidenWorkspaceProjection.cardSubtitle(sessionCount: 1, latestUpdatedMilliseconds: (now.timeIntervalSince1970 - 3_600) * 1_000, now: now),
            String(localized: "1 session · latest 1h ago")
        )
        XCTAssertEqual(
            AidenWorkspaceProjection.cardSubtitle(sessionCount: 4, latestUpdatedMilliseconds: (now.timeIntervalSince1970 - 120) * 1_000, now: now),
            String(localized: "4 sessions · latest 2m ago")
        )
        // Missing or invalid timestamp drops only the recency half.
        XCTAssertEqual(
            AidenWorkspaceProjection.cardSubtitle(sessionCount: 2, latestUpdatedMilliseconds: nil, now: now),
            String(localized: "2 sessions")
        )
        XCTAssertEqual(
            AidenWorkspaceProjection.cardSubtitle(sessionCount: 2, latestUpdatedMilliseconds: -5, now: now),
            String(localized: "2 sessions")
        )
    }

    // MARK: - Display titles

    func testDisplayTitleFallsBackForPlaceholdersOnly() {
        XCTAssertEqual(AidenWorkspaceProjection.displayTitle(""), "Untitled session")
        XCTAssertEqual(AidenWorkspaceProjection.displayTitle("   "), "Untitled session")
        XCTAssertEqual(AidenWorkspaceProjection.displayTitle("New session - ses_abc"), "Untitled session")
        XCTAssertEqual(AidenWorkspaceProjection.displayTitle("Fix login bug"), "Fix login bug")
    }

    // MARK: - Home search filter

    func testFilteredRecentMatchesTitleAgentAndDirectory() {
        let sessions = [
            makeSession(id: "1", directory: "/Users/x/api", updatedMilliseconds: 1, title: "Fix login", agent: "build"),
            makeSession(id: "2", directory: "/Users/x/web", updatedMilliseconds: 2, title: "Docs pass", agent: "write"),
        ]

        XCTAssertEqual(
            AidenWorkspaceProjection.filteredRecent(sessions, query: "").map(\.id),
            ["1", "2"]
        )
        XCTAssertEqual(
            AidenWorkspaceProjection.filteredRecent(sessions, query: "  login ").map(\.id),
            ["1"]
        )
        XCTAssertEqual(AidenWorkspaceProjection.filteredRecent(sessions, query: "WRITE").map(\.id), ["2"])
        XCTAssertEqual(AidenWorkspaceProjection.filteredRecent(sessions, query: "web").map(\.id), ["2"])
        XCTAssertTrue(AidenWorkspaceProjection.filteredRecent(sessions, query: "zzz").isEmpty)
    }

    // MARK: - Old-wording relative timestamps

    func testRelativeTimestampUsesOldWordingBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000_000)

        func text(secondsAgo: TimeInterval) -> String {
            AidenRelativeTimestamp.text(for: now.addingTimeInterval(-secondsAgo), now: now)
        }

        XCTAssertEqual(text(secondsAgo: 0), "just now")
        XCTAssertEqual(text(secondsAgo: 59), "just now")
        XCTAssertEqual(text(secondsAgo: 60), "1 min ago")
        XCTAssertEqual(text(secondsAgo: 119), "1 min ago")
        XCTAssertEqual(text(secondsAgo: 120), "2 mins ago")
        XCTAssertEqual(text(secondsAgo: 3_599), "59 mins ago")
        XCTAssertEqual(text(secondsAgo: 3_600), "1 hr ago")
        XCTAssertEqual(text(secondsAgo: 7_200), "2 hrs ago")
        XCTAssertEqual(text(secondsAgo: 86_399), "23 hrs ago")
        XCTAssertEqual(text(secondsAgo: 86_400), "1 day ago")
        XCTAssertEqual(text(secondsAgo: 172_800), "2 days ago")

        // Future timestamps clamp to "just now" instead of going negative.
        XCTAssertEqual(text(secondsAgo: -30), "just now")
    }
}

// MARK: - Navigation reconciliation

final class AidenWorkspaceNavigationTests: XCTestCase {
    func testReconciledSelectionKeepsValidAndReseedsOtherwise() {
        let ids = ["/a", "/b"]
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledSelection(current: "/b", directoryIDs: ids), "/b")
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledSelection(current: "/gone", directoryIDs: ids), "/a")
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledSelection(current: nil, directoryIDs: ids), "/a")
        XCTAssertNil(AidenWorkspaceNavigation.reconciledSelection(current: "/a", directoryIDs: []))
    }

    func testReconciledCompactPathSurvivesOnlyThroughTrailingValidDirectory() {
        let ids = ["/a", "/b"]
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledCompactPath(current: ["/a"], directoryIDs: ids), ["/a"])
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledCompactPath(current: ["/b"], directoryIDs: ids), ["/b"])
        // A stale trailing id collapses the whole path.
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledCompactPath(current: ["/gone"], directoryIDs: ids), [])
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledCompactPath(current: [], directoryIDs: ids), [])
        XCTAssertEqual(AidenWorkspaceNavigation.reconciledCompactPath(current: ["/x"], directoryIDs: []), [])
    }

    func testCompactPathEnteringFromSplitSeedsFromSelectedDirectory() {
        let ids = ["/a", "/b"]

        // An existing valid compact path wins over the split selection.
        XCTAssertEqual(
            AidenWorkspaceNavigation.compactPath(enteringFromSplit: true, current: ["/b"], selectedDirectoryID: "/a", directoryIDs: ids),
            ["/b"]
        )
        // Empty compact path falls back to the split selection when valid.
        XCTAssertEqual(
            AidenWorkspaceNavigation.compactPath(enteringFromSplit: true, current: [], selectedDirectoryID: "/a", directoryIDs: ids),
            ["/a"]
        )
        // Stale selections seed nothing.
        XCTAssertEqual(
            AidenWorkspaceNavigation.compactPath(enteringFromSplit: true, current: [], selectedDirectoryID: "/gone", directoryIDs: ids),
            []
        )
        // Not entering from split never seeds.
        XCTAssertEqual(
            AidenWorkspaceNavigation.compactPath(enteringFromSplit: false, current: [], selectedDirectoryID: "/a", directoryIDs: ids),
            []
        )
    }

    func testShellRouteExtractionProjectsDirectoryRoutesOnly() {
        let path: [AidenWorkspacesRoute] = [
            .allSessions,
            .directory("/a"),
            .session("ses_1"),
            .directory("/b"),
            .agents,
        ]
        XCTAssertEqual(AidenProductShellView.directoryIDs(in: path), ["/a", "/b"])
        XCTAssertEqual(AidenProductShellView.directoryIDs(in: [.session("ses_1")]), [])
        XCTAssertEqual(AidenWorkspacesRoute.directory("/a").directoryID, "/a")
        XCTAssertNil(AidenWorkspacesRoute.session("ses_1").directoryID)
    }
}

// MARK: - Per-installation navigation persistence

final class AidenProductNavigationStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "test.product-navigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testAreaSelectionPersistsPerInstallation() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AidenProductNavigationStore(defaults: defaults)
        XCTAssertEqual(store.area(for: "inst-1"), .workspaces)

        store.select(.settings, for: "inst-1")
        store.select(.workspaces, for: "inst-2")

        // Rehydrate from the same defaults.
        let reloaded = AidenProductNavigationStore(defaults: defaults)
        XCTAssertEqual(reloaded.area(for: "inst-1"), .settings)
        XCTAssertEqual(reloaded.area(for: "inst-2"), .workspaces)
        XCTAssertEqual(reloaded.area(for: nil), .workspaces)
        XCTAssertEqual(reloaded.area(for: "unknown"), .workspaces)
    }

    func testCompactPathPersistsAndTracksSelectedDirectory() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AidenProductNavigationStore(defaults: defaults)
        store.setCompactDirectoryPath(["/Users/x/api", "/Users/x/web"], for: "inst-1")

        let reloaded = AidenProductNavigationStore(defaults: defaults)
        XCTAssertEqual(
            reloaded.compactDirectoryPath(for: "inst-1"),
            ["/Users/x/api", "/Users/x/web"]
        )
        XCTAssertEqual(reloaded.selectedDirectory(for: "inst-1"), "/Users/x/web")

        store.setCompactPath([.directory("/Users/x/web"), .session("ses_1")], for: "inst-1")
        let withSession = AidenProductNavigationStore(defaults: defaults)
        XCTAssertEqual(withSession.compactRoutePath(for: "inst-1"), [.directory("/Users/x/web"), .session("ses_1")])
        XCTAssertEqual(withSession.selectedDirectory(for: "inst-1"), "/Users/x/web")

        // Clearing the path clears the trailing selection too.
        store.setCompactDirectoryPath([], for: "inst-1")
        let cleared = AidenProductNavigationStore(defaults: defaults)
        XCTAssertTrue(cleared.compactDirectoryPath(for: "inst-1").isEmpty)
        XCTAssertNil(cleared.selectedDirectory(for: "inst-1"))
    }

    func testUnsafeIDsAreRejectedWhileDirectoryPathsAreAccepted() {
        let (defaults, suiteName) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = AidenProductNavigationStore(defaults: defaults)

        // Directory paths are legal ids and must survive.
        store.setCompactDirectoryPath(["/Users/dev/My Project".replacingOccurrences(of: " ", with: "-")], for: "inst-1")
        XCTAssertEqual(store.compactDirectoryPath(for: "inst-1"), ["/Users/dev/My-Project"])

        store.select(.settings, for: "")
        store.select(.settings, for: String(repeating: "x", count: 161))
        store.select(.settings, for: "bad id")
        XCTAssertEqual(store.area(for: ""), .workspaces)
        XCTAssertEqual(store.area(for: String(repeating: "x", count: 161)), .workspaces)
        XCTAssertEqual(store.area(for: "bad id"), .workspaces)
        XCTAssertNil(store.selectedDirectory(for: nil))
        XCTAssertTrue(store.compactDirectoryPath(for: nil).isEmpty)
    }

    func testMalformedSnapshotStartsCleanInsteadOfCrashing() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        struct RawSnapshot: Codable {
            var areasByInstance: [String: String] = [:]
        }
        let raw = RawSnapshot(areasByInstance: [
            "good": "not-an-area",
        ])
        defaults.set(try JSONEncoder().encode(raw), forKey: "aiden.product-navigation.v2")

        // Unknown area raw values fail the whole decode, so the store starts
        // clean instead of crashing or half-loading state.
        let store = AidenProductNavigationStore(defaults: defaults)
        XCTAssertEqual(store.area(for: "good"), .workspaces)
    }
}
