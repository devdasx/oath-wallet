import OathDiagnostics

private func availabilityStatus(_ code: Int) -> Bool {
    code == 408 || code == 429 || (500...599).contains(code)
}

// Case-based admission filtering only; provider retries and thrown errors are unchanged.

extension AnkrError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension SolanaError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005), .rpc(-32019): return true
        default: return false
        }
    }
}

extension AptosError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension TonError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension TronError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension StellarError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport, .indexUnavailable: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension XrplError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc("tooBusy"), .rpc("slowDown"), .rpc("noNetwork"): return true
        default: return false
        }
    }
}

extension NearError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension SuiError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .resourceExhausted, .checkpointUnavailable: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension ThorchainError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .rateLimited: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension EVMSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension SolanaSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension AptosSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension TonSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension TronSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension StellarSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension XrplSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc("tooBusy"), .rpc("slowDown"), .rpc("noNetwork"): return true
        default: return false
        }
    }
}

extension NearSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension SuiSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension ThorchainSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}

extension ArcSendError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .transport: return true
        case .http(let status): return availabilityStatus(status)
        case .rpc(429), .rpc(-32005): return true
        default: return false
        }
    }
}

extension TokenDiscoveryError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .unavailable: return true
        case .http(let status): return availabilityStatus(status)
        default: return false
        }
    }
}
