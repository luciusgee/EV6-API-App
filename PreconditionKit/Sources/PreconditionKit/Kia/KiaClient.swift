import Foundation

/// Kia Connect Europe (HANDOVER.md §3). Unofficial: it speaks the Kia app's own protocol, so it can break
/// whenever Kia changes it.
///
/// Only cached state is read (`status/latest`, `location/park`), which never wakes the car, so automation
/// can't drain the 12 V battery by polling. Each call takes one slot from the `RateBudget`, even though it
/// may make several HTTP requests (login refresh, device registration, vehicle list, status + position).
/// Calls run one at a time.
public final class KiaClient: VehicleAPI, @unchecked Sendable {
    private let transport: HTTPTransport
    private let budget: RateBudget
    private let credentials: CredentialsProvider
    private let sessions: KiaSessionStore
    private let metaSink: ApiMetaSink
    private let time: TimeSource
    private let config: KiaConfig
    private let mutex = AsyncMutex()
    /// Only touched while holding `mutex`.
    private var rng: any RandomNumberGenerator

    static let refreshMargin: TimeInterval = 5 * 60
    static let controlTokenMargin: TimeInterval = 30
    /// Remote control unavailable, request timeout, undefined/response timeout, duplicate request.
    static let busyCodes: Set<String> = ["5031", "4081", "9999", "4004"]

    public init(
        transport: HTTPTransport,
        budget: RateBudget,
        credentials: CredentialsProvider,
        sessions: KiaSessionStore,
        metaSink: ApiMetaSink = NoopMetaSink(),
        time: TimeSource = SystemTime(),
        config: KiaConfig = KiaConfig(),
        rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.transport = transport
        self.budget = budget
        self.credentials = credentials
        self.sessions = sessions
        self.metaSink = metaSink
        self.time = time
        self.config = config
        self.rng = rng
    }

    // MARK: - VehicleAPI

    public func getVehicle(_ kind: RequestKind) async -> ApiResult<VehicleFetch> {
        await call(kind) { s, _ in
            let id = try Self.vehicleId(s)
            let path = s.ccs2 != 0 ? "ccs2/carstatus/latest" : "status/latest"
            let status = try await self.get("\(self.config.spa)/vehicles/\(id)/\(path)", self.authHeaders(s))
            // The position inside the status can be old; the parked position is current and doesn't wake the car either.
            let park: JSONValue?
            do {
                park = try await self.get("\(self.config.spa)/vehicles/\(id)/location/park", self.authHeaders(s, ccs2: 0))
            } catch is KiaAPIError {
                park = nil
            }
            var raw: [String: JSONValue] = ["status": status]
            if let park { raw["park"] = park }
            let snapshot = KiaMapper.toSnapshot(status: status, park: park, ccs2: s.ccs2 != 0, fetchedAt: self.time.now())
            return VehicleFetch(snapshot: snapshot, rawJSON: JSONValue.object(raw).text)
        }
    }

    public func startClimate(targetC: Double, kind: RequestKind, options extras: ClimateOptions) async -> ApiResult<Void> {
        await call(kind) { s, creds in
            let id = try Self.vehicleId(s)
            let target = Self.roundToHalf(min(max(targetC, KiaConfig.minTempC), KiaConfig.maxTempC))
            let minutes = JSONValue.number(Double(self.config.climateMinutes))
            if s.ccs2 == 0 {
                let options: JSONValue = [
                    "defrost": .bool(extras.defrost),
                    "heating1": .number(extras.heatedExtras ? 1 : 0),
                    "igniOnDuration": minutes,
                ]
                let body: JSONValue = [
                    "action": "start",
                    "hvacType": 0,
                    "options": options,
                    "tempCode": .string(KiaMapper.legacyTempCode(target)),
                    "unit": "C",
                ]
                _ = try await self.post("\(self.config.spa)/vehicles/\(id)/control/temperature", self.authHeaders(s), body)
            } else {
                let seats: JSONValue = [
                    "drvSeatClimateState": 0,
                    "psgSeatClimateState": 0,
                    "rrSeatClimateState": 0,
                    "rlSeatClimateState": 0,
                ]
                let body: JSONValue = [
                    "command": "start",
                    "ignitionDuration": minutes,
                    "strgWhlHeating": .number(extras.heatedExtras ? 1 : 0),
                    "hvacTempType": 1,
                    "hvacTemp": .number(target),
                    "sideRearMirrorHeating": 1,
                    // "L" for left-hand drive. The Python library sends "R" in mile-based markets; check on a UK car.
                    "drvSeatLoc": "L",
                    "seatClimateInfo": seats,
                    "tempUnit": "C",
                    "windshieldFrontDefogState": .bool(extras.defrost),
                ]
                let headers = try await self.controlHeaders(s, creds)
                _ = try await self.post("\(self.config.spaV2)/vehicles/\(id)/ccs2/control/temperature", headers, body)
            }
        }
    }

    public func stopClimate(_ kind: RequestKind) async -> ApiResult<Void> {
        await call(kind) { s, creds in
            let id = try Self.vehicleId(s)
            if s.ccs2 == 0 {
                let options: JSONValue = ["defrost": true, "heating1": 1]
                let body: JSONValue = ["action": "stop", "hvacType": 0, "options": options, "tempCode": "10H", "unit": "C"]
                _ = try await self.post("\(self.config.spa)/vehicles/\(id)/control/temperature", self.authHeaders(s), body)
            } else {
                let headers = try await self.controlHeaders(s, creds)
                _ = try await self.post("\(self.config.spaV2)/vehicles/\(id)/ccs2/control/temperature", headers, ["command": "stop"])
            }
        }
    }

    /// Charging, locks and charge limits (payloads as in hyundai_kia_connect_api's ApiImplType1).
    public func send(_ command: CarCommand, kind: RequestKind) async -> ApiResult<Void> {
        await call(kind) { s, creds in
            let id = try Self.vehicleId(s)
            let ccs2 = s.ccs2 != 0
            switch command {
            case .startCharging, .stopCharging:
                let verb = command == .startCharging ? "start" : "stop"
                if ccs2 {
                    let headers = try await self.controlHeaders(s, creds)
                    _ = try await self.post("\(self.config.spaV2)/vehicles/\(id)/ccs2/control/charge", headers, ["command": .string(verb)])
                } else {
                    let body: JSONValue = ["action": .string(verb), "deviceId": .string(s.deviceId ?? "")]
                    _ = try await self.post("\(self.config.spa)/vehicles/\(id)/control/charge", self.authHeaders(s), body)
                }
            case .lock, .unlock:
                let verb = command == .lock ? "close" : "open"
                if ccs2 {
                    let headers = try await self.controlHeaders(s, creds)
                    _ = try await self.post("\(self.config.spaV2)/vehicles/\(id)/ccs2/control/door", headers, ["command": .string(verb)])
                } else {
                    let body: JSONValue = ["action": .string(verb), "deviceId": .string(s.deviceId ?? "")]
                    _ = try await self.post("\(self.config.spa)/vehicles/\(id)/control/door", self.authHeaders(s), body)
                }
            case .setChargeLimits(let ac, let dc):
                let dcEntry: JSONValue = ["plugType": 0, "targetSOClevel": .number(Double(Self.chargeLimit(dc)))]
                let acEntry: JSONValue = ["plugType": 1, "targetSOClevel": .number(Double(Self.chargeLimit(ac)))]
                let body: JSONValue = ["targetSOClist": [dcEntry, acEntry]]
                _ = try await self.post("\(self.config.spa)/vehicles/\(id)/charge/target", self.authHeaders(s), body)
            }
        }
    }

    /// The car accepts 50–100 % in steps of 10.
    static func chargeLimit(_ p: Int) -> Int {
        min(max(Int((Double(p) / 10).rounded()) * 10, 50), 100)
    }

    /// Lifetime energy totals plus the last 30 days (two HTTP requests, one budget slot).
    public func drivingHistory(_ kind: RequestKind) async -> ApiResult<DrivingHistory> {
        await call(kind) { s, _ in
            let id = try Self.vehicleId(s)
            let url = "\(self.config.spa)/vehicles/\(id)/drvhistory"
            let allTime = try await self.post(url, self.authHeaders(s), ["periodTarget": 1])
            let month = try await self.post(url, self.authHeaders(s), ["periodTarget": 0])
            return DrivingHistory.parse(allTime: allTime, month: month, fetchedAt: self.time.now())
        }
    }

    /// Clears the stored login, e.g. when the user enters a new token.
    public func reset() async {
        await mutex.withLock { await sessions.save(nil) }
    }

    // MARK: - Budget, retries, error mapping

    private func call<T>(_ kind: RequestKind, _ op: (KiaSession, Credentials) async throws -> T) async -> ApiResult<T> {
        await mutex.withLock {
            guard let creds = await credentials.credentials(), creds.isConfigured else { return .failure(.notConfigured, nil) }
            guard let ticket = await budget.tryAcquire(kind) else { return .failure(.budgetExhausted(kind), nil) }
            do {
                let value = try await withSession(creds, op)
                let meta = ResponseMeta(httpCode: 200, receivedAt: time.now())
                await budget.complete(ticket, meta: meta)
                await metaSink.onResponse(meta, error: nil)
                return .success(value, meta)
            } catch let failure as KiaFailure {
                return await fail(ticket, failure.error, httpCode: failure.httpCode)
            } catch let e as KiaAPIError {
                let error = Self.map(e)
                return await fail(ticket, error, httpCode: Self.metaCode(e, error))
            } catch {
                // No response arrived. It still counts against the budget.
                await budget.complete(ticket, meta: nil)
                return .failure(.network(Self.describe(error)), nil)
            }
        }
    }

    private func fail<T>(_ ticket: BudgetTicket, _ error: ApiError, httpCode: Int) async -> ApiResult<T> {
        var retryAfter: TimeInterval?
        if case .rateLimited(let after) = error { retryAfter = after }
        let meta = ResponseMeta(httpCode: httpCode, receivedAt: time.now(), retryAfter: retryAfter)
        await budget.complete(ticket, meta: meta, error: error)
        await metaSink.onResponse(meta, error: error)
        return .failure(error, meta)
    }

    /// Runs `op` with a working session: refreshes an expired login and re-registers a dropped device, once each.
    private func withSession<T>(_ creds: Credentials, _ op: (KiaSession, Credentials) async throws -> T) async throws -> T {
        var refreshed = false
        var reRegistered = false
        while true {
            do {
                let session = try await ensureSession(creds)
                return try await op(session, creds)
            } catch let e as KiaAPIError {
                guard var session = await sessions.load() else { throw e }
                if e.isLoginExpired && !refreshed {
                    refreshed = true
                    session.accessToken = nil
                    session.controlToken = nil
                    await sessions.save(session)
                } else if e.isDeviceRejected && !reRegistered {
                    reRegistered = true
                    session.deviceId = nil
                    session.controlToken = nil
                    await sessions.save(session)
                } else {
                    throw e
                }
            }
        }
    }

    private func ensureSession(_ creds: Credentials) async throws -> KiaSession {
        let hash = creds.loginFingerprint
        var s: KiaSession
        if let stored = await sessions.load(), stored.enteredTokenHash == hash {
            s = stored
        } else {
            s = KiaSession(enteredTokenHash: hash, refreshToken: creds.account == nil ? creds.refreshToken : "")
        }
        let expired = s.accessToken == nil || time.now() >= s.accessExpiresAt.addingTimeInterval(-Self.refreshMargin)
        if let account = creds.account {
            // The account sign-in identifies the phone by its registered device id, so register first.
            if s.deviceId == nil {
                s = await save(try await registerDevice(s))
            }
            if expired {
                s = await save(try await accountLogin(s, email: account.email, password: account.password))
            }
        } else {
            if expired {
                s = await save(try await refreshLogin(s))
            }
            if s.deviceId == nil {
                s = await save(try await registerDevice(s))
            }
        }
        let wanted = creds.vin.trimmingCharacters(in: .whitespaces).uppercased()
        if s.vehicleId == nil || s.selectedFor != wanted {
            s = await save(try await selectVehicle(s, wantedVin: wanted))
        }
        return s
    }

    /// Refreshes with the stored token set; signs in with the password when there is none or Kia ended it.
    private func accountLogin(_ s: KiaSession, email: String, password: String) async throws -> KiaSession {
        let login = KiaAccountLogin(transport: transport, config: config, now: { [time] in time.now() })
        let deviceId = s.deviceId ?? ""
        var result: KiaAccountLogin.Result?
        if let cci = s.cci, !s.refreshToken.isEmpty {
            do {
                result = try await login.refresh(cci, refreshToken: s.refreshToken, deviceId: deviceId)
            } catch let failure as KiaFailure {
                // Kia ended the session: sign in again below. Other failures (offline) go up.
                _ = failure
            }
        }
        let r: KiaAccountLogin.Result
        if let result { r = result } else { r = try await login.signIn(email: email, password: password, deviceId: deviceId) }
        var next = s
        next.accessToken = r.accessToken
        next.accessExpiresAt = r.expiresAt
        next.refreshToken = r.refreshToken
        next.cci = r.cci
        next.controlToken = nil
        return next
    }

    private func save(_ s: KiaSession) async -> KiaSession {
        await sessions.save(s)
        return s
    }

    // MARK: - Login (§3.3, §3.4, §3.6)

    private func refreshLogin(_ s: KiaSession) async throws -> KiaSession {
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", s.refreshToken),
            ("client_id", config.serviceId),
            ("client_secret", config.serviceSecret),
        ].map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&")
        let request = HTTPRequest(
            method: "POST",
            url: try Self.url("\(config.idpBase)/auth/api/v2/user/oauth2/token"),
            headers: ["User-Agent": KiaConfig.userAgent, "Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8)
        )
        let response = try await transport.send(request)
        let code = response.status
        guard let body = JSONValue.parse(response.body), body.isObject,
              (200...299).contains(code), let access = body["access_token"]?.str
        else {
            if (500...599).contains(code) { throw KiaFailure(error: .server(httpCode: code, code: "login"), httpCode: code) }
            throw KiaFailure(error: .loginFailed(reason: "Kia rejected the refresh token"), httpCode: 401)
        }
        var next = s
        // Kia may rotate the refresh token: keep the new one from now on.
        next.refreshToken = body["refresh_token"]?.str ?? s.refreshToken
        next.accessToken = "\(body["token_type"]?.str ?? "Bearer") \(access)"
        next.accessExpiresAt = time.now().addingTimeInterval(body["expires_in"]?.num ?? 3600)
        next.controlToken = nil
        return next
    }

    private func registerDevice(_ s: KiaSession) async throws -> KiaSession {
        let hex = Array("0123456789abcdef")
        let pushId = String((0..<64).map { _ in hex[Int.random(in: 0..<16, using: &rng)] })
        let body: JSONValue = ["pushRegId": .string(pushId), "pushType": "APNS", "uuid": .string(randomUUID())]
        let headers = [
            "ccsp-service-id": config.serviceId,
            "ccsp-application-id": config.appId,
            "Stamp": stamp(),
            "User-Agent": KiaConfig.userAgent,
        ]
        let res = try await post("\(config.spa)/notifications/register", headers, body)
        guard let deviceId = res.path("resMsg.deviceId")?.str else {
            throw KiaAPIError(httpCode: 200, resCode: nil, detail: "no deviceId")
        }
        var next = s
        next.deviceId = deviceId
        next.controlToken = nil
        return next
    }

    private func selectVehicle(_ s: KiaSession, wantedVin: String) async throws -> KiaSession {
        let res = try await get("\(config.spa)/vehicles", authHeaders(s, ccs2: 0))
        let vehicles = res.path("resMsg.vehicles")?.array ?? []
        let chosen: JSONValue?
        if !wantedVin.isEmpty {
            chosen = vehicles.first { $0["vin"]?.str?.uppercased() == wantedVin }
        } else {
            chosen = vehicles.first { $0["type"]?.str == "EV" } ?? vehicles.first
        }
        guard let chosen else { throw KiaFailure(error: .vehicleNotFound(code: nil), httpCode: 404) }
        guard let vehicleId = chosen["vehicleId"]?.str else {
            throw KiaAPIError(httpCode: 200, resCode: nil, detail: "no vehicleId")
        }
        var next = s
        next.vehicleId = vehicleId
        next.vehicleVin = chosen["vin"]?.str
        next.selectedFor = wantedVin
        next.ccs2 = chosen["ccuCCS2ProtocolSupport"]?.int ?? 0
        return next
    }

    /// CCS2 commands need a short-lived control token, obtained with the Kia Connect PIN (§3.8).
    private func controlHeaders(_ s: KiaSession, _ creds: Credentials) async throws -> [String: String] {
        guard let pin = creds.pin?.trimmingCharacters(in: .whitespaces), !pin.isEmpty else {
            throw KiaFailure(error: .loginFailed(reason: "this car needs your Kia Connect PIN for climate commands"), httpCode: 401)
        }
        var session = s
        if session.controlToken == nil || time.now() >= session.controlExpiresAt.addingTimeInterval(-Self.controlTokenMargin) {
            let body: JSONValue = ["deviceId": .string(s.deviceId ?? ""), "pin": .string(pin)]
            let request = HTTPRequest(
                method: "PUT",
                url: try Self.url("\(config.user)/pin?token="),
                headers: [
                    "Authorization": s.accessToken ?? "",
                    "User-Agent": KiaConfig.userAgent,
                    "Content-Type": "application/json;charset=UTF-8",
                ],
                body: body.data
            )
            let response = try await transport.send(request)
            let parsed = JSONValue.parse(response.body)
            guard let parsed, parsed.isObject, let token = parsed["controlToken"]?.str else {
                // An expired access token shows up here too; let withSession refresh it and retry.
                if response.status == 401 || (parsed.map { KiaAPIError.from(response.status, $0).isLoginExpired } ?? false) {
                    throw KiaAPIError(httpCode: 401, resCode: "7501", detail: "login expired")
                }
                throw KiaFailure(error: .loginFailed(reason: "Kia Connect PIN rejected"), httpCode: 401)
            }
            session.controlToken = "Bearer \(token)"
            session.controlExpiresAt = time.now().addingTimeInterval(parsed["expiresTime"]?.num ?? 600)
            session = await save(session)
        }
        var headers = authHeaders(session)
        headers["Authorization"] = session.controlToken
        headers["AuthorizationCCSP"] = session.controlToken
        return headers
    }

    /// §3.5. `ccs2` overrides the protocol header (the vehicle list and parked position always send 0).
    private func authHeaders(_ s: KiaSession, ccs2: Int? = nil) -> [String: String] {
        [
            "Authorization": s.accessToken ?? "",
            "ccsp-service-id": config.serviceId,
            "ccsp-application-id": config.appId,
            "Stamp": stamp(),
            "ccsp-device-id": s.deviceId ?? "",
            "Ccuccs2protocolsupport": String(ccs2 ?? s.ccs2),
            "User-Agent": KiaConfig.userAgent,
        ]
    }

    private func stamp() -> String {
        config.stamp(epochSeconds: Int64(time.now().timeIntervalSince1970))
    }

    // MARK: - HTTP

    private func get(_ url: String, _ headers: [String: String]) async throws -> JSONValue {
        let response = try await transport.send(HTTPRequest(method: "GET", url: try Self.url(url), headers: headers))
        return try Self.parse(response)
    }

    private func post(_ url: String, _ headers: [String: String], _ body: JSONValue) async throws -> JSONValue {
        var h = headers
        h["Content-Type"] = "application/json;charset=UTF-8"
        let response = try await transport.send(HTTPRequest(method: "POST", url: try Self.url(url), headers: h, body: body.data))
        return try Self.parse(response)
    }

    /// Kia signals failure with `retCode: "F"` (often on HTTP 200 or 400), or an OAuth-style `error` field.
    private static func parse(_ response: HTTPResponse) throws -> JSONValue {
        let code = response.status
        guard let body = JSONValue.parse(response.body), body.isObject else {
            if (200...299).contains(code) {
                throw KiaFailure(error: .badResponse(httpCode: code, cause: "not JSON"), httpCode: code)
            }
            throw KiaAPIError(httpCode: code, resCode: nil, detail: nil)
        }
        let e = KiaAPIError.from(code, body)
        if !(200...299).contains(code) || body["retCode"]?.str == "F" || e.isLoginExpired { throw e }
        return body
    }

    /// The error table in HANDOVER.md §3.9.
    static func map(_ e: KiaAPIError) -> ApiError {
        if e.isLoginExpired { return .loginFailed(reason: "Kia Connect login no longer accepted") }
        if e.resCode == "5091" { return .rateLimited(retryAfter: 3600) }
        if let code = e.resCode, busyCodes.contains(code) { return .vehicleNotAcceptingRequests(retryAfter: 120) }
        if e.resCode == "4005" { return .operationNotSupported(code: e.resCode) }
        if e.httpCode == 404 { return .vehicleNotFound(code: e.resCode) }
        if (500...599).contains(e.httpCode) { return .server(httpCode: e.httpCode, code: e.resCode) }
        return .http(httpCode: e.httpCode, code: e.resCode ?? e.detail.map { String($0.prefix(60)) })
    }

    /// The status to record: auth failures as 401 so they don't count against the budget, Kia's limit as 429.
    private static func metaCode(_ e: KiaAPIError, _ error: ApiError) -> Int {
        switch error {
        case .loginFailed: return 401
        case .rateLimited: return 429
        default: return e.httpCode
        }
    }

    static func roundToHalf(_ c: Double) -> Double {
        (c * 2).rounded(.toNearestOrAwayFromZero) / 2
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw KiaAPIError(httpCode: 0, resCode: nil, detail: "bad URL") }
        return url
    }

    private static func vehicleId(_ s: KiaSession) throws -> String {
        guard let id = s.vehicleId else { throw KiaAPIError(httpCode: 0, resCode: nil, detail: "no vehicle selected") }
        return id
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError { return urlError.localizedDescription }
        return String(describing: error)
    }

    private func randomUUID() -> String {
        var b = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        b[6] = (b[6] & 0x0f) | 0x40 // version 4
        b[8] = (b[8] & 0x3f) | 0x80 // RFC 4122 variant
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }
}

/// An error Kia returned, before mapping.
struct KiaAPIError: Error {
    var httpCode: Int
    var resCode: String?
    var detail: String?

    /// Access token expired or rejected.
    var isLoginExpired: Bool {
        if resCode == "7501" || httpCode == 401 { return true }
        guard let d = detail?.lowercased() else { return false }
        return d.contains("token is expired") || d.contains("token has expired") || d.contains("unexpected statuscode")
    }

    /// The server dropped the registered device (it does this when push delivery fails).
    var isDeviceRejected: Bool { resCode == "4002" }

    static func from(_ code: Int, _ body: JSONValue) -> KiaAPIError {
        let error = body["error"]
        let detail = body["resMsg"]?.str ?? body["retMsg"]?.str ?? error?.str ?? (error?.isObject == true ? error?.text : nil)
        return KiaAPIError(httpCode: code, resCode: body["resCode"]?.str, detail: detail)
    }
}

/// A failure already mapped to an `ApiError`.
struct KiaFailure: Error {
    var error: ApiError
    var httpCode: Int
}
