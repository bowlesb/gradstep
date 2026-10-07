import Foundation
import Testing
@testable import ScienceReaderCore

struct ReaderDeliveryTests {
    @Test func onlyKnownSameOriginMemberTransportsAreAccepted() throws {
        let origin = URL(string: "https://fixture.supabase.co")!
        let query = "grant=" + String(repeating: "a", count: 64) + "&member=34000000-0000-0000-0000-000000000001"
        let bounded = "https://fixture.supabase.co/functions/v1/reader-member?" + query
        #expect(try ReaderMemberTransport.validated(URL(string: bounded)!, backendURL: origin) == .bounded)
        #expect(try ReaderMemberTransport.validated(URL(string: "https://fixture.supabase.co/storage/v1/object/sign/paper-assets/reader/file?token=legacy")!, backendURL: origin) == .signedStorage)
        for invalid in [bounded.replacingOccurrences(of: "fixture.supabase.co", with: "other.supabase.co"),
                        bounded.replacingOccurrences(of: "https:", with: "http:"),
                        bounded.replacingOccurrences(of: "fixture.supabase.co", with: "user@fixture.supabase.co"),
                        bounded.replacingOccurrences(of: "fixture.supabase.co", with: "fixture.supabase.co:8443"),
                        bounded + "&grant=duplicate", bounded + "#fragment",
                        bounded.replacingOccurrences(of: "reader-member?", with: "other-function?"),
                        bounded.replacingOccurrences(of: String(repeating: "a", count: 64), with: "short")] {
            #expect(throws: ReaderError.self) { try ReaderMemberTransport.validated(URL(string: invalid)!, backendURL: origin) }
        }
    }
}
