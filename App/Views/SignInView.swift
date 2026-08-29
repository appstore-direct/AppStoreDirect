import AppStoreDirectKit
import SwiftUI

/// Apple Account sign-in, including the two-factor step.
///
/// The password lives in this view's state only for as long as the sheet is open,
/// and is cleared the moment sign-in succeeds. It is never written to disk.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if model.needsTwoFactorCode {
                twoFactorFields
            } else {
                credentialFields
            }

            if let error = model.signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("""
            Sign-in goes directly to Apple. Your password is used once and never saved — \
            only the session Apple returns is kept, in your Keychain.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.needsTwoFactorCode ? "Verify" : "Sign In") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 420)
        .overlay {
            if model.isSigningIn {
                Color.black.opacity(0.05)
                ProgressView().controlSize(.large)
            }
        }
        .onAppear { focus = model.needsTwoFactorCode ? .code : .email }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if signedIn {
                password = ""
                code = ""
                dismiss()
            }
        }
        .onChange(of: model.needsTwoFactorCode) { _, needsCode in
            if needsCode { focus = .code }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.needsTwoFactorCode ? "Two-Factor Authentication" : "Sign In with your Apple Account")
                .font(.title2.weight(.semibold))
            Text(model.needsTwoFactorCode
                 ? "Enter the six-digit code shown on your trusted device."
                 : "Apps are installed using your own Apple Account.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialFields: some View {
        VStack(spacing: 10) {
            TextField("Apple Account email", text: $email)
                .textContentType(.username)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(submit)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var twoFactorFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Account", value: email)
            TextField("Verification code", text: $code)
                .textContentType(.oneTimeCode)
                .font(.system(.title3, design: .monospaced))
                .focused($focus, equals: .code)
                .onSubmit(submit)
                .onChange(of: code) { _, newValue in
                    // Apple sends six digits; strip anything pasted around them.
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { code = String(digits.prefix(6)) }
                    else if digits.count > 6 { code = String(digits.prefix(6)) }
                }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var canSubmit: Bool {
        guard !model.isSigningIn else { return false }
        return model.needsTwoFactorCode
            ? code.count == 6
            : (!email.isEmpty && !password.isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            await model.signIn(
                email: email,
                password: password,
                code: model.needsTwoFactorCode ? code : nil
            )
        }
    }
}
