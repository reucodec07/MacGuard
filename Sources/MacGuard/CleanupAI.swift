import Foundation

// MARK: — AI-enhanced cleanup analysis
// Haiku runs AFTER the rule engine — it reviews what the rules found
// and can improve reasoning, reclassify borderline items, and surface
// things the rules missed (e.g. old project folders, named installers).
//
// Architecture:
//   1. Rule engine runs → produces [CleanupItem]
//   2. AICleanupAnalyser.enhance() sends a compact manifest to Haiku
//   3. Haiku returns a JSON array of overrides (only items it wants to change)
//   4. We merge: rule result + AI overrides → final [CleanupItem]
//
// If the API call fails for any reason, the rule engine results are used as-is.
// Haiku is enhancement only — never a dependency.

struct AIOverride: Codable {
    let path:     String          // file path to match against
    let safety:   String          // "safe" | "caution" | "review"
    let category: String          // CleanupCategory rawValue
    let reason:   String          // plain English explanation shown to user
    let include:  Bool            // false = remove from suggestions entirely
    let confidence: Int?            // 0-100, nil = keep rule engine score
}

struct AICleanupResponse: Codable {
    let overrides:    [AIOverride]
    let extraPaths:   [AIExtraPath]  // paths Haiku thinks should be added
}

struct AIExtraPath: Codable {
    let path:     String
    let safety:   String
    let category: String
    let reason:   String
    let sizeMB:   Double   // estimated — Haiku can't read disk, we verify
}

class AICleanupAnalyser {

    // MARK: — Main entry point

    // enhance() takes the rule engine's results and the root URL,
    // calls Haiku with a compact manifest, then merges AI overrides back in.
    // Calls completion on the main thread with the enhanced list.
    func enhance(
        items:   [CleanupItem],
        rootURL: URL,
        apiKey:  String,
        completion: @escaping ([CleanupItem], String?) -> Void  // items, optional AI summary
    ) {
        guard !items.isEmpty else {
            DispatchQueue.main.async { completion(items, nil) }
            return
        }

        // Build a compact manifest — just path, size, current classification
        // We deliberately don't send file contents, only metadata
        let manifest = items.prefix(30).map { item in  // cap at 30 — keeps response under token limit
            [
                "path":     item.url.path,
                "sizeMB":   String(format: "%.1f", Double(item.size) / 1_048_576.0),
                "category": item.category.rawValue,
                "safety":   safetyString(item.safety),
                "reason":   item.reason
            ]
        }

        let systemPrompt = """
You are a macOS disk cleanup expert. You receive a JSON manifest of files/folders \
identified by a rule-based scanner. Your job is to:

1. Review each item and improve the classification if the rule engine was too conservative or too aggressive.
2. Flag items the rules likely missed (e.g. Xcode DerivedData in non-standard paths, old project \
node_modules, Docker volumes, simulator runtimes, old iOS backups, large unused VM disk images).
3. Identify items that should be REMOVED from suggestions (set include: false) because they look \
important (e.g. a file named "final-project-backup.zip" or "passport-scan.pdf").

Rules you must follow:
- Only improve reasoning — never invent files that weren't listed
- Be conservative: when unsure, prefer caution over safe
- Keep reasons SHORT (under 15 words), plain English, user-friendly
- extraPaths should only be paths you are highly confident exist on this Mac given the root path
- Maximum 5 extraPaths suggestions

Respond ONLY with valid JSON in exactly this format, no preamble, no markdown:
{
  "overrides": [
    {"path": "/exact/path", "safety": "safe|caution|review", "category": "Cache|Log|Temporary|Download|Large Media|App Data|User File|Other", "reason": "short reason", "include": true}
  ],
  "extraPaths": [
    {"path": "/suggested/path", "safety": "safe|caution|review", "category": "Cache", "reason": "short reason", "sizeMB": 0}
  ],
  "summary": "one sentence about what was found overall"
}
"""

        let userMessage = """
Root folder scanned: \(rootURL.path)

Items found by rule engine:
\((try? String(data: JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted), encoding: .utf8)) ?? "[]")
"""

        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 3000,
            "system":     systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(items, nil) }
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json",       forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                   forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",             forHTTPHeaderField: "anthropic-version")
        request.httpBody  = bodyData
        request.timeoutInterval = 20  // Haiku is fast — if it takes >20s something is wrong

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            // On any failure — network error, bad key, rate limit — fall back silently
            guard error == nil,
                  let data,
                  let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (json["content"] as? [[String: Any]])?.first,
                  let text    = content["text"] as? String
            else {
                DispatchQueue.main.async { completion(items, nil) }
                return
            }

            // Strip markdown fences — Haiku wraps JSON in ```json``` even when told not to.
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("```") {
                let lines = cleaned.components(separatedBy: "\n")
                cleaned = lines.dropFirst().joined(separator: "\n")
            }
            if cleaned.hasSuffix("```") {
                let lines = cleaned.components(separatedBy: "\n")
                cleaned = lines.dropLast().joined(separator: "\n")
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let responseData = cleaned.data(using: .utf8) else {
                DispatchQueue.main.async { completion(items, nil) }
                return
            }

            // Parse the full response — extract summary separately
            var summary: String? = nil
            if let raw = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                summary = raw["summary"] as? String
            }

            guard let parsed = try? JSONDecoder().decode(AICleanupResponse.self, from: responseData) else {
                DispatchQueue.main.async { completion(items, nil) }
                return
            }

            // Merge AI overrides into rule engine results
            let enhanced = self.merge(
                items:    items,
                response: parsed,
                rootURL:  rootURL
            )

            DispatchQueue.main.async { completion(enhanced, summary) }
        }.resume()
    }

    // MARK: — Merge rule results with AI overrides

    private func merge(
        items:    [CleanupItem],
        response: AICleanupResponse,
        rootURL:  URL
    ) -> [CleanupItem] {

        // Build override lookup by path
        let overrideMap: [String: AIOverride] = Dictionary(
            uniqueKeysWithValues: response.overrides.map { ($0.path, $0) }
        )

        // Apply overrides to existing items
        var result: [CleanupItem] = items.compactMap { (item) -> CleanupItem? in
            guard let override = overrideMap[item.url.path] else {
                return item  // no override — keep as-is
            }
            if !override.include { return nil }  // AI says remove from suggestions
            // Apply AI's improved classification
            return CleanupItem(
                url:             item.url,
                name:            item.name,
                size:            item.size,
                category:        CleanupCategory(rawValue: override.category) ?? item.category,
                safety:          safetyLevel(override.safety),
                reason:          override.reason + " ✦",
                confidence:      override.confidence ?? item.confidence,
                lastAccessedDays: item.lastAccessedDays
            )
        }

        // Add AI-suggested extra paths (verify they actually exist on disk)
        for extra in response.extraPaths {
            let url = URL(fileURLWithPath: extra.path)
            guard FileManager.default.fileExists(atPath: extra.path) else { continue }

            // Verify it's not already in results
            guard !result.contains(where: { $0.url.path == extra.path }) else { continue }

            // Get the real size (Haiku estimates, we verify)
            let realSize = quickSize(url)
            guard realSize > 1_048_576 else { continue }  // skip if < 1MB

            result.append(CleanupItem(
                url:             url,
                name:            url.lastPathComponent,
                size:            realSize,
                category:        CleanupCategory(rawValue: extra.category) ?? .unknown,
                safety:          safetyLevel(extra.safety),
                reason:          extra.reason + " ✦",
                confidence:      50,
                lastAccessedDays: nil
            ))
        }

        // Re-sort: safe first, then by size
        return result.sorted {
            if $0.safety != $1.safety { return $0.safety < $1.safety }
            return $0.size > $1.size
        }
    }

    // MARK: — Helpers

    private func safetyString(_ level: SafetyLevel) -> String {
        switch level {
        case .safe:    return "safe"
        case .caution: return "caution"
        case .review:  return "review"
        }
    }

    private func safetyLevel(_ string: String) -> SafetyLevel {
        switch string.lowercased() {
        case "safe":   return .safe
        case "review": return .review
        default:       return .caution
        }
    }

    private func quickSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int64 ?? 0
        }
        for case let f as URL in enumerator {
            total += Int64(
                (try? f.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize ?? 0
            )
        }
        return total
    }
}
