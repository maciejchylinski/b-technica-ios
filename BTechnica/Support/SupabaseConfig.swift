import Foundation

/// Reads Supabase client settings injected at build time via Info.plist.
/// Never embeds the service_role key.
enum SupabaseConfig {
    enum ConfigError: LocalizedError {
        case missingURL
        case missingAnonKey
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .missingURL:
                return "Supabase URL is not configured. Add Config/Secrets.xcconfig from the example file."
            case .missingAnonKey:
                return "Supabase anon key is not configured. Add Config/Secrets.xcconfig from the example file."
            case .invalidURL(let value):
                return "Supabase URL is invalid: \(value)"
            }
        }
    }

    static var urlString: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
    }

    static var anonKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
    }

    static func makeURL() throws -> URL {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ConfigError.missingURL
        }
        guard let url = URL(string: raw) else {
            throw ConfigError.invalidURL(raw)
        }
        return url
    }

    static func makeAnonKey() throws -> String {
        guard let key = anonKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ConfigError.missingAnonKey
        }
        return key
    }
}
