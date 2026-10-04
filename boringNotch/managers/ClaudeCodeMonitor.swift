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

/// A tool call waiting for the user to allow or deny it from the notch. The hook's
/// HTTP request is held open until then; the decision is its response.
struct ClaudeCodePermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let project: String
    let toolName: String
    /// The most telling argument: the command, file, URL, or query.
    let detail: String
    let receivedAt = Date()
}

enum ClaudeCodePermissionDecision {
    case allow
    case deny
    /// Let Claude Code show its usual prompt in the terminal.
    case askInTerminal
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
    static let permissionPath = "/claude-code/permission"
    /// How long a request waits in the notch before falling back to the terminal
    /// prompt. Kept below the hook's own timeout so Claude Code gets an answer.
    static let permissionWait: TimeInterval = 280
    static let permissionHookTimeout = 300
    static let tokenHeader = "x-boring-notch-token"

    @Published private(set) var sessions: [ClaudeCodeSession] = []
    @Published private(set) var listenerError: String?
    @Published private(set) var isListening = false
    /// Oldest first; the notch shows the first one.
    @Published private(set) var pendingPermissions: [ClaudeCodePermissionRequest] = []
    private var permissionConnections: [UUID: NWConnection] = [:]
    private var permissionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var holdsNotchOpen = false

    private static let log = Logger(subsystem: "theboringteam.boringnotch", category: "ClaudeCode")

    private var listener: NWListener?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var expiryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        _ = Self.token
        // Both keys emit their initial value at launch; coalesce them so the listener
        // is started once instead of twice in a row (the second bind would race the first).
        Defaults.publisher(keys: .enableClaudeCodeMonitor, .claudeCodePort)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
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
        // Permission prompts wait for an answer from the notch, so this one is an
        // HTTP hook whose response carries the decision. If the app isn't running,
        // the request fails and Claude Code asks in the terminal as usual.
        hooks["PermissionRequest"] = [[
            "matcher": "*",
            "hooks": [[
                "type": "http",
                "url": "http://127.0.0.1:\(Defaults[.claudeCodePort])\(permissionPath)",
                "headers": [tokenHeader: token],
                "timeout": permissionHookTimeout,
            ] as [String: Any]],
        ] as [String: Any]]
        let data = (try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Listener

    private func restart() {
        resolveAllPermissions(.askInTerminal)
        retryTask?.cancel()
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
            retryCount = 0
        case .waiting(let error), .failed(let error):
            // `.waiting` is what a refused bind (e.g. port in use) usually looks like,
            // so surface it instead of silently never listening, and retry a few
            // times in case the port is only briefly held (e.g. right after a relaunch).
            isListening = false
            listenerError = error.localizedDescription
            scheduleRetry()
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    private func scheduleRetry() {
        guard retryCount < 5, retryTask == nil || retryTask?.isCancelled == true else { return }
        retryCount += 1
        let delay = Double(retryCount)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isListening else { return }
            self.retryTask = nil
            Self.log.info("retrying listener (attempt \(self.retryCount))")
            let attempts = self.retryCount
            self.restart()
            self.retryCount = attempts
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
                    if request.isAuthorized, request.method == "POST", request.path == Self.permissionPath {
                        self.enqueuePermission(request, on: connection)
                        return
                    }
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

    private func respond(on connection: NWConnection, status: String, json: Data? = nil) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(json?.count ?? 0)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        var response = Data((head + "\r\n").utf8)
        if let json { response.append(json) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Permission requests

    private func enqueuePermission(_ request: HTTPRequest, on connection: NWConnection) {
        guard Defaults[.claudeCodeApprovalsInNotch],
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let toolName = json["tool_name"] as? String else {
            respond(on: connection, status: "204 No Content")
            return
        }
        let cwd = json["cwd"] as? String
        let permission = ClaudeCodePermissionRequest(
            sessionID: json["session_id"] as? String ?? "",
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code",
            toolName: Self.displayName(forTool: toolName),
            detail: Self.detail(for: toolName, input: json["tool_input"] as? [String: Any] ?? [:], cwd: cwd)
        )
        permissionConnections[permission.id] = connection
        withAnimation(.smooth) { pendingPermissions.append(permission) }
        updateNotchHold()

        // Claude Code gives up on the hook if the session is interrupted; drop the
        // request when its connection goes away so the notch doesn't keep asking.
        watchForDisconnect(connection, request: permission.id)
        permissionTimeouts[permission.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.permissionWait))
            guard !Task.isCancelled else { return }
            self?.resolve(permission.id, with: .askInTerminal)
        }
    }

    private func watchForDisconnect(_ connection: NWConnection, request id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.permissionConnections[id] != nil else { return }
                if isComplete || error != nil {
                    self.permissionConnections[id] = nil
                    connection.cancel()
                    self.resolve(id, with: .askInTerminal)
                } else {
                    self.watchForDisconnect(connection, request: id)
                }
            }
        }
    }

    func resolve(_ id: UUID, with decision: ClaudeCodePermissionDecision) {
        permissionTimeouts.removeValue(forKey: id)?.cancel()
        if let connection = permissionConnections.removeValue(forKey: id) {
            switch decision {
            case .allow, .deny:
                var body: [String: Any] = ["behavior": decision == .allow ? "allow" : "deny"]
                if decision == .deny { body["message"] = "Denied from the notch." }
                let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
                respond(on: connection, status: "200 OK", json: try? JSONSerialization.data(withJSONObject: output))
            case .askInTerminal:
                respond(on: connection, status: "204 No Content")
            }
        }
        if let request = pendingPermissions.first(where: { $0.id == id }), decision != .askInTerminal,
           let index = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            sessions[index].state = .working
            sessions[index].updatedAt = Date()
        }
        withAnimation(.smooth) { pendingPermissions.removeAll { $0.id == id } }
        updateNotchHold()
    }

    private func resolveAllPermissions(_ decision: ClaudeCodePermissionDecision) {
        for request in pendingPermissions { resolve(request.id, with: decision) }
    }

    /// Keeps the notch from closing under the pointer while a request is shown.
    private func updateNotchHold() {
        let hold = !pendingPermissions.isEmpty
        guard hold != holdsNotchOpen else { return }
        holdsNotchOpen = hold
        if hold {
            SharingStateManager.shared.beginInteraction()
        } else {
            SharingStateManager.shared.endInteraction()
        }
    }

    private static func displayName(forTool name: String) -> String {
        // MCP tools are named mcp__server__tool.
        let parts = name.components(separatedBy: "__")
        if parts.count == 3, parts[0] == "mcp" { return "\(parts[2]) (\(parts[1]))" }
        return name
    }

    private static func detail(for tool: String, input: [String: Any], cwd: String?) -> String {
        func relative(_ path: String) -> String {
            guard let cwd, path.hasPrefix(cwd + "/") else { return path }
            return String(path.dropFirst(cwd.count + 1))
        }
        switch tool {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            return relative(path)
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(String(decoding: data, as: UTF8.self).prefix(400))
        }
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
