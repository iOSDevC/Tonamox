import Foundation
import Synchronization
import TonamoxCore

/// Admits a progress report at most every 100 ms, plus the final one, so SwiftUI is not flooded.
final class ProgressThrottle: Sendable {
    private let lastAdmitted = Mutex<ContinuousClock.Instant?>(nil)

    func admits(done: Int64, total: Int64) -> Bool {
        let now = ContinuousClock.now
        return lastAdmitted.withLock { last in
            guard done >= total || last.map({ now - $0 >= .milliseconds(100) }) ?? true else { return false }
            last = now
            return true
        }
    }
}

/// User-facing text for a failed download.
enum DownloadMessages {
    static let gated = String(localized: "This repo is gated. Accept its license on huggingface.co and add a read token.",
                              bundle: .module)

    @MainActor
    static func text(for error: any Error) -> String {
        if error is ModelIntegrityError {
            return String(localized: "The download did not match its published checksum and was deleted. Download it again.",
                          bundle: .module)
        }
        if let conflict = error as? DownloadConflictError {
            return conflict.errorDescription
                ?? String(localized: "Another download changed this file. Download it again.", bundle: .module)
        }
        guard let failure = error as? ModelDownloadError else {
            return String(localized: "\(error.localizedDescription) The partial file is kept; Resume continues from it.",
                          bundle: .module)
        }
        switch failure {
        case .unauthorized:
            return gated
        case .notFound:
            return String(localized: "File not found at main (renamed or removed).", bundle: .module)
        case .notFoundOrPrivate:
            return String(localized: "Repo not found, renamed or private. A private repo needs a read token with access to it.",
                          bundle: .module)
        case .insufficientSpace(let needed, let available):
            return String(localized: "Needs \(ByteText.text(needed)), \(ByteText.text(available)) free.", bundle: .module)
        case .sizeMismatch:
            return String(localized: "\(failure.errorDescription ?? "") Delete the partial file and retry.", bundle: .module)
        case .http, .incompleteRepo, .unsupported:
            return failure.errorDescription ?? String(localized: "Download failed.", bundle: .module)
        }
    }

    static func isGated(_ error: any Error) -> Bool {
        if case .unauthorized = error as? ModelDownloadError { return true }
        return false
    }
}

/// Byte counts for display.
@MainActor
enum ByteText {
    private static let fileStyle: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func text(_ bytes: Int64) -> String {
        fileStyle.string(fromByteCount: bytes)
    }
}
