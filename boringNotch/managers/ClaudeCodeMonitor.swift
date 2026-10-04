//
//  ClaudeCodeMonitor.swift
//  boringNotch
//
//  Tracks Claude Code sessions through Claude Code's hooks. Each hook runs a
//  one-line curl that POSTs the hook's JSON payload to a loopback-only HTTP
//  listener here, authenticated with a per-install token.
//

import Combine
import Defaults
import Foundation
import Network
import OSLog
import SwiftUI

enum ClaudeCodeSessionState: Equatable {
    case working
    case waiting(message: String)
    case done
    case idle
}

struct ClaudeCodeSession: Identifiable, Equatable {
    let id: String
    var project: String
    var state: ClaudeCodeSessionState
    var updatedAt: Date
}

@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    /// How long a finished session stays visible in the notch.
    static let doneVisibility: TimeInterval = 8
    static let endpointPath = "/claude-code"
    static let tokenHeader = "x-boring-notch-token"

    @Published private(set) var sessions: [ClaudeCodeSession] = []
    @Published private(set) var listenerError: String?
    @Published private(set) var isListening = false

    private static let log = Logger(subsystem: "theboringteam.boringnotch", category: "ClaudeCode")

    private var listener: NWListener?
    private var expiryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        _ = Self.token
        Defaults.publisher(keys: .enableClaudeCodeMonitor, .claudeCodePort)
            .sink { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Visible state

    /// Sessions worth showing in the closed notch, most urgent first.
    var visibleSessions: [ClaudeCodeSession] {
        let now = Date()
        return sessions
            .filter { session in
                switch session.state {
                case .working, .waiting: return true
                case .done: return now.timeIntervalSince(session.updatedAt) < Self.doneVisibility
                case .idle: return false
                }
            }
            .sorted { Self.priority($0.state) < Self.priority($1.state) }
    }

    var needsAttention: Bool {
        visibleSessions.contains { Self.wantsAttention($0.state) }
    }

    static func wantsAttention(_ state: ClaudeCodeSessionState) -> Bool {
        switch state {
        case .waiting, .done: return true
        case .working, .idle: return false
        }
    }

    private static func priority(_ state: ClaudeCodeSessionState) -> Int {
        switch state {
        case .waiting: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        }
    }

    // MARK: - Hook configuration

    static var token: String {
        if Defaults[.claudeCodeToken].isEmpty {
            Defaults[.claudeCodeToken] = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return Defaults[.claudeCodeToken]
    }

    static var hookCommand: String {
        // `Expect:` stops curl from waiting for a 100-continue on larger payloads.
        "curl -s -m 1 -X POST -H 'Content-Type: application/json' -H 'Expect:' -H '\(tokenHeader): \(token)' "
            + "--data-binary @- http://127.0.0.1:\(Defaults[.claudeCodePort])\(endpointPath) >/dev/null 2>&1 || true"
    }

    /// The `hooks` block to merge into ~/.claude/settings.json.
    static var hooksConfiguration: String {
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
        let hook: [String: Any] = ["type": "command", "command": hookCommand]
        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = ["hooks": [hook]]
            if event == "PreToolUse" { entry["matcher"] = "*" }
            hooks[event] = [entry]
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Listener

    private func restart() {
        listener?.cancel()
        listener = nil
        listenerError = nil
        isListening = false
        Self.log.info("restart: enabled=\(Defaults[.enableClaudeCodeMonitor]) port=\(Defaults[.claudeCodePort])")
        guard Defaults[.enableClaudeCodeMonitor] else {
            sessions.removeAll()
            return
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: Defaults[.claudeCodePort])) else {
            listenerError = String(localized: "Invalid port")
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in ClaudeCodeMonitor.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in ClaudeCodeMonitor.shared.listenerStateChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.log.error("listener creation failed: \(error.localizedDescription)")
            listenerError = error.localizedDescription
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        Self.log.info("listener state: \(String(describing: state))")
        switch state {
        case .ready:
            isListening = true
            listenerError = nil
        case .waiting(let error), .failed(let error):
            // `.waiting` is what a refused bind (e.g. port in use) usually looks like,
            // so surface it instead of silently never listening.
            isListening = false
            listenerError = error.localizedDescription
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer.append(data) }

                if let request = HTTPRequest(buffer) {
                    self.handle(request)
                    self.respond(on: connection, status: request.isAuthorized ? "204 No Content" : "403 Forbidden")
                } else if isComplete || error != nil || buffer.count > 4_194_304 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(on connection: NWConnection, status: String) {
        let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Hook events

    private func handle(_ request: HTTPRequest) {
        guard request.isAuthorized,
              request.method == "POST", request.path == Self.endpointPath,
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let sessionID = json["session_id"] as? String,
              let event = json["hook_event_name"] as? String
        else { return }

        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
        let newState: ClaudeCodeSessionState?
        switch event {
        case "SessionStart": newState = .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": newState = .working
        case "Notification": newState = .waiting(message: json["message"] as? String ?? "")
        case "Stop": newState = .done
        case "SessionEnd": newState = nil
        default: return
        }

        withAnimation(.smooth) {
            guard let newState else {
                sessions.removeAll { $0.id == sessionID }
                return
            }
            let previous = sessions.first { $0.id == sessionID }?.state
            let session = ClaudeCodeSession(id: sessionID, project: project, state: newState, updatedAt: Date())
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
            if previous != newState, Self.wantsAttention(newState) {
                BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .claudeCode)
            }
        }
        scheduleExpiry()
    }

    /// Republishes once finished sessions age out so the notch hides them.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.doneVisibility + 0.1))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth) { self.objectWillChange.send() }
        }
    }
}

/// Minimal HTTP/1.1 request parser: enough for a single small POST from curl.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var isAuthorized: Bool {
        guard let provided = headers[ClaudeCodeMonitor.tokenHeader] else { return false }
        return provided == Defaults[.claudeCodeToken] && !provided.isEmpty
    }

    /// Returns nil until the headers and the full body have arrived.
    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }

        self.method = String(requestLine[0])
        self.path = String(requestLine[1])
        self.headers = headers
        self.body = data[bodyStart..<(bodyStart + length)]
    }
}
