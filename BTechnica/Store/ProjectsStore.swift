import Foundation
import Supabase
import SwiftUI

/// Loads and creates cloud projects for the signed-in user via Supabase RLS.
/// Selection opens a local workspace bound to that cloud project id.
@MainActor
final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [CloudProject] = []
    @Published private(set) var selectedProjectId: UUID?
    /// When true, AppGate presents the Home/Drawings/Issues/More workspace.
    @Published private(set) var isWorkspaceOpen = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    private var userId: UUID?

    var selectedProject: CloudProject? {
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }
    }

    func bind(userId: UUID?) {
        guard self.userId != userId else { return }
        self.userId = userId
        projects = []
        selectedProjectId = nil
        isWorkspaceOpen = false
        errorMessage = nil
    }

    /// - Parameter reopenWorkspace: When true (cold start / sign-in), open the local
    ///   workspace for the restored selection. Pull-to-refresh and Switch Project use false
    ///   so an intentional return to the list is not overridden.
    func load(reopenWorkspace: Bool = false) async {
        guard let userId else { return }
        guard SupabaseManager.isConfigured else {
            errorMessage = "Supabase is not configured on this build."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let projectsTask: [CloudProject] = SupabaseManager.client
                .from("projects")
                .select("id,name,owner_id,created_at")
                .order("created_at", ascending: false)
                .execute()
                .value

            async let profileTask: ProfileActiveProject = SupabaseManager.client
                .from("profiles")
                .select("active_project_id")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            let loaded = try await projectsTask
            let profile = try await profileTask
            projects = loaded

            let cached = localCachedSelection(for: userId)
            let preferred = profile.activeProjectId ?? cached
            if let preferred, loaded.contains(where: { $0.id == preferred }) {
                selectedProjectId = preferred
                cacheLocalSelection(preferred, for: userId)
                if reopenWorkspace {
                    isWorkspaceOpen = true
                }
            } else if let current = selectedProjectId,
                      loaded.contains(where: { $0.id == current }) {
                if reopenWorkspace {
                    isWorkspaceOpen = true
                }
            } else {
                selectedProjectId = nil
                isWorkspaceOpen = false
                clearLocalSelection(for: userId)
            }
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            if reopenWorkspace,
               let selectedProjectId,
               projects.contains(where: { $0.id == selectedProjectId }) {
                isWorkspaceOpen = true
            }
        }
    }

    /// Creates a project owned by the signed-in user. Owner membership is added by a DB trigger.
    @discardableResult
    func create(name: String) async -> Bool {
        guard let userId else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a project name."
            return false
        }
        guard SupabaseManager.isConfigured else {
            errorMessage = "Supabase is not configured on this build."
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let inserted: CloudProject = try await SupabaseManager.client
                .from("projects")
                .insert(ProjectInsert(name: trimmed, ownerId: userId))
                .select("id,name,owner_id,created_at")
                .single()
                .execute()
                .value

            if projects.contains(where: { $0.id == inserted.id }) == false {
                projects.insert(inserted, at: 0)
            }
            await select(inserted)
            return true
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    /// Selects a cloud project, persists it as active, and opens its local workspace.
    func select(_ project: CloudProject) async {
        guard let userId else { return }
        guard projects.contains(where: { $0.id == project.id }) else { return }
        guard SupabaseManager.isConfigured else {
            errorMessage = "Supabase is not configured on this build."
            return
        }

        let previous = selectedProjectId
        selectedProjectId = project.id
        isWorkspaceOpen = true
        cacheLocalSelection(project.id, for: userId)
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            try await SupabaseManager.client
                .from("profiles")
                .update(ActiveProjectUpdate(activeProjectId: project.id))
                .eq("id", value: userId.uuidString)
                .execute()
        } catch {
            // Keep workspace open with local cache even if profile update fails.
            if previous != project.id {
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    /// Returns to the projects list without clearing the last selected project id.
    func leaveWorkspace() {
        isWorkspaceOpen = false
    }

    func dismissError() {
        errorMessage = nil
    }

    private func localSelectionKey(for userId: UUID) -> String {
        "projects.activeProjectId.\(userId.uuidString)"
    }

    private func cacheLocalSelection(_ projectId: UUID, for userId: UUID) {
        UserDefaults.standard.set(projectId.uuidString, forKey: localSelectionKey(for: userId))
    }

    private func clearLocalSelection(for userId: UUID) {
        UserDefaults.standard.removeObject(forKey: localSelectionKey(for: userId))
    }

    private func localCachedSelection(for userId: UUID) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: localSelectionKey(for: userId)) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private static func friendlyMessage(for error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet") {
            return "Network error. Check your connection and try again."
        }
        return text
    }
}

private struct ProjectInsert: Encodable {
    let name: String
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case ownerId = "owner_id"
    }
}

private struct ActiveProjectUpdate: Encodable {
    let activeProjectId: UUID

    enum CodingKeys: String, CodingKey {
        case activeProjectId = "active_project_id"
    }
}

private struct ProfileActiveProject: Decodable {
    let activeProjectId: UUID?

    enum CodingKeys: String, CodingKey {
        case activeProjectId = "active_project_id"
    }
}
