import Foundation
import Supabase

/// Shared Supabase client for the app process (anon key only).
enum SupabaseManager {
    static let client: SupabaseClient = {
        do {
            let url = try SupabaseConfig.makeURL()
            let key = try SupabaseConfig.makeAnonKey()
            return SupabaseClient(supabaseURL: url, supabaseKey: key)
        } catch {
            // Build a clearly broken placeholder so the app can still launch and
            // surface a configuration error on the login screen.
            assertionFailure("Supabase configuration missing: \(error)")
            return SupabaseClient(
                supabaseURL: URL(string: "https://invalid.local")!,
                supabaseKey: "missing-anon-key"
            )
        }
    }()

    static var isConfigured: Bool {
        (try? SupabaseConfig.makeURL()) != nil && (try? SupabaseConfig.makeAnonKey()) != nil
    }
}
