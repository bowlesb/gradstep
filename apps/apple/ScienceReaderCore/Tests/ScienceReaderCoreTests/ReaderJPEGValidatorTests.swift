import Foundation
import Testing
@testable import ScienceReaderCore

struct ReaderJPEGValidatorTests {
    // 12×8 baseline JPEG with JFIF, EXIF and Photoshop segments (macOS sips).
    private let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAADKADAAQAAAABAAAACAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgACAAMAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICBAICBAYEBAQGCAYGBgYICggICAgICgwKCgoKCgoMDAwMDAwMDA4ODg4ODhAQEBAQEhISEhISEhISEv/bAEMBAwMDBQQFCAQECBMNCw0TExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTE//dAAQAAf/aAAwDAQACEQMRAD8A8Xooor8/P66P/9k=")!
    private let frame = 0x9c // SOF0 marker offset in this fixture

    @Test func completeBaselineFrameIsAccepted() throws {
        try ReaderJPEGValidator.validate(jpeg, width: 12, height: 8)
    }

    @Test func dimensionsMustMatchTheManifest() {
        for (width, height) in [(11, 8), (12, 9), (0, 8), (8193, 8)] {
            #expect(throws: ReaderBundleError.invalidResource) { try ReaderJPEGValidator.validate(jpeg, width: width, height: height) }
        }
    }

    @Test func truncatedTrailingOrUnsupportedStreamsAreRefused() {
        var lossless = jpeg; lossless[frame + 1] = 0xc3
        var arithmetic = jpeg; arithmetic[frame + 1] = 0xc9
        var twelveBit = jpeg; twelveBit[frame + 4] = 12
        var noSOI = jpeg; noSOI[1] = 0xd9
        let broken: [Data] = [jpeg.prefix(jpeg.count - 2), jpeg.prefix(jpeg.count - 40), jpeg + Data([0]),
                              jpeg + Data([0xff, 0xd9]), lossless, arithmetic, twelveBit, noSOI, Data(), jpeg.prefix(frame)]
        for bytes in broken {
            #expect(throws: ReaderBundleError.invalidResource) { try ReaderJPEGValidator.validate(bytes, width: 12, height: 8) }
        }
    }
}
