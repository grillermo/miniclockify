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

    /// First deduped description that begins with `query` (case-insensitive) and
    /// is strictly longer, i.e. has a non-empty completion to offer. Returns nil
    /// when nothing to autocomplete (empty query, no prefix match, or exact hit).
    static func firstPrefixMatch(descriptions: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        return filter(descriptions: descriptions, query: "").first {
            let dl = $0.lowercased()
            return dl.hasPrefix(lower) && dl != lower
        }
    }

    /// Fetch recent entry descriptions, most-recent-first, via the API.
    static func fetch(api: ClockifyAPI, workspaceId: String, userId: String) async -> [String] {
        let entries = (try? await api.recentTimeEntries(workspaceId: workspaceId, userId: userId)) ?? []
        return entries.map(\.description)
    }
}
