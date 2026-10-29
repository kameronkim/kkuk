import Foundation
import Darwin
import KkukCore

extension FinderCompressionRequest {
    var title: String {
        guard let first = inputs.first else { return L10n.text("Kkuk") }
        return inputCount == 1 ? first.lastPathComponent : L10n.format("%@ and %d more", first.lastPathComponent, inputCount - 1)
    }
}

/// Display formatting never mutates a task or exposes engine diagnostics.
enum TaskPresentation {
    static func userFacingError(_ failure: Error) -> String {
        // Keep engine transcripts, file paths and error codes out of the interface.
        if let error = failure as? KkukError {
            let key: String
            switch error {
            case .inputMissing: key = "Choose a file or folder to compress."
            case .differentInputLocations: key = "Choose items in the same folder."
            case .systemRoot: key = "Choose a file or folder instead of the system root."
            case .unsupportedFileName: key = "Rename files containing line breaks, then choose the input again."
            case .unsupportedInput: key = "Choose a regular file or folder."
            case .engineUnavailable: key = "Reinstall the app, then try again."
            case .unsafeDestination: key = "Move the source to a private folder, then try again."
            case .insufficientMemory: key = "Close other apps, then try again."
            case .sourceChanged: key = "Finish making changes to the source, then compress again."
            case .archiveContentsMismatch: key = "Choose the source again, then compress."
            case .engineFailed: key = "Check the source and destination, then try again."
            case .cancelled: key = "Canceled"
            }
            return L10n.text(key)
        }
        let error = failure as NSError
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ENOSPC, EDQUOT: return L10n.text("Free up disk space, then try again.")
            case EACCES, EPERM: return L10n.text("Check access permissions for the source and destination.")
            case ENOENT, ENOTDIR: return L10n.text("Choose the source file or folder again.")
            default: break
            }
        }
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return L10n.text("Free up disk space, then try again.")
            case .fileReadNoPermission, .fileWriteNoPermission: return L10n.text("Check access permissions for the source and destination.")
            case .fileNoSuchFile, .fileReadNoSuchFile: return L10n.text("Choose the source file or folder again.")
            default: break
            }
        }
        return L10n.text("Check the source and destination, then try again.")
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    static func resultDetail(_ result: ArchiveResult) -> String {
        let change: String
        if result.originalBytes == 0 {
            change = L10n.text("Empty item archived")
        } else if result.archiveBytes > result.originalBytes {
            change = L10n.text("Size increased slightly")
        } else {
            let percent = (1 - Double(result.archiveBytes) / Double(result.originalBytes)) * 100
            change = L10n.format("%.1f%% smaller", percent)
        }
        return "\(bytes(result.originalBytes)) → \(bytes(result.archiveBytes)) · \(change)"
    }
}
