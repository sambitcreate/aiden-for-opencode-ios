import ActivityKit
import Foundation

/// Bounded last-known state for one running OpenCode session. The attributes
/// carry stable identity only — no credentials, endpoints, or prompt content.
struct AgentRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sessionID: String
        var sessionTitle: String
        var status: AgentRunActivityStatus
        var currentActivity: String
        var responseExcerpt: String
        var startedAt: Date
        var updatedAt: Date
        var isStale: Bool
        var isFinal: Bool
        var errorSummary: String?

        init(
            sessionID: String,
            sessionTitle: String,
            status: AgentRunActivityStatus,
            currentActivity: String,
            responseExcerpt: String = "",
            startedAt: Date,
            updatedAt: Date,
            isStale: Bool = false,
            isFinal: Bool = false,
            errorSummary: String? = nil
        ) {
            self.sessionID = sessionID
            self.sessionTitle = AgentRunActivitySanitizer.sessionTitle(sessionTitle)
            self.status = status
            self.currentActivity = AgentRunActivitySanitizer.activityLine(currentActivity)
            self.responseExcerpt = AgentRunActivitySanitizer.responseExcerpt(responseExcerpt)
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.isStale = isStale
            self.isFinal = isFinal
            self.errorSummary = errorSummary.map(AgentRunActivitySanitizer.activityLine)
        }

        var stateText: String { currentActivity }

        var isRunning: Bool {
            !isFinal && status != .complete && status != .failed && status != .cancelled
        }

        /// Freeze the Live Activity timer when the run is over, last-known, or
        /// the ActivityKit content itself is stale.
        func timerPauseTime(activityStale: Bool) -> Date? {
            isFinal || isStale || activityStale ? updatedAt : nil
        }

        var timerPauseTime: Date? {
            timerPauseTime(activityStale: false)
        }
    }

    /// Installation id (`OpenCodeInstallation.id`) the session belongs to.
    var instanceID: String
    var sessionID: String
    var sessionTitle: String
    /// Optional user-visible server label; display only.
    var serverName: String?
    var startedAt: Date

    init(
        instanceID: String,
        sessionID: String,
        sessionTitle: String,
        serverName: String? = nil,
        startedAt: Date
    ) {
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.sessionTitle = AgentRunActivitySanitizer.sessionTitle(sessionTitle)
        self.serverName = serverName.map(AgentRunActivitySanitizer.serverName)
        self.startedAt = startedAt
    }
}

enum AgentRunActivityStatus: String, Codable, Hashable, CaseIterable {
    case starting
    case thinking
    case usingTool
    case searchingFiles
    case readingFiles
    case runningCommand
    case responding
    case waitingForApproval
    case complete
    case failed
    case cancelled

    var title: String {
        switch self {
        case .starting:
            String(localized: "Starting")
        case .thinking:
            String(localized: "Thinking")
        case .usingTool:
            String(localized: "Using tool")
        case .searchingFiles:
            String(localized: "Searching files")
        case .readingFiles:
            String(localized: "Reading files")
        case .runningCommand:
            String(localized: "Running command")
        case .responding:
            String(localized: "Responding")
        case .waitingForApproval:
            String(localized: "Waiting for approval")
        case .complete:
            String(localized: "Complete")
        case .failed:
            String(localized: "Failed")
        case .cancelled:
            String(localized: "Cancelled")
        }
    }

    var compactTitle: String {
        switch self {
        case .starting:
            String(localized: "Start")
        case .thinking:
            String(localized: "Think")
        case .usingTool:
            String(localized: "Tool")
        case .searchingFiles:
            String(localized: "Search")
        case .readingFiles:
            String(localized: "Files")
        case .runningCommand:
            String(localized: "Cmd")
        case .responding:
            String(localized: "Reply")
        case .waitingForApproval:
            String(localized: "Approve")
        case .complete:
            String(localized: "Done")
        case .failed:
            String(localized: "Fail")
        case .cancelled:
            String(localized: "Stop")
        }
    }
}

enum AgentRunActivityToolKind: Equatable {
    case generic(String)
    case search
    case files
    case command
}

/// Clamps every string written into a Live Activity to a single bounded line.
enum AgentRunActivitySanitizer {
    static let maximumSessionTitleCharacters = 42
    static let maximumActivityCharacters = 64
    static let maximumStateTextCharacters = maximumActivityCharacters
    static let maximumExcerptCharacters = 140
    static let maximumToolLabelCharacters = 28
    static let maximumServerNameCharacters = 40

    static func sessionTitle(_ rawValue: String) -> String {
        let normalized = normalizedSingleLine(rawValue)
        return trimmed(
            normalized.isEmpty ? String(localized: "OpenCode session") : normalized,
            limit: maximumSessionTitleCharacters
        )
    }

    static func activityLine(_ rawValue: String) -> String {
        trimmed(normalizedSingleLine(rawValue), limit: maximumActivityCharacters)
    }

    static func stateText(_ rawValue: String) -> String {
        activityLine(rawValue)
    }

    static func responseExcerpt(_ rawValue: String) -> String {
        trimmed(normalizedSingleLine(rawValue), limit: maximumExcerptCharacters)
    }

    static func serverName(_ rawValue: String) -> String {
        let normalized = normalizedSingleLine(rawValue)
        return trimmed(normalized.isEmpty ? fallbackServerName : normalized, limit: maximumServerNameCharacters)
    }

    static func toolKind(name: String?) -> AgentRunActivityToolKind {
        let label = toolLabel(name)
        let lowercasedName = (name ?? "").lowercased()
        let lowercasedLabel = label.lowercased()
        let haystack = "\(lowercasedName) \(lowercasedLabel)"

        if haystack.contains("shell")
            || haystack.contains("bash")
            || haystack.contains("terminal")
            || haystack.contains("exec")
            || haystack.contains("command")
            || haystack.contains("xcodebuild")
            || haystack.contains("simctl") {
            return .command
        }

        if haystack.contains("search")
            || haystack.contains("grep")
            || haystack.contains("ripgrep")
            || haystack.contains("rg")
            || haystack.contains("find") {
            return .search
        }

        if haystack.contains("read")
            || haystack.contains("file")
            || haystack.contains("list")
            || haystack.contains("glob")
            || haystack.contains("workspace") {
            return .files
        }

        return .generic(label)
    }

    static func toolLabel(_ rawValue: String?) -> String {
        let fallback = String(localized: "tool")
        guard let rawValue else { return fallback }

        let noPathSeparators = rawValue
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? rawValue
        let words = noPathSeparators
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let normalized = normalizedSingleLine(words)
        return trimmed(normalized.isEmpty ? fallback : normalized, limit: maximumToolLabelCharacters)
    }

    private static var fallbackServerName: String { "OpenCode" }

    private static func normalizedSingleLine(_ rawValue: String) -> String {
        rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 3 else {
            return String(value.prefix(limit))
        }

        let endIndex = value.index(value.startIndex, offsetBy: limit - 3)
        return String(value[..<endIndex]) + "..."
    }
}

enum AgentRunElapsedTimeFormatter {
    static func label(startedAt: Date, updatedAt: Date) -> String {
        let elapsedSeconds = max(0, Int(updatedAt.timeIntervalSince(startedAt).rounded(.down)))
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Maps chat-stream milestones onto Live Activity phase + activity line.
enum AgentRunActivityProgress {
    static func snapshot(
        waitingForApproval: Bool,
        runningToolName: String?,
        hasLiveText: Bool,
        isThinking: Bool
    ) -> (status: AgentRunActivityStatus, activity: String) {
        if waitingForApproval {
            return (.waitingForApproval, String(localized: "Waiting for approval"))
        }
        if let runningToolName {
            switch AgentRunActivitySanitizer.toolKind(name: runningToolName) {
            case .command:
                return (.runningCommand, String(localized: "Running command"))
            case .search:
                return (.searchingFiles, String(localized: "Searching files"))
            case .files:
                return (.readingFiles, String(localized: "Reading files"))
            case .generic(let label):
                return (.usingTool, String(localized: "Using \(label)"))
            }
        }
        if hasLiveText {
            return (.responding, String(localized: "Writing response"))
        }
        if isThinking {
            return (.thinking, String(localized: "Thinking"))
        }
        return (.starting, String(localized: "Starting response"))
    }
}

enum AgentRunActivityStateReducer {
    static func initialState(
        sessionID: String,
        sessionTitle: String,
        startedAt: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            status: .starting,
            currentActivity: String(localized: "Starting response"),
            startedAt: startedAt,
            updatedAt: startedAt
        )
    }

    static func applying(
        status: AgentRunActivityStatus,
        activity: String,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: status,
            currentActivity: activity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: state.isStale,
            isFinal: state.isFinal,
            errorSummary: state.errorSummary
        )
    }

    static func toolStarted(
        name: String?,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        let snapshot = AgentRunActivityProgress.snapshot(
            waitingForApproval: false,
            runningToolName: name,
            hasLiveText: false,
            isThinking: false
        )
        return applying(status: snapshot.status, activity: snapshot.activity, state: state, now: now)
    }

    static func stale(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: state.status,
            currentActivity: state.currentActivity.isEmpty
                ? String(localized: "Latest status shown")
                : state.currentActivity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: true,
            isFinal: state.isFinal,
            errorSummary: state.errorSummary
        )
    }

    static func final(
        status: AgentRunActivityStatus,
        activity: String,
        state: AgentRunActivityAttributes.ContentState,
        errorSummary: String? = nil,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: status,
            currentActivity: activity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: false,
            isFinal: true,
            errorSummary: errorSummary
        )
    }
}
