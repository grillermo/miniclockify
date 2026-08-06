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

    /// Best deduped description to autocomplete `query` to: prefer one that
    /// begins with `query`, else fall back to one that merely contains it (so
    /// "bill" can complete to "Create billing system"). In both cases the match
    /// must differ from `query` (something left to complete). Nil when the query
    /// is empty or nothing matches.
    static func firstAutocomplete(descriptions: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        let deduped = filter(descriptions: descriptions, query: "")
        if let prefix = deduped.first(where: {
            let dl = $0.lowercased(); return dl.hasPrefix(lower) && dl != lower
        }) { return prefix }
        return deduped.first {
            let dl = $0.lowercased()
            return dl != lower && dl.range(of: lower) != nil
        }
    }

    /// Fetch recent entry descriptions, most-recent-first, via the API.
    static func fetch(api: ClockifyAPI, workspaceId: String, userId: String) async -> [String] {
        let entries = (try? await api.recentTimeEntries(workspaceId: workspaceId, userId: userId)) ?? []
        return entries.map(\.description)
    }
}
