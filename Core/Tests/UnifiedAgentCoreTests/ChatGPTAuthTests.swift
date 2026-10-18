// SYNTHETIC tests for the experimental ChatGPT sign-in (no live sign-in, no network: URLProtocol stubs and a
// 127.0.0.1 listener; a throwaway in-memory RSA key, never a Keychain item). Adapted from the uncommitted draft
// tests in esp32-iphone-agent-original (ios/IPhoneAgentTests/ChatGPTTests.swift).
import CryptoKit
import Security
import XCTest
@testable import UnifiedAgentCore

/// Records every request (URL, headers, body) and answers by path; for auth.openai.com and the Responses API.
final class RouteStub: URLProtocol {
    struct Seen { let url: URL; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var routes: [String: (Seen) -> (Int, String, String)] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        return URLSession(configuration: config)
    }

    static func form(_ seen: Seen) -> [String: String] {
        let items = URLComponents(string: "?" + String(decoding: seen.body, as: UTF8.self))?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let seen = Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.seen.append(seen)
        let deliver = { [self] in
            let (status, type, text) = Self.routes[request.url!.path]?(seen) ?? (404, "text/plain", "no route")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": type, "x-request-id": "req_test"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        // A held path answers only after `release`, without blocking other requests.
        if let gate = Self.held[request.url!.path] { DispatchQueue.global().async { gate.wait(); deliver() } } else { deliver() }
    }

    nonisolated(unsafe) static var held: [String: DispatchSemaphore] = [:]

    override func stopLoading() {}
}

final class MemoryChatGPTStore: ChatGPTStore {
    var credential: ChatGPTCredential?
    var host: String?
    func load() -> ChatGPTCredential? { credential }
    func save(_ credential: ChatGPTCredential?) { self.credential = credential }
    func hostID() -> String {
        if let host { return host }
        host = "urn:uuid:" + UUID().uuidString.lowercased()
        return host!
    }
}

/// Plays the authorization server's redirect: a real HTTP GET of the 127.0.0.1 callback with code and state.
@MainActor final class RedirectingBrowser: ChatGPTBrowser {
    var opened: [URL] = []
    var issuedClientID: String? = "oaiapp_test"
    var extra: [URLQueryItem] = []
    /// The latest attempt's nonce, for the stub token endpoint (which runs off the main actor).
    nonisolated(unsafe) static var nonce = ""

    func open(_ url: URL, onEnd: @escaping @MainActor @Sendable () -> Void) throws {
        opened.append(url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        Self.nonce = query.first { $0.name == "nonce" }?.value ?? ""
        var callback = URLComponents(string: query.first { $0.name == "redirect_uri" }!.value!)!
        callback.queryItems = [URLQueryItem(name: "code", value: "code_123"),
                               URLQueryItem(name: "state", value: query.first { $0.name == "state" }!.value)]
            + (issuedClientID.map { [URLQueryItem(name: "client_id", value: $0)] } ?? []) + extra
        let target = callback.url!
        Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
    }

    func close() {}
}

/// A test RSA key that signs ID tokens and publishes itself as a JWKS.
struct TestSigner {
    let privateKey: SecKey
    let jwks: String

    init() {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let (n, e) = Self.modulusAndExponent(der)
        jwks = "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"test\","
            + "\"n\":\"\(ChatGPTAuth.base64url(n))\",\"e\":\"\(ChatGPTAuth.base64url(e))\"}]}"
    }

    func token(_ claims: [String: Any]) -> String {
        let header = ChatGPTAuth.base64url(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]))
        let payload = ChatGPTAuth.base64url(try! JSONSerialization.data(withJSONObject: claims))
        let input = header + "." + payload
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)!
        return input + "." + ChatGPTAuth.base64url(signature as Data)
    }

    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    static func modulusAndExponent(_ der: Data) -> (Data, Data) {
        var i = der.startIndex
        func length() -> Int {
            let first = Int(der[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var n = 0
            for _ in 0..<(first & 0x7f) { n = n << 8 | Int(der[i]); i += 1 }
            return n
        }
        i += 1; _ = length()  // SEQUENCE
        i += 1; let nLen = length(); let n = der[i..<i + nLen]; i += nLen
        i += 1; let eLen = length(); let e = der[i..<i + eLen]
        return (Data(n), Data(e))
    }
}

@MainActor final class ChatGPTTests: XCTestCase {
    let signer = TestSigner()

    override func setUp() {
        RouteStub.seen = []
        RouteStub.routes = [:]
    }

    func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { a, _ in a })
    }

    func testFirstAuthorizationRegistersWithTheDocumentedParameters() {
        let a = ChatGPTAuth.attempt(clientID: nil, hostID: "urn:uuid:host", redirectURI: "http://127.0.0.1:1455/auth/callback",
                                    idTokenHint: "old", loginHint: "a@b.c")
        let q = query(a.url)
        XCTAssertEqual(a.url.host, "auth.openai.com")
        XCTAssertEqual(a.url.path, "/api/accounts/authorize")
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Unified Agent (spike)")
        XCTAssertEqual(q["ext_agent_host_id"], "urn:uuid:host")
        XCTAssertNil(q["id_token_hint"])  // hints only identify a returning account
        XCTAssertNil(q["login_hint"])
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(q["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(q["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], ChatGPTAuth.base64url(Data(SHA256.hash(data: Data(a.verifier.utf8)))))
        XCTAssertFalse(q["code_challenge"]!.contains("="))
        XCTAssertEqual(q["state"], a.state)
        XCTAssertEqual(q["nonce"], a.nonce)
        XCTAssertNil(q["prompt"])
        let b = ChatGPTAuth.attempt(clientID: nil, hostID: "urn:uuid:host", redirectURI: a.redirectURI)
        XCTAssertNotEqual(a.state, b.state)  // fresh per attempt
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertGreaterThanOrEqual(a.verifier.count, 43)
    }

    func testReauthorizationReusesTheIssuedClient() {
        let a = ChatGPTAuth.attempt(clientID: "oaiapp_x", hostID: "urn:uuid:host", redirectURI: "http://127.0.0.1:5000/auth/callback",
                                    idTokenHint: "id.tok.en", loginHint: "a+b@c.d", consent: true)
        let q = query(a.url)
        XCTAssertEqual(q["client_id"], "oaiapp_x")
        XCTAssertNil(q["agent_name_hint"])
        XCTAssertEqual(q["id_token_hint"], "id.tok.en")
        XCTAssertEqual(q["login_hint"], "a+b@c.d")  // "+" survives encoding
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertFalse(a.isRegistration)
    }

    func testCallbackChecksStateErrorsAndIssuedClient() throws {
        let reg = ChatGPTAuth.attempt(clientID: nil, hostID: "h", redirectURI: "http://127.0.0.1:1/auth/callback")
        func url(_ q: String) -> URL { URL(string: "http://127.0.0.1:1/auth/callback?" + q)! }
        XCTAssertThrowsError(try ChatGPTAuth.callback(url("code=c&state=wrong&client_id=oaiapp_1"), for: reg)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try ChatGPTAuth.callback(url("error=access_denied&state=\(reg.state)"), for: reg)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .declined)
        }
        XCTAssertThrowsError(try ChatGPTAuth.callback(url("code=c&state=\(reg.state)"), for: reg)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .incomplete)  // registration must return the issued ID
        }
        XCTAssertThrowsError(try ChatGPTAuth.callback(url("code=c&state=\(reg.state)&client_id=dynamic_agent_client"), for: reg))
        let ok = try ChatGPTAuth.callback(url("code=c&state=\(reg.state)&client_id=oaiapp_1"), for: reg)
        XCTAssertEqual(ok.code, "c")
        XCTAssertEqual(ok.clientID, "oaiapp_1")

        let again = ChatGPTAuth.attempt(clientID: "oaiapp_1", hostID: "h", redirectURI: "http://127.0.0.1:1/auth/callback")
        XCTAssertEqual(try ChatGPTAuth.callback(url("code=c&state=\(again.state)"), for: again).clientID, "oaiapp_1")
        XCTAssertThrowsError(try ChatGPTAuth.callback(url("code=c&state=\(again.state)&client_id=oaiapp_2"), for: again)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .clientMismatch)
        }
    }

    nonisolated static func claims(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["iss": "https://auth.openai.com", "aud": "oaiapp_test", "sub": "user-1", "email": "a@b.c", "nonce": "n1",
         "exp": Date().timeIntervalSince1970 + 3600, "iat": Date().timeIntervalSince1970].merging(changes) { $1 }
    }

    func testIDTokenSignatureAndClaimsAreVerified() throws {
        let jwks = Data(signer.jwks.utf8)
        func claims(_ changes: [String: Any] = [:]) -> [String: Any] { Self.claims(changes) }
        let good = try IDToken.verify(signer.token(claims()), jwks: jwks, clientID: "oaiapp_test", nonce: "n1")
        XCTAssertEqual(good.subject, "user-1")
        XCTAssertEqual(good.email, "a@b.c")
        XCTAssertNoThrow(try IDToken.verify(signer.token(claims(["aud": ["oaiapp_test"]])), jwks: jwks,
                                            clientID: "oaiapp_test", nonce: "n1"))
        let bad: [(String, String)] = [
            (signer.token(claims(["nonce": "other"])), "nonce"),
            (signer.token(claims(["aud": "dynamic_agent_client"])), "audience"),
            (signer.token(claims(["iss": "https://evil.example"])), "issuer"),
            (signer.token(claims(["exp": Date().timeIntervalSince1970 - 600])), "expired"),
            (TestSigner().token(claims()), "signature"),  // another key
        ]
        for (token, why) in bad {
            XCTAssertThrowsError(try IDToken.verify(token, jwks: jwks, clientID: "oaiapp_test", nonce: "n1")) {
                XCTAssertTrue($0.localizedDescription.contains(why), "\(why): \($0.localizedDescription)")
            }
        }
        var parts = signer.token(claims()).split(separator: ".").map(String.init)
        parts[1] = ChatGPTAuth.base64url(try JSONSerialization.data(withJSONObject: claims(["sub": "someone-else"])))
        XCTAssertThrowsError(try IDToken.verify(parts.joined(separator: "."), jwks: jwks, clientID: "oaiapp_test", nonce: "n1"))
    }

    func testLoopbackListenerTakesOnlyTheCallbackAndRedirectsToTheApp() async throws {
        let server = try await LoopbackCallback.start(ports: [0], doneURL: ChatGPTAuth.sheetCloseURL)
        defer { server.stop() }
        XCTAssertTrue(server.redirectURI.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(server.redirectURI.hasSuffix("/auth/callback"))
        let noFollow = NoRedirects()
        let session = URLSession(configuration: .ephemeral, delegate: noFollow, delegateQueue: nil)
        let (_, other) = try await session.data(from: URL(string: "http://127.0.0.1:\(server.port)/elsewhere")!)
        XCTAssertEqual((other as? HTTPURLResponse)?.statusCode, 404)
        let (_, response) = try await session.data(from: URL(string: server.redirectURI + "?code=abc&state=xyz")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Location"), ChatGPTAuth.sheetCloseURL)
        let url = try await server.callback()
        XCTAssertEqual(query(url)["code"], "abc")
        XCTAssertEqual(query(url)["state"], "xyz")
    }

    func testLoopbackWaitEndsWhenTheBrowserCloses() async throws {
        let server = try await LoopbackCallback.start(ports: [0], doneURL: ChatGPTAuth.sheetCloseURL)
        defer { server.stop() }
        server.fail(ChatGPTAuthError.cancelled)
        do { _ = try await server.callback(); XCTFail("expected cancel") } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .cancelled)
        }
    }

    /// The token endpoint and JWKS, answering a code exchange with an ID token for the attempt's nonce.
    func stubAuthServer(scope: String = ChatGPTAuth.scopes, sub: String = "user-1", browser: RedirectingBrowser) {
        RouteStub.routes["/.well-known/jwks.json"] = { [signer] _ in (200, "application/json", signer.jwks) }
        RouteStub.routes["/api/accounts/oauth/token"] = { [signer] seen in
            let form = RouteStub.form(seen)
            let id = signer.token(Self.claims(["aud": form["client_id"] ?? "", "nonce": RedirectingBrowser.nonce, "sub": sub]))
            let body: [String: Any] = ["access_token": "at_" + (form["grant_type"] ?? ""), "refresh_token": "rt_1",
                                       "id_token": id, "token_type": "Bearer", "expires_in": 3600, "scope": scope]
            return (200, "application/json", String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
    }

    func testSignInRegistersExchangesWithPKCEAndStoresTheIssuedClient() async throws {
        let store = MemoryChatGPTStore()
        let browser = RedirectingBrowser()
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        stubAuthServer(browser: browser)
        await account.signIn()
        XCTAssertNil(account.error)
        let c = try XCTUnwrap(store.credential)
        XCTAssertEqual(c.clientID, "oaiapp_test")  // never dynamic_agent_client
        XCTAssertEqual(c.subject, "user-1")
        XCTAssertEqual(c.email, "a@b.c")
        XCTAssertEqual(c.hostID, store.host)
        XCTAssertEqual(c.accessToken, "at_authorization_code")
        XCTAssertEqual(c.refreshToken, "rt_1")
        XCTAssertTrue(c.planEnabled)
        XCTAssertTrue(account.ready)

        let opened = query(try XCTUnwrap(browser.opened.first))
        let exchange = RouteStub.form(try XCTUnwrap(RouteStub.seen.first { $0.url.path == "/api/accounts/oauth/token" }))
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["client_id"], "oaiapp_test")
        XCTAssertEqual(exchange["code"], "code_123")
        XCTAssertEqual(exchange["redirect_uri"], opened["redirect_uri"])
        XCTAssertEqual(exchange["resource"], "https://api.openai.com/v1")
        XCTAssertNil(exchange["client_secret"])
        XCTAssertEqual(ChatGPTAuth.challenge(exchange["code_verifier"] ?? ""), opened["code_challenge"])

        // Signing in again: the saved client ID, the same host, the retained ID token as a hint.
        browser.issuedClientID = nil
        await account.signIn()
        XCTAssertNil(account.error)
        let second = query(try XCTUnwrap(browser.opened.last))
        XCTAssertEqual(second["client_id"], "oaiapp_test")
        XCTAssertEqual(second["ext_agent_host_id"], opened["ext_agent_host_id"])
        XCTAssertEqual(second["id_token_hint"], c.idToken)
        XCTAssertNil(second["agent_name_hint"])
    }

    func testSignInWithoutPlanScopeKeepsIdentityButIsNotReady() async throws {
        let store = MemoryChatGPTStore()
        let browser = RedirectingBrowser()
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        stubAuthServer(scope: "openid profile email offline_access", browser: browser)
        await account.signIn()
        XCTAssertTrue(try XCTUnwrap(store.credential).signedIn)
        XCTAssertFalse(account.ready)
        do { _ = try await account.accessToken(); XCTFail("plan use is not allowed") } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .declined)
        }
    }

    func testDeclinedConsentAndOtherAccountAreRejected() async throws {
        let store = MemoryChatGPTStore()
        let browser = RedirectingBrowser()
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        browser.extra = [URLQueryItem(name: "error", value: "access_denied")]
        stubAuthServer(browser: browser)
        await account.signIn()
        XCTAssertNil(store.credential)
        XCTAssertEqual(account.error, ChatGPTAuthError.declined.localizedDescription)
        XCTAssertFalse(RouteStub.seen.contains { $0.url.path == "/api/accounts/oauth/token" })  // no code exchange

        store.credential = ChatGPTCredential(email: "a@b.c", subject: "user-1", clientID: "oaiapp_test", hostID: "h",
                                             scopes: [], savedAt: Date())
        let returning = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        browser.extra = []
        browser.issuedClientID = nil
        stubAuthServer(sub: "user-2", browser: browser)
        await returning.signIn()
        XCTAssertEqual(returning.error, ChatGPTAuthError.accountMismatch.localizedDescription)
        XCTAssertNil(store.credential?.accessToken)  // the saved account was not overwritten
    }

    func expiring(_ store: MemoryChatGPTStore) -> ChatGPTCredential {
        let c = ChatGPTCredential(email: "a@b.c", subject: "user-1", clientID: "oaiapp_test", hostID: "urn:uuid:h",
                                  idToken: "id", accessToken: "at_old", refreshToken: "rt_old",
                                  expiresAt: Date().addingTimeInterval(60), scopes: ChatGPTAuth.scopes.split(separator: " ").map(String.init),
                                  savedAt: Date())
        store.credential = c
        return c
    }

    func testRefreshIsSerializedAndRotatesTheRefreshToken() async throws {
        let store = MemoryChatGPTStore()
        _ = expiring(store)
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { RedirectingBrowser() })
        RouteStub.routes["/api/accounts/oauth/token"] = { _ in
            (200, "application/json", "{\"access_token\":\"at_new\",\"refresh_token\":\"rt_new\",\"expires_in\":3600,"
             + "\"scope\":\"\(ChatGPTAuth.scopes)\"}")
        }
        async let a = account.accessToken()
        async let b = account.accessToken()
        let tokens = try await [a, b]
        XCTAssertEqual(tokens, ["at_new", "at_new"])
        let refreshes = RouteStub.seen.filter { $0.url.path == "/api/accounts/oauth/token" }
        XCTAssertEqual(refreshes.count, 1)
        let form = RouteStub.form(refreshes[0])
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["client_id"], "oaiapp_test")
        XCTAssertEqual(form["refresh_token"], "rt_old")
        XCTAssertEqual(form["resource"], "https://api.openai.com/v1")
        XCTAssertNil(form["scope"])
        XCTAssertEqual(store.credential?.refreshToken, "rt_new")
        let fresh = try await account.accessToken()  // not near expiry: no request
        XCTAssertEqual(fresh, "at_new")
        XCTAssertEqual(RouteStub.seen.count, 1)
    }

    func testUnusableRefreshTokenEndsTheSessionButKeepsTheRegistration() async throws {
        let store = MemoryChatGPTStore()
        _ = expiring(store)
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { RedirectingBrowser() })
        RouteStub.routes["/api/accounts/oauth/token"] = { _ in (400, "application/json", "{\"error\":\"invalid_grant\"}") }
        do { _ = try await account.accessToken(); XCTFail("expected sign in again") } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .signInAgain)
        }
        XCTAssertNil(store.credential?.refreshToken)
        XCTAssertEqual(store.credential?.clientID, "oaiapp_test")

        _ = expiring(store)
        let flaky = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { RedirectingBrowser() })
        RouteStub.routes["/api/accounts/oauth/token"] = { _ in (503, "text/plain", "busy") }
        do { _ = try await flaky.accessToken(); XCTFail("expected an error") } catch {}
        XCTAssertEqual(store.credential?.refreshToken, "rt_old")  // a temporary failure erases nothing
    }

    func testSignOutRevokesTheRefreshTokenAndKeepsTheMapping() async throws {
        let store = MemoryChatGPTStore()
        _ = expiring(store)
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { RedirectingBrowser() })
        RouteStub.routes["/api/accounts/oauth/revoke"] = { _ in (200, "text/plain", "") }
        let revoked = await account.signOut()
        XCTAssertTrue(revoked)
        let form = RouteStub.form(try XCTUnwrap(RouteStub.seen.first))
        XCTAssertEqual(form, ["token": "rt_old", "token_type_hint": "refresh_token", "client_id": "oaiapp_test"])
        let c = try XCTUnwrap(store.credential)
        XCTAssertNil(c.accessToken)
        XCTAssertNil(c.refreshToken)
        XCTAssertNil(c.idToken)  // no id_token_hint after signing out
        XCTAssertEqual(c.clientID, "oaiapp_test")
        XCTAssertEqual(c.hostID, "urn:uuid:h")
        XCTAssertFalse(account.ready)
    }


    func testClosingTheSheetCancelsWithoutSavingAnything() async throws {
        let store = MemoryChatGPTStore()
        let browser = ClosingBrowser()
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        stubAuthServer(browser: RedirectingBrowser())
        await account.signIn()
        XCTAssertNil(account.error)  // a cancel is not shown as an error
        XCTAssertNil(store.credential)
        XCTAssertFalse(account.busy)
        XCTAssertTrue(RouteStub.seen.isEmpty)  // no code exchange, no JWKS fetch
    }

    func testForgedStateIsRejectedBeforeAnyExchange() async throws {
        let store = MemoryChatGPTStore()
        let browser = ForgingBrowser()
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { browser }, ports: [0])
        stubAuthServer(browser: RedirectingBrowser())
        await account.signIn()
        XCTAssertEqual(account.error, ChatGPTAuthError.stateMismatch.localizedDescription)
        XCTAssertNil(store.credential)
        XCTAssertTrue(RouteStub.seen.isEmpty)
    }

    func testRefreshThatRacesSignOutDoesNotRestoreTokens() async throws {
        let store = MemoryChatGPTStore()
        _ = expiring(store)
        let account = ChatGPTAccount(store: store, session: RouteStub.session(), browser: { RedirectingBrowser() })
        let gate = DispatchSemaphore(value: 0)
        RouteStub.held["/api/accounts/oauth/token"] = gate
        defer { RouteStub.held = [:] }
        RouteStub.routes["/api/accounts/oauth/token"] = { _ in
            return (200, "application/json", "{\"access_token\":\"at_new\",\"refresh_token\":\"rt_new\",\"expires_in\":3600}")
        }
        RouteStub.routes["/api/accounts/oauth/revoke"] = { _ in (200, "text/plain", "") }
        let pending = Task { try await account.accessToken() }
        for _ in 0..<200 where !RouteStub.seen.contains(where: { $0.url.path == "/api/accounts/oauth/token" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await account.signOut()
        gate.signal()
        do { _ = try await pending.value; XCTFail("a refresh after sign-out must not succeed") } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .notSignedIn)
        }
        XCTAssertNil(store.credential?.accessToken)
        XCTAssertNil(store.credential?.refreshToken)
        XCTAssertFalse(account.ready)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The user closes the sign-in sheet: no redirect ever reaches the listener.
@MainActor final class ClosingBrowser: ChatGPTBrowser {
    func open(_ url: URL, onEnd: @escaping @MainActor @Sendable () -> Void) throws { Task { @MainActor in onEnd() } }
    func close() {}
}

/// A redirect with a code but someone else's state (a forged or replayed callback).
@MainActor final class ForgingBrowser: ChatGPTBrowser {
    func open(_ url: URL, onEnd: @escaping @MainActor @Sendable () -> Void) throws {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        var callback = URLComponents(string: query.first { $0.name == "redirect_uri" }!.value!)!
        callback.queryItems = [URLQueryItem(name: "code", value: "code_x"), URLQueryItem(name: "state", value: "forged"),
                               URLQueryItem(name: "client_id", value: "oaiapp_attacker")]
        let target = callback.url!
        Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
    }
    func close() {}
}
