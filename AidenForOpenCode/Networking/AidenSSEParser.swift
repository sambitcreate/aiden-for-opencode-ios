import Foundation

enum AidenSSEParserError: Error, Equatable {
    /// A single SSE frame exceeded the configured byte ceiling.
    case frameTooLarge
}

/// Line-oriented server-sent-events frame parser shared by the OpenCode global
/// (`/api/event`) and per-session (`/api/session/:id/event`) streams.
///
/// Tolerant by design: `:` comment heartbeat frames are swallowed, multi-line
/// `data:` fields are joined with `\n`, CR/LF/CRLF terminators are accepted,
/// and unknown SSE fields are ignored (the V2 envelope carries `id`/`type`
/// inside the JSON `data` payload, so no SSE-level bookkeeping is needed).
/// The only failure mode is a frame that exceeds the byte ceiling.
struct AidenSSEParser: Sendable {
    private let maximumFrameBytes: Int

    private var dataLines: [String] = []
    private var frameBytes = 0

    init(maximumFrameBytes: Int = 8_388_608) {
        self.maximumFrameBytes = max(maximumFrameBytes, 1024)
    }

    /// Feed one line (without its terminator). Returns the joined `data`
    /// payload once a blank line closes the frame; `nil` while the frame is
    /// still open or the line was ignorable (comment, unknown field).
    mutating func consume(line: String) throws -> String? {
        // Defensively drop a trailing CR so CRLF streams behave like LF.
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        frameBytes += line.utf8.count + 1
        guard frameBytes <= maximumFrameBytes else {
            throw AidenSSEParserError.frameTooLarge
        }
        guard !line.isEmpty else { return try finishFrame() }
        guard !line.hasPrefix(":") else { return nil }

        let (field, value) = Self.splitField(line)
        switch field {
        case "data":
            dataLines.append(String(value))
        default:
            // `event`, `retry`, and unknown fields carry no V2 semantics.
            break
        }
        return nil
    }

    /// Flush a frame that was still open when the stream ended.
    mutating func finish() throws -> String? {
        guard frameBytes > 0 else { return nil }
        return try finishFrame()
    }

    private mutating func finishFrame() throws -> String? {
        defer { reset() }
        guard !dataLines.isEmpty else { return nil }
        return dataLines.joined(separator: "\n")
    }

    private mutating func reset() {
        dataLines.removeAll(keepingCapacity: true)
        frameBytes = 0
    }

    /// Splits `field:value` at the first colon and strips one optional leading
    /// space from the value, per the SSE field grammar.
    private static func splitField(_ line: String) -> (field: Substring, value: Substring) {
        guard let separator = line.firstIndex(of: ":") else {
            return (field: line[...], value: "")
        }
        let field = line[..<separator]
        var start = line.index(after: separator)
        if start < line.endIndex, line[start] == " " {
            start = line.index(after: start)
        }
        return (field: field, value: line[start...])
    }
}
