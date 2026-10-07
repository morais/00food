import AuthenticationServices
import CryptoKit
import SwiftUI

struct SignInView: View {
    @Environment(FoodStore.self) private var store
    @State private var nonce = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var showingAgentSetup = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer()
                Image("BrandMark")
                    .resizable().scaledToFit()
                    .frame(width: 152, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                Image("BrandWordmark")
                    .resizable().scaledToFit().frame(width: 240, height: 76)
                Text("Your food log. Your AI agent.")
                    .font(.headline).multilineTextAlignment(.center)
                Text("Bring your own AI agent to estimate foods and help you review your day. You approve the estimates and build your own food library.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("No built-in food catalogue or bundled AI agent. Manual logging is always available.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("See how to connect your agent") { showingAgentSetup = true }
                    .font(.subheadline)
                Spacer()
                SignInWithAppleButton(.signIn, onRequest: { request in
                    nonce = Self.makeNonce()
                    request.requestedScopes = [.email]
                    request.nonce = Self.hash(nonce)
                }, onCompletion: { result in
                    switch result {
                    case .failure(let error): errorText = error.localizedDescription
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let identityData = credential.identityToken,
                              let codeData = credential.authorizationCode,
                              let identityToken = String(data: identityData, encoding: .utf8),
                              let code = String(data: codeData, encoding: .utf8), !nonce.isEmpty else {
                            errorText = "Apple did not return a usable sign-in. Please try again."
                            return
                        }
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await store.signIn(identityToken: identityToken, code: code, nonce: nonce) }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                })
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52).disabled(busy)
                if busy { ProgressView("Signing in…") }
                Text("You choose your agent and what to share. Health history stays on your device unless you request daily feedback.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingAgentSetup) { AgentSetupView() }
        .alert("Could not sign in", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    static func makeNonce() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
