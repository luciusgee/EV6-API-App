import Foundation

/// Signing in with the Kia account's email and password, the way the current Kia app does
/// (hyundai_kia_connect_api's "OneApp/CCI" flow, 2026). Kia's login server blocks the older flow, so this
/// is the one that works. The password is RSA-encrypted with Kia's public key before it leaves the phone,
/// and only ever sent to Kia's login server.
///
/// 1. `authorize` on the login server (collects its session cookies);
/// 2. Kia's RSA public key (`accounts/certs`);
/// 3. `account/signin` with the encrypted password → a redirect carrying an authorisation code;
/// 4. the code → the CCI token set (`cci-api-eu.kia.com`);
/// 5. a token exchange → the access token the car API accepts.
/// The CCI token set refreshes the access token later without the password (`token-refresh`, then 5).
struct KiaAccountLogin {
    let transport: HTTPTransport
    let config: KiaConfig
    let now: () -> Date

    struct Result {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String
        var cci: CCITokens
    }

    // MARK: Password sign-in

    func signIn(email: String, password: String, deviceId: String) async throws -> Result {
        var cookies: [String: String] = [:]
        let redirect = config.oneAppRedirect
        let clientId = config.oneAppClientId

        // 1. authorize, following redirects by hand so every hop's cookies are kept.
        var url = try KiaClient.url(
            "\(config.idpBase)/auth/api/v2/user/oauth2/authorize?response_type=code&client_id=\(clientId)"
            + "&redirect_uri=\(KiaClient.formEncode(redirect))&lang=en&state=ccsp&country=de"
        )
        for _ in 0..<8 {
            let response = try await browser("GET", url, cookies: cookies)
            cookies.merge(response.cookies) { $1 }
            if response.text.lowercased().contains("abusing") || url.absoluteString.contains("/error?status=400") {
                throw KiaFailure(error: .loginFailed(reason: "Kia's login server refused the request (it blocks automated logins at times); try again later"), httpCode: 403)
            }
            guard (300...399).contains(response.status), let location = response.header("Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL
            else { break }
            url = next
        }

        // 2. Kia's public key.
        let certs = try await browser("GET", try KiaClient.url("\(config.idpBase)/auth/api/v1/accounts/certs"), cookies: cookies)
        cookies.merge(certs.cookies) { $1 }
        guard certs.status == 200, let jwk = JSONValue.parse(certs.body)?["retValue"],
              let n = jwk["n"]?.str, let e = jwk["e"]?.str, let key = RSAPublicKey(jwkN: n, e: e),
              let encrypted = key.encryptPKCS1v15(Array(password.utf8))
        else {
            throw KiaFailure(error: .server(httpCode: certs.status, code: "certs"), httpCode: certs.status == 200 ? 502 : certs.status)
        }

        // 3. Sign in; the answer is a redirect carrying the code.
        let form = [
            ("client_id", clientId),
            ("encryptedPassword", "true"),
            ("password", encrypted.map { String(format: "%02x", $0) }.joined()),
            ("redirect_uri", redirect),
            ("scope", ""),
            ("nonce", ""),
            ("state", "ccsp"),
            ("username", email),
            ("connector_session_key", ""),
            ("kid", jwk["kid"]?.str ?? ""),
            ("_csrf", ""),
        ].map { "\($0)=\(KiaClient.formEncode($1))" }.joined(separator: "&")
        let signin = try await browser(
            "POST", try KiaClient.url("\(config.idpBase)/auth/account/signin"), cookies: cookies,
            body: Data(form.utf8), contentType: "application/x-www-form-urlencoded"
        )
        let location = signin.header("Location") ?? ""
        guard signin.status == 302 || signin.status == 303 else {
            if (500...599).contains(signin.status) { throw KiaFailure(error: .server(httpCode: signin.status, code: "signin"), httpCode: signin.status) }
            throw KiaFailure(error: .loginFailed(reason: "Kia didn't accept the email and password"), httpCode: 401)
        }
        guard let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            if location.contains("/web/v1/user/authorization") {
                throw KiaFailure(error: .loginFailed(reason: "Kia needs you to accept its updated terms: sign in once in the Kia app, then try again"), httpCode: 401)
            }
            throw KiaFailure(error: .loginFailed(reason: "Kia didn't accept the email and password"), httpCode: 401)
        }

        // 4. Code → CCI tokens.
        let tokenResponse = try await transport.send(HTTPRequest(
            method: "POST",
            url: try KiaClient.url("\(config.cciDomain)/v1/auth/token?code=\(KiaClient.formEncode(code))"),
            headers: cciHeaders(deviceId: deviceId, tokens: nil)
        ))
        guard tokenResponse.status == 200, let t = JSONValue.parse(tokenResponse.body), let access = t["accessToken"]?.str else {
            throw KiaFailure(error: .server(httpCode: tokenResponse.status, code: "cci-token"), httpCode: tokenResponse.status == 200 ? 502 : tokenResponse.status)
        }
        let tokens = CCITokens(
            accessToken: access,
            exchangeableToken: t["exchangeableAccessToken"]?.str ?? "",
            exchangeableRefreshToken: t["exchangeableRefreshToken"]?.str ?? "",
            nonCcsToken: t["nonCcsToken"]?.str ?? "",
            nonCcsRefreshToken: t["nonCcsRefreshToken"]?.str ?? "",
            idToken: t["idToken"]?.str ?? ""
        )
        // 5. CCI → the access token the car API takes.
        let (ccs, expires) = try await exchange(tokens, deviceId: deviceId)
        return Result(accessToken: "Bearer \(ccs)", expiresAt: expires, refreshToken: t["refreshToken"]?.str ?? "", cci: tokens)
    }

    // MARK: Refresh

    /// A new access token from the stored token set, no password needed.
    func refresh(_ tokens: CCITokens, refreshToken: String, deviceId: String) async throws -> Result {
        let body: JSONValue = [
            "accessToken": .string(Self.bare(tokens.accessToken)),
            "refreshToken": .string(refreshToken),
            "exchangeableAccessToken": .string(tokens.exchangeableToken),
            "exchangeableRefreshToken": .string(tokens.exchangeableRefreshToken),
            "nonCcsToken": .string(tokens.nonCcsToken),
            "nonCcsRefreshToken": .string(tokens.nonCcsRefreshToken),
            "idToken": .string(tokens.idToken),
        ]
        var headers = cciHeaders(deviceId: deviceId, tokens: tokens)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = nil
        let response = try await transport.send(HTTPRequest(
            method: "POST", url: try KiaClient.url("\(config.cciDomain)/v2/auth/token-refresh"), headers: headers, body: body.data
        ))
        guard response.status == 200, let t = JSONValue.parse(response.body) else {
            throw KiaFailure(error: .loginFailed(reason: "Kia ended the session"), httpCode: response.status)
        }
        var next = CCITokens(
            accessToken: t["accessToken"]?.str ?? tokens.accessToken,
            exchangeableToken: t["exchangeableAccessToken"]?.str ?? tokens.exchangeableToken,
            exchangeableRefreshToken: t["exchangeableRefreshToken"]?.str ?? tokens.exchangeableRefreshToken,
            nonCcsToken: t["nonCcsToken"]?.str ?? tokens.nonCcsToken,
            nonCcsRefreshToken: t["nonCcsRefreshToken"]?.str ?? tokens.nonCcsRefreshToken,
            idToken: t["idToken"]?.str ?? tokens.idToken
        )
        // An updated exchangeable token can arrive as the "t" cookie.
        if let cookie = response.cookies["t"], !cookie.isEmpty { next.exchangeableToken = cookie }
        let (ccs, expires) = try await exchange(next, deviceId: deviceId)
        return Result(accessToken: "Bearer \(ccs)", expiresAt: expires, refreshToken: t["refreshToken"]?.str ?? refreshToken, cci: next)
    }

    // MARK: Pieces

    private func exchange(_ tokens: CCITokens, deviceId: String) async throws -> (String, Date) {
        let response = try await transport.send(HTTPRequest(
            method: "POST",
            url: try KiaClient.url("\(config.cciDomain)/v1/auth/token-exchange?serviceType=CCS"),
            headers: cciHeaders(deviceId: deviceId, tokens: tokens)
        ))
        guard response.status == 200, let t = JSONValue.parse(response.body),
              let token = t["accessToken"]?.str ?? t["ccsAccessToken"]?.str, !token.isEmpty
        else {
            throw KiaFailure(error: .loginFailed(reason: "Kia didn't issue a car access token"), httpCode: response.status == 200 ? 401 : response.status)
        }
        // expiresTime is a duration in seconds.
        return (token, now().addingTimeInterval(t["expiresTime"]?.num ?? 3600))
    }

    /// Headers the CCI service expects from the Kia iOS app.
    func cciHeaders(deviceId: String, tokens: CCITokens?) -> [String: String] {
        var h = [
            "client-id": KiaConfig.cciPackageId,
            "client-name": "kia",
            "client-version": KiaConfig.cciClientVersion,
            "client-os-code": "ios",
            "client-os-version": KiaConfig.cciOsVersion,
            "client-device-id": deviceId,
            "client-device-model": "iPhone",
            "client-notification-provider-type": "IOS_APPSTORE",
            "locale": "EN",
            "timezone": Self.berlinOffset(now()),
            "Accept": "application/json",
            "Accept-Language": "en",
            "User-Agent": KiaConfig.userAgent,
            "Content-Length": "0",
        ]
        if let tokens {
            h["Authentication"] = tokens.nonCcsToken
            h["authorization"] = "Bearer \(Self.bare(tokens.accessToken))"
            h["exchangeable-token"] = tokens.exchangeableToken
            h["non-ccs-token"] = tokens.nonCcsToken
        }
        return h
    }

    private func browser(_ method: String, _ url: URL, cookies: [String: String], body: Data? = nil, contentType: String? = nil) async throws -> HTTPResponse {
        var headers = ["User-Agent": KiaConfig.browserUserAgent]
        if !cookies.isEmpty { headers["Cookie"] = cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
        if let contentType { headers["Content-Type"] = contentType }
        return try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body, followRedirects: false))
    }

    static func bare(_ token: String) -> String {
        token.hasPrefix("Bearer ") ? String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) : token
    }

    /// Kia's EU data runs on German time: "+02:00" in summer.
    static func berlinOffset(_ date: Date) -> String {
        let seconds = TimeZone(identifier: "Europe/Berlin")?.secondsFromGMT(for: date) ?? 3600
        let sign = seconds < 0 ? "-" : "+"
        return String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
    }
}
