//
//  DeviceInfoManager.swift
//  StikDebug
//
//  Created by Stephen on 8/2/25.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@_silgen_name("ideviceinfo_c_init")
private func c_deviceinfo_init(_ path: UnsafePointer<CChar>) -> Int32
@_silgen_name("ideviceinfo_c_get_xml")
private func c_deviceinfo_get_xml() -> UnsafePointer<CChar>?
@_silgen_name("ideviceinfo_c_cleanup")
private func c_deviceinfo_cleanup()

// MARK: - Device Info Manager

@MainActor
final class DeviceInfoManager: ObservableObject {
    @Published var entries: [(key: String, value: String)] = []
    @Published var busy = false
    @Published var error: (title: String, message: String)?
    private var initialized = false
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func initAndLoad() {
        guard !initialized else { loadInfo(); return }
        busy = true
        let path = docs.appendingPathComponent("pairingFile.plist").path
        Task.detached {
            let code = path.withCString { c_deviceinfo_init($0) }
            await MainActor.run {
                if code != 0 {
                    self.error = ("Initialization Failed", self.initErrorMessage(code))
                    self.busy = false
                } else {
                    self.initialized = true
                    self.loadInfo()
                }
            }
        }
    }

    private func loadInfo() {
        busy = true
        Task.detached {
            guard let cXml = c_deviceinfo_get_xml() else {
                await MainActor.run {
                    self.error = ("Fetch Error", "Failed to fetch device info")
                    self.busy = false
                }
                return
            }
            defer { free(UnsafeMutableRawPointer(mutating: cXml)) }
            guard let xml = String(validatingUTF8: cXml) else {
                await MainActor.run {
                    self.error = ("Parse Error", "Invalid XML data")
                    self.busy = false
                }
                return
            }
            do {
                let data = Data(xml.utf8)
                guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw NSError(domain: "DeviceInfo", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected dictionary"])
                }
                let formatted = dict.keys.sorted().map { ($0, Self.convertToString(dict[$0]!)) }
                await MainActor.run {
                    self.entries = formatted
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.error = ("Parse Error", error.localizedDescription)
                    self.busy = false
                }
            }
        }
    }

    func cleanup() {
        c_deviceinfo_cleanup()
        initialized = false
    }

    private func initErrorMessage(_ code: Int32) -> String {
        switch code {
        case 1: return "Couldn’t read pairingFile.plist"
        case 2: return "Unable to create device provider"
        case 3: return "Cannot connect to lockdown service"
        case 4: return "Unable to start lockdown session"
        default: return "Unknown init error (\(code))"
        }
    }

    nonisolated private static func convertToString(_ raw: Any) -> String {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return String(describing: raw)
        }
    }

    func exportToCSV() throws -> URL {
        var csv = "Key,Value\n"
        for (k, v) in entries {
            csv += "\"\(k.replacingOccurrences(of: "\"", with: "\"\""))\","
            csv += "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceInfo.csv")
        try csv.data(using: .utf8)?.write(to: url)
        return url
    }
}

// MARK: - Device Info UI

struct DeviceInfoView: View {
    @StateObject private var mgr = DeviceInfoManager()
    @State private var importer = false
    @State private var exportURL: URL?
    @State private var isShowingExporter = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var justCopied = false

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var pairingURL: URL { docs.appendingPathComponent("pairingFile.plist") }
    private var isPaired: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    @State private var searchText = ""
    @State private var alert = false
    @State private var alertTitle = ""
    @State private var alertMsg = ""
    @State private var alertSuccess = false

    var filteredEntries: [(key: String, value: String)] {
        guard !searchText.isEmpty else { return mgr.entries }
        return mgr.entries.filter {
            $0.key.localizedCaseInsensitiveContains(searchText)
            || $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    @AppStorage("appTheme") private var appThemeRaw: String = AppTheme.system.rawValue
    @Environment(\.themeExpansionManager) private var themeExpansion
    private var backgroundStyle: BackgroundStyle { themeExpansion?.backgroundStyle(for: appThemeRaw) ?? AppTheme.system.backgroundStyle }
    private var preferredScheme: ColorScheme? { themeExpansion?.preferredColorScheme(for: appThemeRaw) }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedBackground(style: backgroundStyle)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        infoCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 30)
                }

                if mgr.busy {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("Fetching device info…")
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                }

                if alert {
                    CustomErrorView(title: alertTitle,
                                    message: alertMsg,
                                    onDismiss: { alert = false },
                                    messageType: alertSuccess ? .success : .error)
                }

                if justCopied {
                    VStack {
                        Spacer()
                        Text("Copied")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 30)
                    }
                    .animation(.easeInOut(duration: 0.25), value: justCopied)
                }
            }
            .navigationTitle("Device Info")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isPaired {
                        Button { mgr.initAndLoad() } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }

                        Button {
                            do {
                                exportURL = try mgr.exportToCSV()
                                isShowingExporter = true
                            } catch {
                                fail("Export Failed", error.localizedDescription)
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(mgr.entries.isEmpty)

                        Menu {
                            Button { copyAllText() } label: {
                                Label("Copy All (Text)", systemImage: "doc.on.doc")
                            }
                            Button { copyAllCSV() } label: {
                                Label("Copy All (CSV)", systemImage: "tablecells")
                            }
                            Button { shareAll() } label: {
                                Label("Share…", systemImage: "square.and.arrow.up.on.square")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(mgr.entries.isEmpty)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isPaired {
                        Button { importer = true } label: {
                            Label("Import Pairing File", systemImage: "doc.badge.plus")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.propertyList]) { result in
                if case .success(let url) = result { importPairing(from: url) }
            }
            .fileExporter(
                isPresented: $isShowingExporter,
                document: CSVDocument(url: exportURL),
                contentType: .commaSeparatedText,
                defaultFilename: "DeviceInfo"
            ) { _ in notify("Export Complete", "Device info exported to CSV") }
            .sheet(isPresented: $showShareSheet) {
                ActivityViewController(items: shareItems)
            }
            .onAppear { if isPaired { mgr.initAndLoad() } }
            .onDisappear { mgr.cleanup() }
        }
        .preferredColorScheme(preferredScheme)
    }

    // MARK: - UI Sections

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search device info…", text: $searchText)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.bottom, 10)

            if !isPaired {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No pairing file detected", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Import your device’s pairing file to get started.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }

            if mgr.entries.isEmpty {
                Text(mgr.busy ? "Loading…" : (isPaired ? "No info available" : ""))
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredEntries, id: \.key) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.key).bold()
                        Text(entry.value)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    Divider()
                        .background(Color.white.opacity(0.12))
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    // MARK: - Copy / Share helpers

    private func allAsText() -> String {
        filteredEntries.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func allAsCSV() -> String {
        var csv = "Key,Value\n"
        for (k, v) in filteredEntries {
            let kq = k.replacingOccurrences(of: "\"", with: "\"\"")
            let vq = v.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(kq)\",\"\(vq)\"\n"
        }
        return csv
    }

    private func copyAllText() {
        UIPasteboard.general.string = allAsText()
        hapticCopySuccess()
        showCopiedToast()
    }

    private func copyAllCSV() {
        UIPasteboard.general.string = allAsCSV()
        hapticCopySuccess()
        showCopiedToast()
    }

    private func copyToPasteboard(_ str: String) {
        UIPasteboard.general.string = str
        hapticCopySuccess()
        showCopiedToast()
    }

    private func shareAll() {
        let text = allAsText()
        shareItems = [text]
        showShareSheet = true
    }

    private func hapticCopySuccess() {
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
    }

    private func showCopiedToast() {
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { justCopied = false }
        }
    }

    // MARK: - Pairing Import

    private func importPairing(from src: URL) {
        guard src.startAccessingSecurityScopedResource() else { return }
        defer { src.stopAccessingSecurityScopedResource() }
        do {
            if FileManager.default.fileExists(atPath: pairingURL.path) {
                try FileManager.default.removeItem(at: pairingURL)
            }
            try FileManager.default.copyItem(at: src, to: pairingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURL.path)
            notify("Pairing File Added", "Your device is ready. Tap Reload to fetch info.")
            mgr.initAndLoad()
        } catch {
            fail("Import Failed", error.localizedDescription)
        }
    }

    // MARK: - Alerts

    private func fail(_ title: String, _ msg: String) {
        alertTitle = title; alertMsg = msg; alertSuccess = false; alert = true
    }
    private func notify(_ title: String, _ msg: String) {
        alertTitle = title; alertMsg = msg; alertSuccess = true; alert = true
    }
}

// MARK: - CSV Document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [UTType.commaSeparatedText] }
    let url: URL?
    init(url: URL?) { self.url = url }
    init(configuration: ReadConfiguration) throws { fatalError("Not supported") }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = url else { throw NSError(domain: "CSVDocument", code: -1) }
        return try FileWrapper(url: url, options: .immediate)
    }
}

// MARK: - UIKit Share Sheet wrapper

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
