import Foundation

/// Workspaces that must never talk to Supabase.
///
/// The only one is the DEBUG demo workspace (`DemoMode.userId`): its projects, drawings and
/// outbox rows are fictional and exist only in a separate local database. Every sync entry
/// point checks this before touching the network. Release builds have no local-only users.
enum LocalOnlyWorkspace {
    static func isLocalOnly(userId: UUID) -> Bool {
        #if DEBUG
        return userId == DemoMode.userId
        #else
        return false
        #endif
    }
}
