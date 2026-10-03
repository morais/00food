import AuthenticationServices
import SwiftUI

struct DeleteAccountView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var nonce = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "trash").font(.largeTitle).foregroundStyle(.red)
                Text("Verify with Apple to delete your 00Food account and all food data.")
                    .multilineTextAlignment(.center)
                SignInWithAppleButton(.continue, onRequest: { request in
                    nonce = SignInView.makeNonce()
                    request.nonce = SignInView.hash(nonce)
                }, onCompletion: { result in
                    switch result {
                    case .failure(let error): errorText = error.localizedDescription
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let identityData = credential.identityToken,
                              let codeData = credential.authorizationCode,
                              let identityToken = String(data: identityData, encoding: .utf8),
                              let code = String(data: codeData, encoding: .utf8) else {
                            errorText = "Apple did not return a usable sign-in."
                            return
                        }
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await store.deleteAccount(identityToken: identityToken, code: code, nonce: nonce); dismiss() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                })
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52).disabled(busy)
                if busy { ProgressView("Deleting…") }
                Spacer()
            }
            .padding(28)
            .navigationTitle("Delete account")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .alert("Could not delete account", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }
}
