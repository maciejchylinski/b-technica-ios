import Foundation
import Supabase
import SwiftUI

/// Owns the Supabase Auth session for the process.
///
/// Session tokens are persisted by the SDK in the Keychain, so a previously
/// signed-in user can start the app offline and still enter the main UI.
@MainActor
final class AuthStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case signedOut
        case signedIn
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var session: Session?
    @Published private(set) var authError: String?
    @Published private(set) var isBusy = false

    /// Stable account id for local storage isolation. Nil when signed out.
    var userId: UUID? {
        session?.user.id
    }

    var userEmail: String? {
        session?.user.email
    }

    private var authTask: Task<Void, Never>?
    /// Bumped on explicit password sign-in so AppGate rebuilds the workspace
    /// even when the same account signs back in after sign-out.
    private(set) var workspaceEpoch: Int = 0
    /// Set only around password sign-in so Keychain session restore cannot claim
    /// unowned pre-auth Documents for whichever account happens to restore first.
    private var adoptLegacyOnNextWorkspace = false

    init() {
        authTask = Task { await observeAuth() }
    }

    deinit {
        authTask?.cancel()
    }

    /// Whether the next workspace build should run one-time legacy adoption.
    func consumeLegacyAdoptionIntent() -> Bool {
        let value = adoptLegacyOnNextWorkspace
        adoptLegacyOnNextWorkspace = false
        return value
    }

    func signIn(email: String, password: String) async {
        authError = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            authError = "Enter email and password."
            return
        }
        guard SupabaseManager.isConfigured else {
            authError = "Supabase is not configured on this build."
            return
        }

        isBusy = true
        defer { isBusy = false }
        // Set before await so a signedIn event during sign-in still adopts.
        adoptLegacyOnNextWorkspace = true
        do {
            _ = try await SupabaseManager.client.auth.signIn(
                email: trimmed,
                password: password
            )
            workspaceEpoch &+= 1
        } catch {
            adoptLegacyOnNextWorkspace = false
            authError = Self.friendlyMessage(for: error)
        }
    }

    func signOut() async {
        authError = nil
        adoptLegacyOnNextWorkspace = false
        isBusy = true
        defer { isBusy = false }
        do {
            try await SupabaseManager.client.auth.signOut()
        } catch {
            // Still clear local session UI if the network call fails.
            session = nil
            phase = .signedOut
            authError = Self.friendlyMessage(for: error)
        }
    }

    func dismissError() {
        authError = nil
    }

    private func observeAuth() async {
        guard SupabaseManager.isConfigured else {
            phase = .signedOut
            authError = "Supabase is not configured on this build."
            return
        }

        for await (event, session) in SupabaseManager.client.auth.authStateChanges {
            apply(event: event, session: session)
        }
    }

    private func apply(event: AuthChangeEvent, session: Session?) {
        self.session = session
        switch event {
        case .initialSession:
            phase = session == nil ? .signedOut : .signedIn
        case .signedIn, .tokenRefreshed, .userUpdated:
            phase = session == nil ? .signedOut : .signedIn
        case .signedOut:
            phase = .signedOut
            self.session = nil
        default:
            phase = session == nil ? .signedOut : .signedIn
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("invalid login") || lower.contains("invalid credentials") {
            return "Incorrect email or password."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet") {
            return "Network error. Check your connection and try again."
        }
        return text
    }
}
