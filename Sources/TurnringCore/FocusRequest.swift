import Foundation

public struct FocusRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case focus
        case resume
    }

    public var requestID: String
    public var provider: AgentProvider
    public var sessionID: String
    public var shellPID: Int32?
    public var cwd: String
    public var executablePath: String?
    public var action: Action
    public var createdAt: Date

    public init(
        requestID: String,
        provider: AgentProvider,
        sessionID: String,
        shellPID: Int32?,
        cwd: String,
        executablePath: String?,
        action: Action,
        createdAt: Date = Date()
    ) {
        self.requestID = requestID
        self.provider = provider
        self.sessionID = sessionID
        self.shellPID = shellPID
        self.cwd = cwd
        self.executablePath = executablePath
        self.action = action
        self.createdAt = createdAt
    }
}
