import Foundation

enum RecentDescriptions {
    /// Pure: dedup case-insensitively (first occurrence wins, original casing
    /// kept), drop blank, filter by case-insensitive substring. Matches spec §6.
    static func filter(descriptions: [String], query: String) -> [String] {
        var seen = Set<String>()      // lowercased keys
        var result: [String] = []
        for d in descriptions {
            let trimmed = d.trimmingCharacters(in: .whitespaces)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        guard !query.isEmpty else { return result }
        return result.filter { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    /// Fetch recent entry descriptions, most-recent-first, via the API.
    static func fetch(api: ClockifyAPI, workspaceId: String, userId: String) async -> [String] {
        let entries = (try? await api.recentTimeEntries(workspaceId: workspaceId, userId: userId)) ?? []
        return entries.map(\.description)
    }
}
