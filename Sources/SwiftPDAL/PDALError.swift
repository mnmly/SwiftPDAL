//
//  PDALError.swift
//  SwiftPDAL
//
//  Portable PDAL error codes. Extracted from SwiftPDAL.swift (which is Metal-
//  backed and compiled out on Windows) so the convert path — used by PDAL2COPC
//  on every platform — can reference these codes.
//

/// Error codes for PDAL operations
public enum PDALError: Int, Sendable {
    case ok = 0
    case notImplemented = -1
    case pdalError = -2
    case stdException = -3
    case createStageFailed = -4
    case noPoints = -5
    case unknown = -6
    case invalidCallback = -7
    case invalidChunkSize = -8
    case invalidViewPointer = -9
    case allocFailed = -10

    public var message: String {
        switch self {
        case .ok: return "OK"
        case .notImplemented: return "Not implemented on this platform"
        case .pdalError: return "PDAL error occurred"
        case .stdException: return "Standard exception occurred"
        case .createStageFailed: return "Failed to create stage"
        case .noPoints: return "No points in view"
        case .unknown: return "Unknown error"
        case .invalidCallback: return "Invalid callback"
        case .invalidChunkSize: return "Invalid chunk size"
        case .invalidViewPointer: return "Invalid view pointer"
        case .allocFailed: return "Memory allocation failed"
        }
    }
}
