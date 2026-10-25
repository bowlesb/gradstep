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

    func testDeletedAccountInvitationRefusalIsRecognizedWithoutAcceptingFragmentCredentials() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback)
        for suffix in ["?error=access_denied&error_code=signup_disabled",
                       "#error=access_denied&error_code=signup_disabled&error_description=Signups+not+allowed",
                       "#error=access_denied&error_description=beta_invitation_required"] {
            XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + suffix)!)) {
                XCTAssertEqual($0 as? OAuthFlowError, .invitationRequired)
            }
        }
        for suffix in ["?code=abc#error=access_denied&error_code=signup_disabled",
                       "#access_token=secret&error_code=signup_disabled", "#code=abc",
                       "?code=abc&error_code=signup_disabled", "?error_code=signup_disabled&error_code=other"] {
            XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + suffix)!)) {
                XCTAssertEqual($0 as? OAuthFlowError, .invalidCallback)
            }
        }
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "evil://auth#Error=access_denied&error_code=signup_disabled")!)) {
            XCTAssertEqual($0 as? OAuthFlowError, .invalidCallback)
        }
    }

    /// TestFlight 92: Supabase issued the code (its 302 Location has no fragment) and the app refused the return. WebKit keeps
    /// an earlier page's fragment across redirects, so a provider's sign-in pages can leave `#` or `#…` on it.
    func testAFragmentTheBrowserCarriedOverIsIgnored() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback)
        let code = "0f0e0d0c-0b0a-4908-8706-050403020100"
        for suffix in ["#", "#x", "#_=_", "#!/home", "#gid=0&tab=1", "#state=opaque"] {
            XCTAssertEqual(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?code=" + code + suffix)!), code, suffix)
        }
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?error=access_denied&error_code=signup_disabled#")!)) {
            XCTAssertEqual($0 as? OAuthFlowError, .invitationRequired)
        }
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?error=access_denied#x")!)) {
            XCTAssertEqual($0 as? OAuthFlowError, .providerDenied)
        }
        // A fragment naming any OAuth parameter is still Auth's: never mixed with a query code, never a credential.
        for suffix in ["#Access_Token=x", "#access%5Ftoken=x", "#code=other", "#error=access_denied", "#expires_in=3600",
                       "#provider_token=x", "#refresh_token=x&gid=0"] {
            XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?code=" + code + suffix)!), suffix) {
                XCTAssertEqual($0 as? OAuthFlowError, .invalidCallback)
            }
        }
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: callback.absoluteString + "?code=a&code=b#")!)) {
            XCTAssertEqual($0 as? OAuthFlowError, .invalidCallback)
        }
    }

    func testCallbackDescriptionNamesShapesAndNeverValues() throws {
        let attempt = try OAuthPKCEAttempt(callbackURL: callback)
        let code = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let plain = callback.absoluteString + "?code=" + code
        XCTAssertEqual(attempt.describeCallback(URL(string: plain)!),
                       "destination=ok query=code fragment=none code=uuid length=\(plain.utf8.count)")
        XCTAssertEqual(attempt.describeCallback(URL(string: plain + "#")!),
                       "destination=ok query=code fragment=empty code=uuid length=\(plain.utf8.count + 1)")
        let denied = callback.absoluteString + "#error=access_denied&error_code=signup_disabled&error_description=Signups+for+someone%40example.com"
        XCTAssertEqual(attempt.describeCallback(URL(string: denied)!), "destination=ok query=none fragment=error,error_code,error_description " +
                       "error=access_denied error_code=signup_disabled length=\(denied.utf8.count)")
        let hostile = "other.app://elsewhere/x?code=secret%23value&state=s3cr3t&utm=campaign#access_token=t0ken&gid=0"
        let described = attempt.describeCallback(URL(string: hostile)!)
        XCTAssertEqual(described, "destination=scheme+host+path query=code,state,other:1 fragment=access_token,other:1 code=12ch,unsafe " +
                       "length=\(hostile.utf8.count)")
        for secret in ["secret", "s3cr3t", "campaign", "t0ken", "someone"] { XCTAssertFalse(described.contains(secret)) }
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
