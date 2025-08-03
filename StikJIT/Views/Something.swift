//
//  Something.swift
//  StikDebug
//
//  Created by Stephen on 7/29/25.
//

import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation
import ZSign
import StikImporter

@_silgen_name("install_ipa")
private func c_install_ipa(
    _ ip: UnsafePointer<CChar>,
    _ pairing: UnsafePointer<CChar>,
    _ udid: UnsafePointer<CChar>?,
    _ ipa: UnsafePointer<CChar>
) -> Int32

private func installErrorMessage(_ code: Int32) -> String {
    switch code {
    case 0:  return "Success"
    case 1:  return "Pairing file unreadable"
    case 2:  return "TCP provider error"
    case 3:  return "AFC connect error"
    case 4:  return "IPA unreadable"
    case 5:  return "AFC open error"
    case 6:  return "AFC write error"
    case 7:  return "Install-proxy error"
    case 8:  return "Device refused IPA"
    case 9:  return "Invalid IP address"
    default: return "Unknown (\(code))"
    }
}

private let docs      = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
private let appsJSON  = docs.appendingPathComponent("signed_apps.json")
private let certsJSON = docs.appendingPathComponent("certs.json")

struct SignedApp: Identifiable, Codable, Hashable {
    let id:       UUID
    let name:     String
    let bundleID: String
    let version:  String
    let ipaPath:  String
    let iconPath: String?
    
    var ipaURL:  URL { docs.appendingPathComponent(ipaPath) }
    var iconURL: URL? { iconPath.map { docs.appendingPathComponent($0) } }
}

struct Certificate: Identifiable, Codable, Hashable {
    let id:      UUID
    let name:    String
    let p12Path: String
    let mobPath: String?
    
    var p12URL: URL { docs.appendingPathComponent(p12Path) }
    var mobURL: URL? { mobPath.map { docs.appendingPathComponent($0) } }
}

private enum FSX {
    static func mkdir(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        }
    }
    static func copySecure(from src: URL, to dst: URL) throws {
        let ok = src.startAccessingSecurityScopedResource()
        defer { if ok { src.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
    }
    static func perms(app: URL) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isExecutableKey]
        guard let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return }
        for case let f as URL in e {
            let rv = try f.resourceValues(forKeys: Set(keys))
            if rv.isDirectory == true {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            } else {
                let exec = rv.isExecutable == true ||
                           f.lastPathComponent == app.lastPathComponent.replacingOccurrences(of: ".app", with: "") ||
                           (f.pathExtension.isEmpty && !f.lastPathComponent.contains("."))
                try FileManager.default.setAttributes([.posixPermissions: exec ? 0o755 : 0o644],
                                                      ofItemAtPath: f.path)
            }
        }
    }
}

@MainActor
final class AppSignerManager: ObservableObject {
    
    private var didFinishInitialLoad = false
    
    @Published var apps: [SignedApp] = [] {
        didSet { if didFinishInitialLoad { saveApps() } }
    }
    @Published var certs: [Certificate] = [] {
        didSet { if didFinishInitialLoad { saveCerts() } }
    }
    @Published var selectedCertID: UUID?
    @Published var busy   = false
    @Published var ipaURL: URL?
    @Published var ipaName: String?
    
    private let imports     = docs.appendingPathComponent("Imports", isDirectory: true)
    private let certsFolder = docs.appendingPathComponent("Certs",   isDirectory: true)
    
    init() {
        try? FSX.mkdir(imports)
        try? FSX.mkdir(certsFolder)
        migrateAndLoadApps()
        migrateAndLoadCerts()
        didFinishInitialLoad = true
    }
    
    private func migrateAndLoadApps() {
        guard let data = try? Data(contentsOf: appsJSON),
              let stored = try? JSONDecoder().decode([SignedApp].self, from: data) else { return }
        
        var fixed: [SignedApp] = []
        for app in stored {
            if FileManager.default.fileExists(atPath: app.ipaURL.path) {
                fixed.append(app)
                continue
            }
            let expectedRel = "SignedApps/\(app.name)/\(app.name).ipa"
            let newAbs      = docs.appendingPathComponent(expectedRel).path
            if FileManager.default.fileExists(atPath: newAbs) {
                let newIconRel = "SignedApps/\(app.name)/icon.png"
                fixed.append(SignedApp(
                    id: app.id, name: app.name, bundleID: app.bundleID,
                    version: app.version, ipaPath: expectedRel,
                    iconPath: FileManager.default.fileExists(atPath: docs.appendingPathComponent(newIconRel).path) ? newIconRel : nil))
            }
        }
        apps = fixed
    }
    private func saveApps() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: appsJSON)
    }
    
    private func migrateAndLoadCerts() {
        guard let data = try? Data(contentsOf: certsJSON),
              let stored = try? JSONDecoder().decode([Certificate].self, from: data) else { return }
        
        var fixed: [Certificate] = []
        for cert in stored {
            if FileManager.default.fileExists(atPath: cert.p12URL.path) &&
               (cert.mobURL == nil || FileManager.default.fileExists(atPath: cert.mobURL!.path)) {
                fixed.append(cert)                // already fine
                continue
            }
            let dir = certsFolder.appendingPathComponent(cert.id.uuidString)
            let newP12Rel = "Certs/\(cert.id.uuidString)/cert.p12"
            let newMobRel = "Certs/\(cert.id.uuidString)/profile.mobileprovision"
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("cert.p12").path) {
                fixed.append(Certificate(
                    id: cert.id, name: cert.name,
                    p12Path: newP12Rel,
                    mobPath: FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.mobileprovision").path) ? newMobRel : nil))
            }
        }
        certs = fixed
        if selectedCertID == nil { selectedCertID = certs.first?.id }
    }
    private func saveCerts() {
        guard let data = try? JSONEncoder().encode(certs) else { return }
        try? data.write(to: certsJSON)
    }
    
    func deleteApp(_ app: SignedApp) {
        if let idx = apps.firstIndex(of: app) {
            try? FileManager.default.removeItem(at: app.ipaURL.deletingLastPathComponent())
            apps.remove(at: idx)
        }
    }
    
    func importIPA(from url: URL) throws {
        let dst = imports.appendingPathComponent("current.ipa")
        try FSX.copySecure(from: url, to: dst)
        ipaURL = dst
        ipaName = try parseIPAName(at: dst)
    }
    private func parseIPAName(at ipa: URL) throws -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FSX.mkdir(tmp)
        try FileManager.default.unzipItem(at: ipa, to: tmp)
        let payload = tmp.appendingPathComponent("Payload")
        let appDir = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let dir = appDir,
              let dict = NSDictionary(contentsOf: dir.appendingPathComponent("Info.plist")) else { return nil }
        return (dict["CFBundleDisplayName"] ?? dict["CFBundleName"]) as? String
    }
    
    func addCertificate(name: String, p12: URL, mob: URL, password: String,
                        onErr: (String,String)->Void, onOK: (String,String)->Void) {
        let id  = UUID()
        let dir = certsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FSX.mkdir(dir)
            try FSX.copySecure(from: p12, to: dir.appendingPathComponent("cert.p12"))
            try FSX.copySecure(from: mob, to: dir.appendingPathComponent("profile.mobileprovision"))
            KeychainHelper.shared.save(password: password, forKey: id.uuidString)
            
            certs.append(Certificate(
                id: id, name: name,
                p12Path: "Certs/\(id.uuidString)/cert.p12",
                mobPath: "Certs/\(id.uuidString)/profile.mobileprovision"))
            selectedCertID = id
            onOK("Certificate added", name)
        } catch { onErr("Cert error", error.localizedDescription) }
    }
    
    func signIPA(onErr: @escaping (String,String)->Void,
                 onOK:  @escaping (String,String)->Void) {
        guard !busy else { return }
        guard let ipa = ipaURL,
              let cert = certs.first(where: { $0.id == selectedCertID }) else {
            onErr("Missing data", "Import IPA and select certificate first"); return
        }
        busy = true
        Task.detached {
            do {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FSX.mkdir(tmp)
                _ = ipa.startAccessingSecurityScopedResource(); defer { ipa.stopAccessingSecurityScopedResource() }
                
                try FileManager.default.unzipItem(at: ipa, to: tmp)
                let payload = tmp.appendingPathComponent("Payload")
                guard let appFolder = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "Signer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No .app found"])
                }
                try FSX.perms(app: appFolder)
                guard
                    let dict   = NSDictionary(contentsOf: appFolder.appendingPathComponent("Info.plist")),
                    let name   = (dict["CFBundleDisplayName"] ?? dict["CFBundleName"]) as? String,
                    let bundle = dict["CFBundleIdentifier"]         as? String,
                    let ver    = dict["CFBundleShortVersionString"] as? String
                else {
                    throw NSError(domain: "Signer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Info.plist parse error"])
                }
                
                let pw = KeychainHelper.shared.readPassword(forKey: cert.id.uuidString) ?? ""
                let rc = zsign(appFolder.path,
                               cert.p12URL.path,
                               cert.p12URL.path,
                               cert.mobURL?.path ?? "",
                               pw, "", "")
                guard rc == 0 else {
                    throw NSError(domain: "zsign", code: Int(rc),
                                  userInfo: [NSLocalizedDescriptionKey: "zsign returned \(rc)"])
                }
                
                let outDir = docs.appendingPathComponent("SignedApps/\(name)", isDirectory: true)
                if FileManager.default.fileExists(atPath: outDir.path) { try FileManager.default.removeItem(at: outDir) }
                try FSX.mkdir(outDir)
                let final = outDir.appendingPathComponent("\(name).ipa")
                try FileManager.default.zipItem(at: payload,
                                                to: outDir.appendingPathComponent("\(name).ipa"),
                                                shouldKeepParent: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: final.path)
                
                var iconRel: String?
                if let iconURL = try? FileManager.default.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)
                    .first(where: { $0.lastPathComponent.lowercased().contains("appicon") && $0.pathExtension == "png" }) {
                    let dst = outDir.appendingPathComponent("icon.png")
                    try? FileManager.default.copyItem(at: iconURL, to: dst)
                    iconRel = "SignedApps/\(name)/icon.png"
                }
                
                let relIPA = "SignedApps/\(name)/\(name).ipa"
                let newApp = SignedApp(
                    id: UUID(), name: name, bundleID: bundle,
                    version: ver, ipaPath: relIPA, iconPath: iconRel)
                
                await MainActor.run {
                    self.apps.removeAll { $0.name == newApp.name }
                    self.apps.append(newApp)
                    self.busy = false
                    onOK("\(name) is ready for testing", "Saved to \(relIPA)")
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    onErr("Sign error", error.localizedDescription)
                }
            }
        }
    }
    
    func install(app: SignedApp, ip: String, pairing: String,
                 onErr: @escaping (String,String)->Void,
                 onOK:  @escaping (String,String)->Void) {
        guard !busy else { return }
        guard FileManager.default.fileExists(atPath: app.ipaURL.path) else { onErr("IPA missing", app.ipaURL.path); return }
        guard FileManager.default.fileExists(atPath: pairing) else { onErr("Pairing missing", pairing); return }
        busy = true
        Task.detached {
            let rc = ip.withCString { ipPtr in
                pairing.withCString { pairPtr in
                    app.ipaURL.path.withCString { ipaPtr in
                        c_install_ipa(ipPtr, pairPtr, nil, ipaPtr)
                    }
                }
            }
            await MainActor.run {
                self.busy = false
                rc == 0 ? onOK("Installed for testing", app.name)
                        : onErr("Install failed", installErrorMessage(rc))
            }
        }
    }
}

struct IPAAppManagerView: View {
    @AppStorage("customAccentColor") private var customAccentColorHex: String = ""
    private var accent: Color {
        customAccentColorHex.isEmpty ? .blue : Color(hex: customAccentColorHex) ?? .blue
    }
    
    @StateObject private var mgr = AppSignerManager()
    @State private var pickerShown  = false
    @State private var showAddCert  = false
    @State private var alert        = false
    @State private var alertTitle   = ""
    @State private var alertMsg     = ""
    @State private var alertSuccess = false
    @AppStorage("deviceIP") private var deviceIP = "10.7.0.2"
    private var pairingPath: String { docs.appendingPathComponent("pairingFile.plist").path }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 14) {
                        signCard
                        appsCard
                        versionInfo
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                
                if mgr.busy {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView()
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if alert {
                    CustomErrorView(title: alertTitle,
                                    message: alertMsg,
                                    onDismiss: { alert = false },
                                    messageType: alertSuccess ? .success : .error)
                }
            }
            .navigationTitle("Testing")
            .stikImporter(isPresented: $pickerShown,
                          selectedURLs: .constant([]),
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { urls in
                if let u = urls.first {
                    do { try mgr.importIPA(from: u); notify("File imported", "File saved to Imports") }
                    catch { fail("Import error", error.localizedDescription) }
                }
            }
            .sheet(isPresented: $showAddCert) {
                AddCertView(accent: accent) { n, p12, mob, pw in
                    mgr.addCertificate(name: n, p12: p12, mob: mob, password: pw,
                                       onErr: fail, onOK: notify)
                }
            }
        }
    }
        
    private var signCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Prepare for testing")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                VStack(spacing: 10) {
                    importButton(label: mgr.ipaName ?? ".IPA File",
                                 icon: "arrow.down.doc",
                                 imported: mgr.ipaURL != nil) { pickerShown = true }
                    
                    Picker("Certificate", selection: $mgr.selectedCertID) {
                        ForEach(mgr.certs) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button("Add Developer Certificate") { showAddCert = true }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.4))
                        .foregroundColor(accent.contrastText())
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    Button("Prepare") { mgr.signIPA(onErr: fail, onOK: notify) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accent)
                        .foregroundColor(accent.contrastText())
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(mgr.busy || mgr.ipaURL == nil || mgr.selectedCertID == nil)
                }
            }
            .padding(20)
        }
    }
    
    private var appsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ready to test apps")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                if mgr.apps.isEmpty {
                    Text("No ready to test apps yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(mgr.apps) { app in
                        HStack(spacing: 12) {
                            if let img = app.iconURL.flatMap({ UIImage(contentsOfFile: $0.path) }) {
                                Image(uiImage: img)
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading) {
                                Text(app.name).bold()
                                Text("v\(app.version) • \(app.bundleID)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Test") {
                                mgr.install(app: app, ip: deviceIP, pairing: pairingPath,
                                            onErr: fail, onOK: notify)
                            }
                            .buttonStyle(.bordered)
                            .disabled(mgr.busy)
                            
                            Button(role: .destructive) {
                                mgr.deleteApp(app)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .padding(20)
        }
    }
    
    private var versionInfo: some View {
        HStack {
            Spacer()
            Text("iOS \(UIDevice.current.systemVersion)")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 6)
    }
        
    private func importButton(label: String, icon: String,
                              imported: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(label)
                Spacer()
                Image(systemName: imported ? "checkmark.circle.fill" : "chevron.right")
            }
            .foregroundColor(imported ? .primary : .secondary)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(mgr.busy)
    }
    
    private func fail(_ title: String, _ msg: String) {
        alertTitle = title; alertMsg = msg; alertSuccess = false; alert = true
    }
    private func notify(_ title: String, _ msg: String) {
        alertTitle = title; alertMsg = msg; alertSuccess = true; alert = true
    }
}

private struct AddCertView: View {
    let accent: Color
    var onSave: (String, URL, URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var name    = ""
    @State private var p12URL: URL?
    @State private var mobURL: URL?
    @State private var password = ""
    
    @State private var pickP12 = false
    @State private var pickMob = false
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Certificate name", text: $name)
                importRow(label: ".mobileprovision", picked: mobURL != nil) { pickMob = true }
                    .stikImporter(isPresented: $pickMob,
                                  selectedURLs: .constant([]),
                                  allowedContentTypes: [UTType.item],
                                  allowsMultipleSelection: false) { mobURL = $0.first }
                importRow(label: ".p12 file", picked: p12URL != nil) { pickP12 = true }
                    .stikImporter(isPresented: $pickP12,
                                  selectedURLs: .constant([]),
                                  allowedContentTypes: [UTType.item],
                                  allowsMultipleSelection: false) { p12URL = $0.first }
                SecureField("p12 password", text: $password)
            }
            .navigationTitle("New Certificate")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let p = p12URL, let m = mobURL, !name.isEmpty {
                            onSave(name, p, m, password); dismiss()
                        }
                    }
                    .disabled(p12URL == nil || mobURL == nil || name.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func importRow(label: String, picked: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(picked ? .green : accent)
            }
        }
    }
}
