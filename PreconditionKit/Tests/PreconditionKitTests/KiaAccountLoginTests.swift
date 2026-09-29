import Foundation
import XCTest
@testable import PreconditionKit

final class KiaAccountLoginTests: XCTestCase {
    /// A 2048-bit test key (openssl) and the ciphertext Python's pow() gives for a fixed padding.
    static let nJWK = "wcyObEaPIxekm3tyhPZe7lEnrZ803o0GprV5cq6csWpVyQO6iGUWDjsyCGIiGz8KL3EJdp6QHJ8fC_rnLtlEBsrxWXvb4tqXqc809Jjm3jYnJwkZETYb768QEn-aPT1synDkNuPlVEzbfxRleDRykEaA_nQu2bZ9ELXyTz0SoTzjmqBMb7ChKSlFQ-sCRj3dAb4vcHQRqowM1RDKSc77yNw5KHgkX_ZSd4COolCwSVznQTqHLUSuGv1EJkn6DvG_UuS9V6KhDVyCi34vTcdtsuduwrciXZhW_4wEyrVzk8YMD5KD77CmdGQWcWtdS-afbLJnJyNbynwcFSZMm_qv1Q"
    static let expectedHex = "2743383164bfc1fb98d5fdaabe04f300fc0a2c1520c4f5e3f1d8ea4b88d2ab8bdc5daafc5fb9450e68eba78fdde9527115b6ab992d23b500b1fbd9ee63c3fa5ee64c0d9725274b6736a564c8184ef86033a1b60687bf5f6d506bd7b1e483da097826960dd7f6c01f778606653478f793a59bd408c7701f0f60c83f7860aba8941bdd51d18a08a92efcc44cd8bc5dddd2b22a88dc6d49c941ccd8403dc9f04a01ddbbe81d5117df3d8e47ac3b8c6d23be8737f43713da5bb57f5086e5d8297af8f1d92d31faf7e348680f377750f3b2ad14840417c3dcf36118544f19ff811998809e92cfa21f5c9684743528a1496d97cceb490f437e0eb8f0beb9d7e160afa1"

    let time = MutableTime()
    let server = ScriptedTransport()
    let sessions = InMemoryKiaSessionStore()
    let creds = TestCredentials(Credentials(email: "luke@example.com", password: "S3cret password!"))
    lazy var client = KiaClient(
        transport: server,
        budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
        credentials: creds,
        sessions: sessions,
        time: time
    )

    static let cciTokens = #"{"accessToken":"cci-acc","refreshToken":"cci-ref","nonCcsToken":"ncs","exchangeableAccessToken":"ex","exchangeableRefreshToken":"exr","nonCcsRefreshToken":"ncsr","idToken":"id","expiresIn":3599}"#

    override func setUp() {
        super.setUp()
        server.setDefault("/oauth2/authorize", HTTPResponse(status: 302, text: "", headers: ["Location": "/auth/login?client=kia"], cookies: ["SESSION": "abc"]))
        server.setDefault("/auth/login", HTTPResponse(status: 200, text: "<html>login</html>", cookies: ["XSRF": "1"]))
        server.setDefault("/accounts/certs", jsonResponse(#"{"retValue":{"kid":"k1","kty":"RSA","n":"\#(Self.nJWK)","e":"AQAB"}}"#))
        server.setDefault("/auth/account/signin", HTTPResponse(status: 302, text: "", headers: ["Location": "https://oneapp.kia.com/redirect?code=CODE123&state=ccsp"]))
        server.setDefault("/v1/auth/token", jsonResponse(Self.cciTokens))
        server.setDefault("/v1/auth/token-exchange", jsonResponse(#"{"accessToken":"ccs-1","expiresTime":86400}"#))
        server.setDefault("/v2/auth/token-refresh", jsonResponse(#"{"accessToken":"cci-acc-2","refreshToken":"cci-ref-2"}"#, status: 200))
        server.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesLegacy))
        server.setDefault("/status/latest", okResponse(KiaClientTests.legacyStatus))
        server.setDefault("/location/park", okResponse(KiaClientTests.park))
    }

    private func read() async -> ApiResult<VehicleFetch> { await client.getVehicle(.manual) }

    // MARK: RSA

    func testRSAMatchesAnIndependentImplementation() throws {
        let key = try XCTUnwrap(RSAPublicKey(jwkN: Self.nJWK, e: "AQAB"))
        XCTAssertEqual(key.size, 256)
        let message = Array("S3cret password!".utf8)
        let padding = (0..<(256 - message.count - 3)).map { UInt8(($0 * 37) % 255 + 1) }
        let c = try XCTUnwrap(key.encryptPKCS1v15(message, padding: padding))
        XCTAssertEqual(c.map { String(format: "%02x", $0) }.joined(), Self.expectedHex)
        // With random padding: right length, never the same twice.
        let a = try XCTUnwrap(key.encryptPKCS1v15(message))
        let b = try XCTUnwrap(key.encryptPKCS1v15(message))
        XCTAssertEqual(a.count, 256)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(key.encryptPKCS1v15([UInt8](repeating: 1, count: 250)), "too long for the key")
    }

    // MARK: Sign-in

    func testSignsInWithEmailAndPasswordThenReadsTheCar() async throws {
        let fetched = await expectSuccess(await read())
        XCTAssertEqual(fetched?.snapshot.socPercent, 74)

        let paths = server.paths
        let register = try XCTUnwrap(paths.firstIndex { $0.hasSuffix("notifications/register") })
        let authorize = try XCTUnwrap(paths.firstIndex { $0.contains("oauth2/authorize") })
        XCTAssertLessThan(register, authorize, "the device id is needed for the sign-in")
        XCTAssertFalse(paths.contains { $0.hasSuffix("user/oauth2/token") }, "no legacy refresh-token grant")

        let signin = try XCTUnwrap(server.last("/auth/account/signin"))
        XCTAssertFalse(signin.followRedirects, "the code is read from the redirect")
        XCTAssertEqual(signin.header("Cookie"), "SESSION=abc; XSRF=1")
        let form = Dictionary(uniqueKeysWithValues: signin.bodyText.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (kv[0], (kv.count > 1 ? kv[1] : "").removingPercentEncoding ?? "")
        })
        XCTAssertEqual(form["username"], "luke@example.com")
        XCTAssertEqual(form["encryptedPassword"], "true")
        XCTAssertEqual(form["kid"], "k1")
        XCTAssertEqual(form["client_id"], "01b36c86-79e8-486c-8009-15f2ad88d670")
        XCTAssertEqual(form["password"]?.count, 512, "RSA-2048 ciphertext as hex")
        XCTAssertFalse(signin.bodyText.contains("S3cret"), "the password never leaves in the clear")

        let token = try XCTUnwrap(server.last("/v1/auth/token"))
        XCTAssertEqual(URLComponents(url: token.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "CODE123")
        XCTAssertEqual(token.header("client-device-id"), "dev-1")
        XCTAssertEqual(token.header("client-id"), "com.kia.oneapp.eu")
        XCTAssertNil(token.header("authorization"))

        let exchange = try XCTUnwrap(server.last("/v1/auth/token-exchange"))
        XCTAssertEqual(exchange.header("authorization"), "Bearer cci-acc")
        XCTAssertEqual(exchange.header("Authentication"), "ncs")
        XCTAssertEqual(exchange.header("exchangeable-token"), "ex")
        XCTAssertEqual(exchange.url.query, "serviceType=CCS")

        XCTAssertEqual(server.last("/status/latest")?.header("Authorization"), "Bearer ccs-1")
        let stored = await sessions.session
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(session.refreshToken, "cci-ref")
        XCTAssertEqual(session.cci?.nonCcsToken, "ncs")
        XCTAssertEqual(session.accessExpiresAt, t0.addingTimeInterval(86400))
    }

    func testRefreshesWithTheTokenSetNotThePassword() async throws {
        await expectSuccess(await read())
        time.advance(86400)
        server.clearSeen()
        await expectSuccess(await read())
        XCTAssertFalse(server.seen.contains { $0.url.path.hasSuffix("/auth/account/signin") })
        let refresh = try XCTUnwrap(server.last("/v2/auth/token-refresh"))
        let body = try XCTUnwrap(body(refresh))
        XCTAssertEqual(body["refreshToken"], "cci-ref")
        XCTAssertEqual(body["accessToken"], "cci-acc")
        XCTAssertEqual(body["nonCcsRefreshToken"], "ncsr")
        XCTAssertEqual(refresh.header("Content-Type"), "application/json")
        // Fields the refresh didn't return are kept.
        let stored = await sessions.session
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(session.cci?.accessToken, "cci-acc-2")
        XCTAssertEqual(session.cci?.nonCcsToken, "ncs")
        XCTAssertEqual(session.refreshToken, "cci-ref-2")
    }

    func testAnEndedSessionSignsInAgainWithThePassword() async throws {
        await expectSuccess(await read())
        time.advance(86400)
        server.setDefault("/v2/auth/token-refresh", jsonResponse(#"{"error":"invalid"}"#, status: 401))
        server.clearSeen()
        await expectSuccess(await read())
        XCTAssertTrue(server.seen.contains { $0.url.path.hasSuffix("/auth/account/signin") })
    }

    func testAWrongPasswordIsAnAuthFailure() async throws {
        server.setDefault("/auth/account/signin", HTTPResponse(status: 200, text: "<html>Incorrect password</html>"))
        let error = try await failure(await read())
        XCTAssertTrue(error.isAuthFailure)
        XCTAssertTrue(error.message.contains("email and password"), error.message)
        XCTAssertFalse(server.seen.contains { $0.url.path.hasSuffix("/v1/auth/token") })
    }

    func testTermsToAcceptAndTheServerBlockAreExplained() async throws {
        server.setDefault("/auth/account/signin", HTTPResponse(status: 302, text: "", headers: ["Location": "https://idpconnect-eu.kia.com/web/v1/user/authorization?x=1"]))
        let consent = try await failure(await read())
        XCTAssertTrue(consent.message.contains("terms"), consent.message)

        server.setDefault("/oauth2/authorize", HTTPResponse(status: 200, text: "You are abusing request"))
        await sessions.save(nil)
        let blocked = try await failure(await read())
        XCTAssertTrue(blocked.message.contains("refused"), blocked.message)
    }

    func testCredentialsKeepWorkingFromOlderSavesAndNeverPrintSecrets() throws {
        let old = try JSONDecoder().decode(Credentials.self, from: Data(#"{"refreshToken":"ABC","vin":"","pin":"1234"}"#.utf8))
        XCTAssertEqual(old.refreshToken, "ABC")
        XCTAssertNil(old.account)
        XCTAssertTrue(old.isConfigured)
        let account = Credentials(pin: "1234", email: "luke@example.com", password: "hunter2")
        XCTAssertEqual(account.description, "Credentials(account: l***@example.com, vin: none, pin: set)")
        XCTAssertFalse(account.description.contains("hunter2"))
        XCTAssertNotEqual(account.loginFingerprint, Credentials(email: "other@example.com", password: "x").loginFingerprint)
        XCTAssertEqual(account.loginFingerprint, Credentials(email: "LUKE@example.com", password: "changed").loginFingerprint)
        XCTAssertFalse(Credentials(pin: "1234").isConfigured)
        XCTAssertEqual(KiaAccountLogin.berlinOffset(date("2026-07-01T12:00:00Z")), "+02:00")
        XCTAssertEqual(KiaAccountLogin.berlinOffset(date("2026-01-01T12:00:00Z")), "+01:00")
    }
}
