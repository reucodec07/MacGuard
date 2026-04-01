import Foundation

/// Centralized TTl-bound cache actor to reduce repetitive I/O across overlapping/burst refreshes.
actor LoginItemsCaches {
    static let shared = LoginItemsCaches()

    private var systemLabels: Set<String> = []
    private var systemTimestamp: Date = Date.distantPast

    private var appCache: [String: URL] = [:]
    private var appTimestamp: Date = Date.distantPast

    /// Fetches the system state domain cache, internally managing a strict 2s TTL.
    func getSystemCache() async -> Set<String> {
        if Date().timeIntervalSince(systemTimestamp) < 2.0 {
            return systemLabels
        }
        let fresh = await SystemDomainStateCache.build()
        systemLabels = fresh
        systemTimestamp = Date()
        return fresh
    }

    /// Fetches the base app URL mapping pool. Handled merging explicitly after sweeps.
    func getAppCache() -> [String: URL] {
        return appCache // Caches grow monolithically; logic determines updates dynamically
    }

    /// Merges missing URLs back to maintain an O(1) App lookup dictionary.
    func updateAppCache(_ newCache: [String: URL]) {
        appCache.merge(newCache) { _, new in new }
        appTimestamp = Date()
    }
}
