import SwiftUI

struct UninstallerView: View {
    @State private var searchText = ""
    @StateObject private var uninstaller = AppUninstaller()
    @State private var showConfirm       = false
    @State private var selectedID: UUID?
    @State private var resultMessage     = ""
    @State private var showResult        = false
    @State private var resultSuccess     = true

    var filteredApps: [AppBundle] {
        searchText.isEmpty ? uninstaller.installedApps :
            uninstaller.installedApps.filter {
                $0.name.lowercased().contains(searchText.lowercased()) ||
                $0.bundleID.lowercased().contains(searchText.lowercased())
            }
    }

    var body: some View {
        HSplitView {
            // ── Left: App List ───────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Installed Apps").font(.title2).bold()
                    Spacer()
                    if uninstaller.isScanning { ProgressView().scaleEffect(0.7) }
                    Button("↻ Scan") { uninstaller.scanApps() }.buttonStyle(.bordered)
                }
                
                TextField("Search Apps...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if !uninstaller.statusMessage.isEmpty && !uninstaller.isScanning {
                    Text(uninstaller.statusMessage)
                        .font(.caption).foregroundColor(.secondary)
                }
                List(filteredApps, id: \.id, selection: $selectedID) { app in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).fontWeight(.medium)
                        Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                        Text(RelatedFile.formatSize(app.appSize))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(app.id)
                }
                .listStyle(.bordered)
                .onChange(of: selectedID) { id in
                    guard let id = id,
                          let app = filteredApps.first(where: { $0.id == id })
                    else { return }
                    uninstaller.selectedApp = app
                    uninstaller.findRelatedFiles(for: app)
                }
            }
            .padding()
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 300)

            // ── Right: Detail ────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                if let app = uninstaller.selectedApp { detailView(for: app) }
                else { emptyState }
            }
            .frame(minWidth: 520)
        }
        .onAppear { uninstaller.scanApps() }
        .alert(resultSuccess ? "Uninstall Complete" : "Uninstall Issue",
               isPresented: $showResult) {
            Button("OK", role: .cancel) {}
            if !resultSuccess { Button("Rescan") { uninstaller.scanApps() } }
        } message: { Text(resultMessage) }
    }

    // MARK: — Detail Panel
    @ViewBuilder
    func detailView(for app: AppBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            // App header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.1)).frame(width: 52, height: 52)
                    Text(String(app.name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold)).foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2).bold()
                    Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                    Text(app.path.path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("App Size").font(.caption).foregroundColor(.secondary)
                    Text(RelatedFile.formatSize(app.appSize))
                        .font(.title3).fontWeight(.semibold).foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color.blue.opacity(0.04))
            .cornerRadius(10)
            .padding(.horizontal).padding(.top)

            // ── Vendor uninstaller banner ─────────────────
            if let vendorURL = uninstaller.vendorUninstallerURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Official uninstaller found").fontWeight(.medium)
                            .font(.system(size: 12))
                        Text("Use the vendor's own script for cleanest removal")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Run Official Uninstaller") {
                        NSWorkspace.shared.open(vendorURL)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            // ── Warning banners ───────────────────────────
            if !uninstaller.isFindingFiles {
                if uninstaller.launchSvcCount() > 0 {
                    BannerView(
                        title: "\(uninstaller.launchSvcCount()) background service(s) will be unloaded first",
                        subtitle: "MacGuard will run launchctl to stop them before deleting their plist files — this prevents re-spawning",
                        style: .info,
                        actionLabel: nil,
                        action: nil)
                }
                if uninstaller.adminFileCount() > 0 {
                    BannerView(
                        title: "\(uninstaller.adminFileCount()) system file(s) require your admin password",
                        subtitle: "One password prompt will handle all of them at once",
                        style: .warning,
                        actionLabel: nil,
                        action: nil)
                }
                if uninstaller.sipFileCount() > 0 {
                    BannerView(
                        title: "\(uninstaller.sipFileCount()) SIP-protected file(s) cannot be deleted",
                        subtitle: "These are owned by macOS SIP and cannot be removed by any app. They take no storage worth reclaiming.",
                        style: .critical,
                        actionLabel: nil,
                        action: nil)
                }
            }

            // ── Advisory warnings (VPN, TCC, Dock, Keychain) ──────
            if !uninstaller.advisoryWarnings.isEmpty && !uninstaller.isFindingFiles {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "info.circle.fill").foregroundColor(.blue)
                        Text("Manual action required after uninstall")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    ForEach(uninstaller.advisoryWarnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.06))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            Divider().padding(.horizontal)

            // Files header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leftover Files").font(.headline)
                    if uninstaller.isFindingFiles {
                        Text("Deep scanning: Spotlight + pkgutil + Library…")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(uninstaller.statusMessage)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if uninstaller.isFindingFiles { ProgressView().scaleEffect(0.8) }
                else {
                    Button("↻ Rescan") { uninstaller.findRelatedFiles(for: app) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal)

            // File list
            if uninstaller.isFindingFiles {
                Spacer()
                HStack { Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning system & ~/Library…")
                            .foregroundColor(.secondary).font(.callout)
                    }
                    Spacer() }
                Spacer()
            } else if uninstaller.relatedFiles.isEmpty {
                Spacer()
                HStack { Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44)).foregroundColor(.green)
                        Text("No leftover files found")
                            .font(.title3).foregroundColor(.secondary)
                        Text("Only the .app bundle will be deleted")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer() }
                Spacer()
            } else {
                List(uninstaller.relatedFiles) { file in
                    HStack(spacing: 10) {
                        // File type icon
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(
                                file.isSIPProtected  ? .red.opacity(0.4) :
                                file.isLaunchService ? .blue :
                                file.requiresAdmin   ? .orange : .gray)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(file.label).fontWeight(.medium).lineLimit(1)
                                    .foregroundColor(file.isSIPProtected ? .secondary : .primary)
                                // Badges
                                if file.isSIPProtected {
                                    badge("SIP", .red)
                                } else if file.isLaunchService {
                                    badge("SERVICE", .blue)
                                } else if file.requiresAdmin {
                                    badge("ADMIN", .orange)
                                }
                            }
                            Text(file.url.deletingLastPathComponent().path)
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Text("via \(file.source)")
                                .font(.caption2).foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                        Text(file.sizeLabel)
                            .font(.caption)
                            .foregroundColor(
                                file.isSIPProtected ? .secondary.opacity(0.5) :
                                file.size > 50_000_000 ? .orange : .secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                    .opacity(file.isSIPProtected ? 0.5 : 1.0)
                }
                .listStyle(.bordered)
                .padding(.horizontal)
            }

            Divider().padding(.horizontal)

            // Total + Uninstall button
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Space to be freed").font(.caption).foregroundColor(.secondary)
                    Text(uninstaller.totalSizeToFree(for: app))
                        .font(.title3).fontWeight(.bold).foregroundColor(.red)
                    if uninstaller.sipFileCount() > 0 {
                        Text("(\(uninstaller.sipFileCount()) SIP-protected files excluded)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) { showConfirm = true } label: {
                    Label("Uninstall \(app.name)", systemImage: "trash.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(uninstaller.isFindingFiles)
                .confirmationDialog(
                    "Completely uninstall \(app.name)?",
                    isPresented: $showConfirm, titleVisibility: .visible
                ) {
                    Button("Uninstall", role: .destructive) {
                        AdminSession.shared.warmUp { granted in
                            guard granted else { return }
                            uninstaller.uninstall(app: app) { success, message in
                                resultSuccess = success
                                resultMessage = message
                                showResult    = true
                                if success { selectedID = nil }
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // ViewBuilder only accepts View expressions — compute string inline
                    Text([
                        "Deletes \(app.name) and \(uninstaller.relatedFiles.filter { $0.canBeDeleted }.count) leftover file(s) (\(uninstaller.totalSizeToFree(for: app))). Cannot be undone.",
                        uninstaller.launchSvcCount() > 0 ? "⚙️ \(uninstaller.launchSvcCount()) background service(s) will be stopped first." : nil,
                        uninstaller.adminFileCount() > 0 ? "🔐 Admin password required for \(uninstaller.adminFileCount()) system file(s)." : nil,
                        uninstaller.sipFileCount()   > 0 ? "🛡 \(uninstaller.sipFileCount()) SIP-protected file(s) will be skipped — cannot be deleted by any app." : nil,
                    ].compactMap { $0 }.joined(separator: "\n\n"))
                }
            }
            .padding()
            .background(Color.red.opacity(0.04))
            .cornerRadius(10)
            .padding([.horizontal, .bottom])
        }
    }

    func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(color)
            .cornerRadius(3)
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash.slash")
                .font(.system(size: 56)).foregroundColor(.secondary.opacity(0.35))
            Text("Select an app to uninstall")
                .font(.title3).foregroundColor(.secondary)
            Text("4-layer deep scan: Spotlight · pkgutil · ~/Library · /Library")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            if uninstaller.isScanning {
                ProgressView("Scanning apps…").padding(.top, 8)
            } else if uninstaller.installedApps.isEmpty {
                Button("↻ Scan for Apps") { uninstaller.scanApps() }
                    .buttonStyle(.borderedProminent).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
