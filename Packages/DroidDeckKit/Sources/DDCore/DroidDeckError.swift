import Foundation

/// User-facing errors with a recovery suggestion. Messages must never contain secrets.
public struct DroidDeckError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case sdkMissing, toolMissing, toolFailed, invalidConfiguration, deviceNotFound, deviceBusy
        case launchFailed, bootTimeout, adbUnavailable, installFailed, fileOperationFailed
        case unsupported, cancelled, network, persistence, permission
    }

    public var kind: Kind
    public var message: String
    public var recovery: String?
    /// Technical detail (tool output) for the diagnostics view; already redacted.
    public var detail: String?

    public init(_ kind: Kind, _ message: String, recovery: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.recovery = recovery
        self.detail = detail
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }

    public static func unsupported(_ capability: RuntimeCapability, reason: String?) -> DroidDeckError {
        DroidDeckError(.unsupported, "\(capability.displayName) is not available.", recovery: reason)
    }

    public static let cancelled = DroidDeckError(.cancelled, "The operation was cancelled.")
}
