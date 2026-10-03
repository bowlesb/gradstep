import CryptoKit
import Foundation
import XCTest
@testable import ScienceReaderCore

final class OAuthFlowTests: XCTestCase {
    private let callback = URL(string: "com.sciencereader.ios://auth-callback")!

    func testPKCEChallengeMatchesRFC7636Vector() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback, verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try attempt.authorizationURL(supabaseURL: URL(string: "https://fixture.supabase.co")!)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(components.path, "/auth/v1/authorize")
        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(values["code_challenge_method"], "s256")
        XCTAssertEqual(values["redirect_to"], callback.absoluteString)
        XCTAssertNil(url.absoluteString.range(of: attempt.verifier))
    }

    func testCallbackBindsExactDestinationAndRejectsAmbiguousCredentials() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback)
        XCTAssertEqual(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?code=abc-123")!), "abc-123")
        for value in [
            "other.app://auth-callback?code=abc", "com.sciencereader.ios://other?code=abc",
            "com.sciencereader.ios://auth-callback/extra?code=abc", "com.sciencereader.ios://user@auth-callback?code=abc",
            "com.sciencereader.ios://auth-callback:443?code=abc", "com.sciencereader.ios://auth-callback?code=a&code=b",
            "com.sciencereader.ios://auth-callback?code=", "com.sciencereader.ios://auth-callback?code=a%0Ab",
            "com.sciencereader.ios://auth-callback?access_token=bearer&code=abc",
            "com.sciencereader.ios://auth-callback?code=abc#access_token=bearer",
            "com.sciencereader.ios://auth-callback?code=" + String(repeating: "a", count: 2_049)
        ] {
            XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: value)!)) { error in
                XCTAssertEqual(error as? OAuthFlowError, .invalidCallback)
            }
        }
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?error=access_denied&error_description=untrusted")!)) {
            XCTAssertEqual($0 as? OAuthFlowError, .providerDenied)
        }
    }

    func testRandomAttemptsAndNonceBinding() throws {
        let first = try OAuthPKCEAttempt(callbackURL: callback), second = try OAuthPKCEAttempt(callbackURL: callback)
        XCTAssertNotEqual(first.id, second.id); XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.verifier.utf8.count, 43)
        let apple = AppleSignInNonce(), other = AppleSignInNonce()
        XCTAssertNotEqual(apple.raw, other.raw)
        XCTAssertEqual(apple.hashed, Data(SHA256.hash(data: Data(apple.raw.utf8))).hex)
        XCTAssertEqual(apple.hashed.utf8.count, 64)
    }

    func testOnlyConfiguredSecureAuthorizationOriginIsAccepted() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback)
        for value in ["http://fixture.supabase.co", "https://user@fixture.supabase.co", "https://fixture.supabase.co/extra", "https://fixture.supabase.co?override=true"] {
            XCTAssertThrowsError(try attempt.authorizationURL(supabaseURL: URL(string: value)!))
        }
        for value in ["http://example.invalid/auth", "com.sciencereader.ios://auth-callback?code=existing", "com.sciencereader.ios://auth-callback#existing"] {
            XCTAssertThrowsError(try OAuthPKCEAttempt(callbackURL: URL(string: value)!))
        }
    }
}
