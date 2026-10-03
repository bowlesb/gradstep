import Foundation
import ScienceReaderCore

struct LibraryCommandDelivery: Sendable {
    let attempt: LibraryCommandAttempt
    let response: LibraryCommandResponse
}

protocol LibraryCommandTransport: Sendable {
    /// Sends the exact durable request. This method does not create or retry
    /// operations; the queue records possible submission before calling it.
    func libraryCommand(_ attempt: LibraryCommandAttempt) async throws -> LibraryCommandDelivery
}
