import Foundation
import os.log

struct SystemDomainStateCache {
    private static let logger = Logger(subsystem: "com.macguard", category: "SystemDomainStateCache")

    /// Builds a cache of system domain labels currently loaded/present.
    /// Returns an empty set if parsing fails or execution times out.
    static func build() async -> Set<String> {
        let start = Date()
        let out = await ProcessRunner.shared.run("/bin/launchctl", ["print", "system"], timeout: 3.0).stdout
        
        guard !out.isEmpty else {
            logger.error("launchctl print system returned empty or timed out.")
            return []
        }
        
        let labels = parse(output: out)
        
        let elapsed = Date().timeIntervalSince(start)
        logger.debug("Built SystemDomainStateCache in \(String(format: "%.3f", elapsed))s with \(labels.count) items.")
        return labels
    }
    
    static func parse(output: String) -> Set<String> {
        var labels = Set<String>()
        let lines = output.components(separatedBy: "\n")
        var inServicesBlock = false
        
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            
            // Flexible matching for "services = {" with potential whitespace
            if t.replacingOccurrences(of: " ", with: "") == "services={" {
                inServicesBlock = true
                continue
            }
            if inServicesBlock && t == "}" {
                inServicesBlock = false
                continue
            }
            
            if inServicesBlock {
                // In services block, format is typically: 0x... (pid) status label
                // But can vary. We look for the last token.
                let parts = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 3 {
                    // Stripping potential quotes
                    let label = parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !label.isEmpty { labels.insert(label) }
                }
            } else if t.hasPrefix("label =") {
                // format: label = "com.apple.xpc.launchd.domain.system"
                let label = t.components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let l = label, !l.isEmpty {
                    labels.insert(l)
                }
            }
        }
        return labels
    }
}
