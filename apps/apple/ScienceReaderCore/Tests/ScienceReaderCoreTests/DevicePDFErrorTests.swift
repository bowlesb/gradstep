import JavaScriptCore
import XCTest
@testable import ScienceReaderCore

@available(macOS 15.0, iOS 18.0, *)
final class DevicePDFErrorTests: XCTestCase {
    /// Exercise the actual JavaScriptCore exception callback, not a Swift dictionary stand-in.
    private func thrown(_ script: String) throws -> (DevicePDFRoute.Failure, JSContext, Int) {
        let context = try XCTUnwrap(JSContext())
        let reader = try XCTUnwrap(DevicePDFRoute.exceptionDetailsReader(in: context))
        var failure: DevicePDFRoute.Failure?
        var callbacks = 0
        context.exceptionHandler = { _, exception in
            callbacks += 1
            guard failure == nil else { return }
            failure = DevicePDFRoute.converterFailure(exception, using: reader)
        }
        defer { context.exceptionHandler = nil }
        context.evaluateScript(script)
        return (try XCTUnwrap(failure), context, callbacks)
    }

    func testStructuredCompilerFailurePreservesItsCodeAndBoundedDetail() throws {
        for code in ["device_pdf_internal", "utf8_invalid"] {
            let (failure, _, callbacks) = try thrown("throw {code:'\(code)', detail:'tagger: a line could not be read'}")
            XCTAssertEqual(failure, .converter(code: code, message: "tagger: a line could not be read"))
            XCTAssertEqual(callbacks, 1)
        }
    }

    func testStandardJavaScriptErrorsKeepTheirOwnMessage() throws {
        for expression in ["new Error('native inference failed')", "new TypeError('native inference failed')"] {
            let (failure, _, callbacks) = try thrown("throw \(expression)")
            XCTAssertEqual(failure, .converter(code: "exception", message: "native inference failed"))
            XCTAssertEqual(callbacks, 1)
        }
    }

    func testDetailsHaveTheCompilerUTF16BoundAndDoNotIncludeStacks() throws {
        let (failure, _, _) = try thrown("throw {code:'tagger_output', detail:'😀'.repeat(300), stack:'private source path'}")
        XCTAssertEqual(failure, .converter(code: "tagger_output", message: String(repeating: "😀", count: 100)))
        if case .converter(_, let message) = failure { XCTAssertEqual(message.utf16.count, 200) }
        let (plain, _, _) = try thrown("throw 'x'.repeat(500)")
        XCTAssertEqual(plain, .converter(code: "exception", message: String(repeating: "x", count: 200)))
    }

    func testMalformedCodesAndDetailsAreNotCoerced() throws {
        let (failure, context, callbacks) = try thrown("""
        var coerced = 0;
        const hostile = {toString(){coerced++; throw new Error('wrong failure')}};
        throw {code:hostile, detail:hostile, message:'usable message'};
        """)
        XCTAssertEqual(failure, .converter(code: "exception", message: "usable message"))
        XCTAssertEqual(context.objectForKeyedSubscript("coerced")?.toInt32(), 0)
        XCTAssertEqual(callbacks, 1)
        for code in ["bad code", "BadCode", "bad-123", String(repeating: "a", count: 81)] {
            let context = try XCTUnwrap(JSContext())
            let reader = DevicePDFRoute.exceptionDetailsReader(in: context)
            let value = try XCTUnwrap(JSValue(object: ["code": code, "detail": "detail survives"], in: context))
            XCTAssertEqual(DevicePDFRoute.converterFailure(value, using: reader), .converter(code: "exception", message: "detail survives"))
        }
    }

    func testDiagnosticExtractionDoesNotInvokeExceptionGettersOrToString() throws {
        let context = try XCTUnwrap(JSContext())
        let reader = try XCTUnwrap(DevicePDFRoute.exceptionDetailsReader(in: context))
        var failure: DevicePDFRoute.Failure?
        var callbacks = 0
        var accessesBefore: Int32?, accessesAfter: Int32?
        context.exceptionHandler = { _, exception in
            callbacks += 1
            // JavaScriptCore can coerce a thrown value before its native callback. The extractor must not add
            // another getter/coercion or turn one failure into a recursive callback.
            accessesBefore = context.objectForKeyedSubscript("accessed")?.toInt32()
            failure = DevicePDFRoute.converterFailure(exception, using: reader)
            accessesAfter = context.objectForKeyedSubscript("accessed")?.toInt32()
        }
        defer { context.exceptionHandler = nil }
        context.evaluateScript("""
        var accessed = 0;
        throw {
          get code(){accessed++; throw new Error('code getter')},
          get detail(){accessed++; throw new Error('detail getter')},
          get message(){accessed++; throw new Error('message getter')},
          get stack(){accessed++; throw new Error('stack getter')},
          toString(){accessed++; throw new Error('toString')}
        };
        """)
        XCTAssertEqual(failure, .converter(code: "exception", message: ""))
        XCTAssertNotNil(accessesBefore)
        XCTAssertEqual(accessesAfter, accessesBefore)
        XCTAssertEqual(callbacks, 1, "diagnostic extraction must not cause nested native exception callbacks")
    }

    func testThrowingProxyDescriptorDoesNotReplaceTheOriginalFailure() throws {
        let (failure, context, callbacks) = try thrown("""
        var trapped = 0;
        throw new Proxy({}, {getOwnPropertyDescriptor(){trapped++; throw new Error('nested diagnostic failure')}});
        """)
        XCTAssertEqual(failure, .converter(code: "exception", message: ""))
        XCTAssertEqual(context.objectForKeyedSubscript("trapped")?.toInt32(), 1)
        XCTAssertEqual(callbacks, 1)
    }

    func testNativeDiagnosticHelpersAreCapturedBeforeCompilerEvaluation() throws {
        let (failure, _, callbacks) = try thrown("""
        Object.getOwnPropertyDescriptor = function(){throw new Error('replaced descriptor')};
        String.prototype.slice = function(){throw new Error('replaced slice')};
        throw {code:'tagger_output', detail:'original failure'};
        """)
        XCTAssertEqual(failure, .converter(code: "tagger_output", message: "original failure"))
        XCTAssertEqual(callbacks, 1)
    }

    func testMissingPrimitiveAndInheritedPropertiesHaveSafeDefaults() throws {
        let context = try XCTUnwrap(JSContext())
        let reader = DevicePDFRoute.exceptionDetailsReader(in: context)
        let unknown = DevicePDFRoute.Failure.converter(code: "exception", message: "")
        XCTAssertEqual(DevicePDFRoute.converterFailure(nil, using: reader), unknown)
        XCTAssertEqual(DevicePDFRoute.converterFailure(context.evaluateScript("({code:'tagger_output'})"), using: nil), unknown)
        for expression in ["undefined", "null", "17", "true", "Symbol('private value')", "Object.create({code:'inherited', detail:'inherited detail'})"] {
            XCTAssertEqual(DevicePDFRoute.converterFailure(context.evaluateScript(expression), using: reader), unknown, expression)
        }
    }

    func testTaggerFailureClassifiesOnlyKnownReasonsAndUsesOneBasedPositions() {
        for (error, reason) in [(DevicePDFModelError.unusable("tagger input"), "invalid_input"),
                               (DevicePDFModelError.unusable("tagger output"), "invalid_output")] {
            XCTAssertEqual(DevicePDFRoute.taggerFailureDetail(error, page: 4, line: 2, count: 12, glyphs: 67),
                           "tagger: \(reason) (page 5, line 3/12, glyphs 67)")
        }
    }

    func testTaggerDiagnosticsDoNotIncludeForeignErrorMessagesPathsOrSourceText() {
        let foreign = NSError(domain: "private_pdf_content", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "file:///private/papers/secret.pdf: private glyphs and logits"])
        for error: Error in [foreign, DevicePDFModelError.missing("/private/models/secret.mlmodelc"),
                             DevicePDFModelError.unusable("tagger output: private source text")] {
            let detail = DevicePDFRoute.taggerFailureDetail(error, page: 4, line: 2, count: 12, glyphs: 67)
            XCTAssertEqual(detail, "tagger: inference_failed (page 5, line 3/12, glyphs 67)")
            XCTAssertFalse(detail.contains("private"))
        }
    }

    func testMalformedTaggerMetadataCannotOverflowOrExceedTheDiagnosticBound() {
        for value in [Int.min, -1, Int.max] {
            let detail = DevicePDFRoute.taggerFailureDetail(nil, page: value, line: value, count: value, glyphs: value)
            XCTAssertLessThanOrEqual(detail.utf16.count, 200)
            XCTAssertTrue(detail.hasPrefix("tagger: inference_failed"))
            XCTAssertTrue(detail.contains("page unknown"))
            XCTAssertTrue(detail.contains("line unknown"))
        }
    }
}
