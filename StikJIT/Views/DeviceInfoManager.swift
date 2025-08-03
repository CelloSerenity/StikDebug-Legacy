//
//  DeviceInfoManager.swift
//  StikDebug
//
//  Created by Stephen on 8/2/25.
//

import SwiftUI
import UIKit

@_silgen_name("ideviceinfo_c_init")
private func c_deviceinfo_init(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("ideviceinfo_c_get_xml")
private func c_deviceinfo_get_xml() -> UnsafePointer<CChar>?

@_silgen_name("ideviceinfo_c_cleanup")
private func c_deviceinfo_cleanup()

private func initErrorMessage(_ code: Int32) -> String {
    switch code {
    case 1: return "Couldn’t read pairingFile.plist"
    case 2: return "Unable to create device provider"
    case 3: return "Cannot connect to lockdown service"
    case 4: return "Unable to start lockdown session"
    default: return "Unknown init error (\(code))"
    }
}

private let docs = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]

@MainActor
final class DeviceInfoManager: ObservableObject {
    @Published var entries: [(key: String, value: String)] = []
    @Published var busy = false
    @Published var error: (title: String, message: String)?

    private var initialized = false

    func initAndLoad() {
        guard !initialized else {
            loadInfo()
            return
        }
        busy = true
        let pairingPath = docs
            .appendingPathComponent("pairingFile.plist")
            .path

        DispatchQueue.global(qos: .userInitiated).async {
            let code = pairingPath.withCString { c_deviceinfo_init($0) }
            DispatchQueue.main.async {
                if code != 0 {
                    self.error = ("Initialization Failed", initErrorMessage(code))
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
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cXml = c_deviceinfo_get_xml() else {
                DispatchQueue.main.async {
                    self.error = ("Fetch Error", "Failed to fetch device info")
                    self.busy = false
                }
                return
            }
            defer { free(UnsafeMutableRawPointer(mutating: cXml)) }

            guard let xml = String(validatingUTF8: cXml) else {
                DispatchQueue.main.async {
                    self.error = ("Parse Error", "Invalid XML data")
                    self.busy = false
                }
                return
            }

            do {
                guard let data = xml.data(using: .utf8) else {
                    throw NSError(domain: "DeviceInfo", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid XML encoding"])
                }
                let plistObj = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [], format: nil)
                guard let dict = plistObj as? [String: Any] else {
                    throw NSError(domain: "DeviceInfo", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected dictionary"])
                }

                let formatted = dict.keys.sorted().map { key in
                    (key, Self.convertToString(dict[key]!))
                }

                DispatchQueue.main.async {
                    self.entries = formatted
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
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

    private static func convertToString(_ raw: Any) -> String {
        switch raw {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case let d as Data:
            let hex = d.prefix(32).map { String(format: "%02X", $0) }.joined()
            let suffix = d.count > 32 ? "…" : ""
            return "Data(\(d.count) B) \(hex)\(suffix)"
        case let arr as [Any]:
            return "[" + arr.map { convertToString($0) }.joined(separator: ", ") + "]"
        case let dic as [String: Any]:
            return "{" + dic.map { "\($0.key): \(convertToString($0.value))" }
                              .joined(separator: ", ") + "}"
        default:
            return String(describing: raw)
        }
    }

    func exportToCSV() throws -> URL {
        var csv = "Key,Value\n"
        for (key, value) in entries {
            let escKey = key.replacingOccurrences(of: "\"", with: "\"\"")
            let escValue = value.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(escKey)\",\"\(escValue)\"\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceInfo-Export.csv")
        try csv.data(using: .utf8)?.write(to: url)
        return url
    }
}

struct DeviceInfoView: View {
    @StateObject private var mgr = DeviceInfoManager()
    @State private var exportURL: URL?
    @State private var isShowingExporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 12) {

                                if mgr.entries.isEmpty {
                                    Text(mgr.busy ? "Loading…" : "No info available")
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(mgr.entries, id: \.key) { entry in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.key)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.primary)

                                            Text(entry.value)
                                                .font(.footnote.monospaced())
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .contextMenu {
                                            Button("Copy Key") {
                                                UIPasteboard.general.string = entry.key
                                            }
                                            Button("Copy Value") {
                                                UIPasteboard.general.string = entry.value
                                            }
                                            Button("Copy Both") {
                                                UIPasteboard.general.string = "\(entry.key): \(entry.value)"
                                            }
                                        }
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 20)
                }

                if mgr.busy {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView()
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if let err = mgr.error {
                    CustomErrorView(
                        title: err.title,
                        message: err.message,
                        onDismiss: { mgr.error = nil }
                    )
                }
            }
            .navigationTitle("Device Info")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        do {
                            let url = try mgr.exportToCSV()
                            exportURL = url
                            isShowingExporter = true
                        } catch {
                            mgr.error = ("Export Failed", error.localizedDescription)
                        }
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(mgr.entries.isEmpty)
                }
            }
            .fileExporter(
                isPresented: $isShowingExporter,
                document: CSVDocument(url: exportURL),
                contentType: .commaSeparatedText,
                defaultFilename: "DeviceInfo"
            ) { result in
                // completion
            }
        }
        .onAppear { mgr.initAndLoad() }
        .onDisappear { mgr.cleanup() }
    }
}

import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [UTType.commaSeparatedText] }

    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        fatalError("Not supported")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = url else {
            throw NSError(domain: "CSVDocument", code: -1, userInfo: nil)
        }
        return try FileWrapper(url: url, options: .immediate)
    }
}
