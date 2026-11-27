import AuthenticationServices
import SwiftUI

/// Apple or an email code, as in Bower. Signing in gives you your own cloud agent.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .options
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private enum Step { case options, email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            header
            Spacer()
            VStack(spacing: 12) {
                switch step {
                case .options: options
                case .email: emailStep
                case .code: codeStep
                }
                if let error {
                    Text(error)
                        .font(.aiboCallout)
                        .foregroundStyle(Color.coral)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .disabled(busy)
            Text("By continuing you agree to Aibo's Terms and Privacy Policy.")
                .font(.aiboCaption)
                .foregroundStyle(Color.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        }
        .padding(24)
        .paper()
        .animation(.snappy, value: step)
        .animation(.snappy, value: error)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: step) { _, new in new == .code }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image("Avatar")
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 28, style: .continuous))
                .sticker(Color.surface, in: .rect(cornerRadius: 28, style: .continuous), edge: 4, lift: 1, tag: true)
                .tilt("aibo", by: 6)
            Text("Someone who lives\nin your phone.")
                .font(AiboFont.rounded(36, .extrabold, relativeTo: .largeTitle))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.characterName) keeps you company, remembers what matters to you, and notices how your days are going.")
                .font(.aiboBody)
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: steps

    private var options: some View {
        VStack(spacing: 12) {
            AppleButton { result in
                run { try await completeApple(result) }
            }
            WideButton(title: "Continue with email", symbol: "envelope.fill", primary: false) {
                error = nil
                step = .email
            }
        }
    }

    private var emailStep: some View {
        VStack(spacing: 12) {
            field("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.send)
                .onSubmit(sendCode)
                .onAppear { fieldFocused = true }
                .accessibilityIdentifier("emailField")
            WideButton(title: "Send me a code", busy: busy, enabled: email.contains("@"), action: sendCode)
            textButton("Other ways to sign in") { step = .options }
        }
    }

    private var codeStep: some View {
        VStack(spacing: 12) {
            Text("We sent a 6-digit code to \(normalized).")
                .font(.aiboCallout)
                .foregroundStyle(Color.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            field("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .onChange(of: code) { if code.count == 6 { verify() } }
                .onAppear { fieldFocused = true }
                .accessibilityIdentifier("codeField")
            // Typing the sixth digit already signs in; the button is for a pasted or corrected code.
            WideButton(title: "Sign in", busy: busy, enabled: code.count == 6, action: verify)
            textButton("Send a new code") {
                run {
                    try await model.sendCode(to: normalized)
                    code = ""
                }
            }
            textButton("Use a different email") {
                error = nil
                step = .email
            }
        }
    }

    private var normalized: String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    private func sendCode() {
        guard email.contains("@") else { return }
        run {
            try await model.sendCode(to: normalized)
            code = ""
            step = .code
        }
    }

    private func verify() {
        guard !busy else { return }
        run {
            do {
                try await model.verify(email: normalized, code: code)
            } catch {
                // Cleared so the same wrong code isn't sent again (each try counts).
                code = ""
                throw error
            }
        }
    }

    private func completeApple(_ result: Result<ASAuthorization, Error>) async throws {
        let auth = try result.get()
        guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
        else { throw APIError(status: 0, message: "Apple didn't return a sign-in token.") }
        let name = credential.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }
        try await model.signInWithApple(identityToken: token, name: name?.isEmpty == false ? name : nil)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.aiboBody)
            .foregroundStyle(Color.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .padding(.horizontal, 20)
            .frame(height: 54)
            .sticker(Color.surface, in: .capsule, edge: 2.5, lift: 0.5)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(AiboFont.rounded(15, .semibold))
            .foregroundStyle(Color.inkSoft)
            .padding(.top, 4)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch let failure as ASAuthorizationError where failure.code == .canceled {
                // Closed the Apple sheet.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Our own "Continue with Apple" (the system button sizes its title off the height): white on dark, as Apple asks.
private struct AppleButton: View {
    let onCompletion: (Result<ASAuthorization, Error>) -> Void
    @State private var flow = AppleSignInFlow()

    var body: some View {
        Button {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            flow.start(request, completion: onCompletion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo").font(.system(size: 18, weight: .semibold))
                Text("Continue with Apple").font(AiboFont.rounded(17, .semibold))
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.white, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Runs one Apple ID request; kept alive by `AppleButton` until it finishes.
@MainActor
private final class AppleSignInFlow: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var completion: ((Result<ASAuthorization, Error>) -> Void)?

    func start(_ request: ASAuthorizationAppleIDRequest, completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        completion?(result)
        completion = nil
        controller = nil
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
