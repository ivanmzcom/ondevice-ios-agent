#if DEBUG
import AuthenticationServices
import Security
import SwiftUI
import UIKit
import UnifiedAgentCore

// EXPERIMENTAL, Debug builds only: Sign in with ChatGPT and ChatGPT plan usage (CHATGPT_AUTH_GATE.md). The on-device
// 127.0.0.1 redirect has never been verified on an iPhone; the owner must validate a real sign-in.

/// The ChatGPT credential and this install's host ID, in this app's own Keychain items (separate from APIKeyStore;
/// this device only, never backed up). Reads nothing but its own two items.
final class KeychainChatGPTStore: ChatGPTStore {
    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: (Bundle.main.bundleIdentifier ?? "unified-agent") + ".chatgpt",
         kSecAttrAccount: account]
    }
    private func get(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    private func set(_ data: Data?, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return }
        var q = query(account)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func load() -> ChatGPTCredential? { get("credential").flatMap { try? JSONDecoder().decode(ChatGPTCredential.self, from: $0) } }
    func save(_ credential: ChatGPTCredential?) { set(credential.flatMap { try? JSONEncoder().encode($0) }, "credential") }
    func hostID() -> String {
        if let d = get("host-id"), !d.isEmpty { return String(decoding: d, as: UTF8.self) }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        set(Data(id.utf8), "host-id")
        return id
    }
}

/// ASWebAuthenticationSession (the system sign-in sheet). The authorization server redirects to the in-app
/// 127.0.0.1 listener, which answers with a redirect to this app's own scheme so the sheet closes.
@MainActor final class SystemChatGPTBrowser: NSObject, ChatGPTBrowser, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ url: URL, onEnd: @escaping @MainActor @Sendable () -> Void) throws {
        let done: ASWebAuthenticationSession.CompletionHandler = { _, _ in Task { @MainActor in onEnd() } }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(url: url, callback: .customScheme(ChatGPTAuth.sheetCloseScheme), completionHandler: done)
        } else {
            session = ASWebAuthenticationSession(url: url, callbackURLScheme: ChatGPTAuth.sheetCloseScheme, completionHandler: done)
        }
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else { throw ChatGPTAuthError.incomplete }
    }

    func close() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Section 5b: Continue with ChatGPT, the signed-in account, its model catalog, usage and sign-out.
struct ChatGPTPlanSection: View {
    @ObservedObject var model: AgentAppModel
    @ObservedObject var account: ChatGPTAccount
    // EXPERIMENTAL Fast mode: own key, default off, read by ResponsesClient on every request.
    @AppStorage(ResponsesClient.fastPreferenceKey) private var fastMode = false
    @AppStorage(ResponsesClient.lastRequestedTierKey) private var lastRequestedTier = ""
    @AppStorage(ResponsesClient.lastConfirmedTierKey) private var lastConfirmedTier = ""

    var body: some View {
        Section("5b. ChatGPT plan (EXPERIMENTAL, Debug only)") {
            Text("Unverified on iPhone: sign-in uses a 127.0.0.1 callback inside this app. If the sign-in sheet cannot reach it, this path is blocked; do not try other redirects.")
                .font(.caption2).foregroundStyle(.orange)
            if let c = account.credential, c.signedIn {
                LabeledContent("Account", value: c.email ?? c.subject)
                LabeledContent("Plan use", value: c.planEnabled ? "allowed" : "not allowed (sign in again and allow it)")
                if !c.planEnabled {
                    Button("Sign in again and allow plan use") { Task { await account.signIn(consent: true) } }.disabled(account.busy)
                }
                Toggle("Use ChatGPT plan for tasks (no API key, no fallback)", isOn: $model.useChatGPTPlan)
                Picker("Plan model", selection: $model.chatGPTModelID) {
                    Text(model.chatGPTModelID.isEmpty ? "none" : model.chatGPTModelID).tag(model.chatGPTModelID)
                    ForEach(model.chatGPTModels.filter { $0 != model.chatGPTModelID }, id: \.self) { Text($0).tag($0) }
                }
                Button("Load model catalog") { model.loadChatGPTModels() }.disabled(!account.ready)
                Toggle("Modo Fast (EXPERIMENTAL)", isOn: $fastMode)
                Text("Pide service_tier \"fast\" con el mismo modelo y la misma cuenta. No está verificado que tu plan de ChatGPT lo admita: puede rechazarse (la tarea falla, sin reintento ni otra vía) o consumir el uso de tu cuenta de otra forma. Sin promesas de velocidad ni de coste.")
                    .font(.caption2).foregroundStyle(.orange)
                LabeledContent("Tier solicitado (última petición)", value: lastRequestedTier.isEmpty ? "ninguno (omitido)" : lastRequestedTier)
                LabeledContent("Tier confirmado por el servidor", value: lastConfirmedTier.isEmpty ? "no confirmado" : lastConfirmedTier)
                if !model.chatGPTStatus.isEmpty { Text(model.chatGPTStatus).font(.footnote) }
                if !model.chatGPTUsage.isEmpty { Text("Last run: \(model.chatGPTUsage)").font(.caption.monospaced()) }
                Link("Manage usage", destination: ChatGPTAuth.usageURL)
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }.disabled(account.busy)
            } else {
                Button("Continue with ChatGPT") { Task { await account.signIn() } }.disabled(account.busy)
                if account.credential != nil {
                    Button("Forget saved registration", role: .destructive) { Task { await account.forget() } }.disabled(account.busy)
                }
            }
            if account.busy { ProgressView() }
            if let e = account.error { Text(e).font(.footnote).foregroundStyle(.red) }
        }
    }
}
#endif
