import Foundation
import Darwin

// MARK: — DiskItem

struct DiskItem: Identifiable {
    let id        = UUID()
    let url:        URL
    let name:       String
    let size:       Int64
    let isDir:      Bool
    let isSymlink:  Bool
    let itemCount:  Int
    let isPackage:  Bool

    var sizeLabel: String { size < 0 ? "…" : DiskItem.formatSize(size) }
    var isPending: Bool   { size < 0 }

    var icon: String {
        if isSymlink  { return "link" }
        if isPackage  { return "shippingbox.fill" }
        if isDir      { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic","tiff": return "photo.fill"
        case "mp4","mov","avi","mkv","m4v":                 return "film.fill"
        case "mp3","m4a","aac","flac","wav":                return "music.note"
        case "pdf":                                          return "doc.richtext.fill"
        case "zip","tar","gz","bz2","7z","rar","dmg":       return "archivebox.fill"
        case "swift","py","js","ts","c","cpp","h","go":     return "doc.text.fill"
        default:                                             return "doc.fill"
        }
    }

    static func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0            { return "—" }
        if bytes < 1_024         { return "\(bytes) B" }
        if bytes < 1_048_576     { return String(format: "%.1f KB", Double(bytes)/1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes)/1_048_576) }
        return String(format: "%.2f GB", Double(bytes)/1_073_741_824)
    }
}

// MARK: — DiskAnalyzer

class DiskAnalyzer: ObservableObject {
    @Published var items: [DiskItem] = []
    @Published var isScanning = false
    @Published var progress = ""
    @Published var rootURL: URL?
    @Published var totalSize: Int64 = 0
    @Published var scannedCount: Int = 0
    @Published var breadcrumbs: [URL] = []
    @Published var progressPulse = false
    @Published var scanProgress: Double = 0   // 0.0 → 1.0, drives the progress bar

    private var scanGeneration = 0
    private var securedURL: URL?

    private let skipPaths: [String] = [
        "/System/Volumes",
        "/private/var/vm",
        "/private/var/folders",
        "/dev",
        "/net",
        "/home",
        "/cores"
    ]

    // MARK: — Public API

    func scan(_ url: URL) {
        stopSecuredAccess()
        _ = url.startAccessingSecurityScopedResource()
        securedURL = url
        rootURL = url
        breadcrumbs = [url]
        startNewScan(url)
    }

    func drillDown(into item: DiskItem) {
        guard item.isDir && !item.isPackage else { return }
        breadcrumbs.append(item.url)
        startNewScan(item.url)
    }

    func navigateTo(breadcrumb url: URL) {
        guard let idx = breadcrumbs.firstIndex(of: url) else { return }
        breadcrumbs = Array(breadcrumbs.prefix(idx + 1))
        startNewScan(url)
    }

    func cancel() {
        scanGeneration += 1
        isScanning = false
        progress = "Cancelled"
    }

    private func stopSecuredAccess() {
        securedURL?.stopAccessingSecurityScopedResource()
        securedURL = nil
    }

    // MARK: — Internal

    private func startNewScan(_ url: URL) {
        scanGeneration += 1
        let gen = scanGeneration

        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            self.isScanning = true
            self.items = []
            self.totalSize = 0
            self.scannedCount = 0
            self.progress = "Scanning…"
            self.progressPulse = false
            self.scanProgress = 0
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            self.doScan(url, gen: gen)
        }
    }

    private func shouldSkip(_ url: URL) -> Bool {
        let p = url.path
        return skipPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    private func duSize(_ url: URL, gen: Int) -> Int64 {
        guard scanGeneration == gen else { return 0 }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-skx", url.path]
        task.standardError = Pipe()
        let pipe = Pipe()
        task.standardOutput = pipe

        do { try task.run() } catch { return 0 }

        while task.isRunning {
            if scanGeneration != gen { task.terminate(); return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard scanGeneration == gen else { return 0 }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let kb = Int64(out.components(separatedBy: "\t").first?
                        .trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        return kb * 1024
    }

    private func doScan(_ dirURL: URL, gen: Int) {
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey,
                .isSymbolicLinkKey, .totalFileSizeKey, .fileSizeKey
            ],
            options: []
        ) else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == gen else { return }
                self.isScanning = false
                self.progress = "Cannot read this folder — permission denied"
            }
            return
        }

        var dirURLs: [URL] = []
        var fileItems: [DiskItem] = []

        for entry in entries {
            guard scanGeneration == gen else { return }

            var st = Darwin.stat()
            let isLink = lstat(entry.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
            let rv = try? entry.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey, .totalFileSizeKey, .fileSizeKey
            ])
            let isDir = rv?.isDirectory ?? false
            let isPackage = rv?.isPackage ?? false

            if isDir && !isPackage && !isLink && !shouldSkip(entry) {
                dirURLs.append(entry)
            } else {
                let size = Int64(rv?.totalFileSize ?? rv?.fileSize ?? 0)
                fileItems.append(DiskItem(
                    url: entry, name: entry.lastPathComponent,
                    size: size, isDir: isDir, isSymlink: isLink,
                    itemCount: 0, isPackage: isPackage
                ))
            }
        }

        // Publish all items immediately: files with real sizes, dirs as pending (size = -1)
        let pendingDirs = dirURLs.map { url in
            DiskItem(url: url, name: url.lastPathComponent,
                     size: -1, isDir: true, isSymlink: false,
                     itemCount: -1, isPackage: false)
        }
        let fileTotal     = fileItems.reduce(Int64(0)) { $0 + $1.size }
        let initialItems  = (fileItems + pendingDirs).sorted { max(0, $0.size) > max(0, $1.size) }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            self.items        = initialItems
            self.totalSize    = fileTotal
            self.scanProgress = 0
            self.progress     = "Sizing \(dirURLs.count) folder\(dirURLs.count == 1 ? "" : "s")…"
        }

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 4
        opQueue.qualityOfService = .utility

        let group = DispatchGroup()
        let lock = NSLock()
        var sizedDirs = [DiskItem]()

        for dirURL in dirURLs {
            guard scanGeneration == gen else { break }
            group.enter()
            opQueue.addOperation { [weak self] in
                defer { group.leave() }
                guard let self, self.scanGeneration == gen else { return }

                let size = self.duSize(dirURL, gen: gen)
                let childCount = (try? fm.contentsOfDirectory(atPath: dirURL.path).count) ?? -1
                let item = DiskItem(
                    url: dirURL, name: dirURL.lastPathComponent,
                    size: size, isDir: true, isSymlink: false,
                    itemCount: childCount, isPackage: false
                )

                lock.lock()
                sizedDirs.append(item)
                let done      = sizedDirs.count
                let totalDirs = dirURLs.count

                // Rebuild: already-sized + still-pending + files
                let sizedPaths    = Set(sizedDirs.map { $0.url.path })
                let stillPending  = dirURLs
                    .filter { !sizedPaths.contains($0.path) }
                    .map    { url in DiskItem(url: url, name: url.lastPathComponent,
                                              size: -1, isDir: true, isSymlink: false,
                                              itemCount: -1, isPackage: false) }
                let combined      = (sizedDirs + stillPending + fileItems)
                    .sorted { max(0, $0.size) > max(0, $1.size) }
                let knownTotal    = (sizedDirs + fileItems).reduce(Int64(0)) { $0 + $1.size }
                lock.unlock()

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanGeneration == gen else { return }
                    self.items        = combined
                    self.totalSize    = knownTotal
                    self.scanProgress = Double(done) / Double(max(1, totalDirs))
                    self.progress     = "Sized \(done) of \(totalDirs) folders…"
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            let final = (sizedDirs + fileItems).sorted { $0.size > $1.size }
            let total = final.reduce(Int64(0)) { $0 + $1.size }
            self.items = final
            self.totalSize = total
            self.scannedCount = final.count
            self.scanProgress = 1.0
            self.isScanning = false
            self.progress = "\(final.count) item\(final.count == 1 ? "" : "s") · \(DiskItem.formatSize(total))"
            self.progressPulse.toggle()
        }
    }
}
