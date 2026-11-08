import SwiftUI

/// Email/password sign-in. No public registration.
struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sign in to B Technica")
                        .font(.title2.weight(.semibold))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 8, trailing: 0))
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(auth.isBusy)
                        .focused($focusedField, equals: .email)
                        .accessibilityIdentifier("loginEmailField")

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .disabled(auth.isBusy)
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("loginPasswordField")
                }

                if let message = auth.authError {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                            .accessibilityIdentifier("loginErrorLabel")
                            .accessibilityLabel(message)
                    }
                }

                Section {
                    Button {
                        focusedField = nil
                        Task {
                            await auth.signIn(email: email, password: password)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if auth.isBusy {
                                ProgressView()
                            } else {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .frame(minHeight: Theme.touchTarget - 16)
                    }
                    .disabled(auth.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("loginSignInButton")
                }

                #if DEBUG
                Section {
                    Button {
                        DemoModeController.shared.enter()
                    } label: {
                        Label("Open demo projects", systemImage: "theatermasks")
                    }
                    .accessibilityIdentifier("openDemoButton")
                } footer: {
                    Text("DEBUG only: fictional local data, no sign-in and no Supabase sync.")
                }
                #endif
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("loginScreen")
        }
        .tint(Theme.blue)
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthStore())
}
