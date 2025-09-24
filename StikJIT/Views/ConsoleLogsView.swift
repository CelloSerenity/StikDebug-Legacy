//
//  ConsoleLogsView.swift
//  StikJIT
//
//  Created by neoarz on 3/29/25.
//

import SwiftUI
import UIKit

struct ConsoleLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accentColor) private var environmentAccentColor
    @StateObject private var logManager = LogManager.shared
    @State private var jitScrollView: ScrollViewProxy? = nil
    @AppStorage("customAccentColor") private var customAccentColorHex: String = ""
    
    @State private var showingCustomAlert = false
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    @State private var isError = false
    
    @State private var logCheckTimer: Timer? = nil
    
    @State private var isViewActive = false
    @State private var lastProcessedLineCount = 0
    @State private var isLoadingLogs = false
    @State private var jitIsAtBottom = true
    @AppStorage("appTheme") private var appThemeRaw: String = AppTheme.system.rawValue
    @Environment(\.themeExpansionManager) private var themeExpansion
    private var backgroundStyle: BackgroundStyle { themeExpansion?.backgroundStyle(for: appThemeRaw) ?? AppTheme.system.backgroundStyle }
    private var preferredScheme: ColorScheme? { themeExpansion?.preferredColorScheme(for: appThemeRaw) }

    private var accentColor: Color {
        themeExpansion?.resolvedAccentColor(from: customAccentColorHex) ?? .blue
    }

    private var overlayOpacity: Double {
        colorScheme == .dark ? 0.82 : 0.9
    }

    var body: some View {
        NavigationView {
            ZStack {
                ThemedBackground(style: backgroundStyle)
                    .ignoresSafeArea()
                Color(colorScheme == .dark ? .black : .white)
                    .opacity(overlayOpacity)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    jitLogsPane
                    Spacer(minLength: 0)
                    jitFooter
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Console Logs")
                            .font(.headline)
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                    }

                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { dismiss() }) {
                            HStack(spacing: 2) {
                                Text("Exit")
                                    .fontWeight(.regular)
                            }
                            .foregroundColor(accentColor)
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack {
                            Button(action: {
                                Task { await loadIdeviceLogsAsync() }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(accentColor)
                            }

                            Button(action: {
                                logManager.clearLogs()
                            }) {
                                Text("Clear")
                                    .foregroundColor(accentColor)
                            }
                        }
                    }
                }
            }
            .overlay(
                Group {
                    if showingCustomAlert {
                        Color.black.opacity(0.4)
                            .edgesIgnoringSafeArea(.all)
                            .overlay(
                                CustomErrorView(
                                    title: alertTitle,
                                    message: alertMessage,
                                    onDismiss: {
                                        showingCustomAlert = false
                                    },
                                    showButton: true,
                                    primaryButtonText: "OK",
                                    messageType: isError ? .error : .success
                                )
                            )
                    }
                }
            )
        }
        .preferredColorScheme(preferredScheme)
    }
    
    private var jitLogsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("=== DEVICE INFORMATION ===")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(.vertical, 4)

                        Text("iOS Version: \(UIDevice.current.systemVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text("Device: \(UIDevice.current.name)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text("Model: \(UIDevice.current.model)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text("=== LOG ENTRIES ===")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(.vertical, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    ForEach(logManager.logs) { logEntry in
                        Text(AttributedString(createLogAttributedString(logEntry)))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 4)
                            .id(logEntry.id)
                    }
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("jitScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "jitScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                jitIsAtBottom = offset > -20
            }
            .onChange(of: logManager.logs.count) { _ in
                guard jitIsAtBottom, let lastLog = logManager.logs.last else { return }
                withAnimation {
                    proxy.scrollTo(lastLog.id, anchor: .bottom)
                }
            }
            .onAppear {
                jitScrollView = proxy
                isViewActive = true
                Task { await loadIdeviceLogsAsync() }
                startLogCheckTimer()
            }
            .onDisappear {
                isViewActive = false
                stopLogCheckTimer()
            }
        }
    }

    private var jitFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundColor(.red)
                Text("\(logManager.errorCount) Errors")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)

            Button {
                var logsContent = "=== DEVICE INFORMATION ===\n"
                logsContent += "Version: \(UIDevice.current.systemVersion)\n"
                logsContent += "Name: \(UIDevice.current.name)\n"
                logsContent += "Model: \(UIDevice.current.model)\n"
                logsContent += "StikJIT Version: App Version: 1.0\n\n"
                logsContent += "=== LOG ENTRIES ===\n"

                logsContent += logManager.logs.map {
                    "[\(formatTime(date: $0.timestamp))] [\($0.type.rawValue)] \($0.message)"
                }.joined(separator: "\n")

                UIPasteboard.general.string = logsContent

                alertTitle = "Logs Copied"
                alertMessage = "Logs have been copied to clipboard."
                isError = false
                showingCustomAlert = true
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(accentColor)
            }
            .buttonStyle(GlassOvalButtonStyle(height: 36, strokeOpacity: 0.18))
            .accessibilityLabel("Copy app logs")

            exportControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var exportControl: some View {
        let logURL: URL = URL.documentsDirectory.appendingPathComponent("idevice_log.txt")
        if FileManager.default.fileExists(atPath: logURL.path) {
            ShareLink(
                item: logURL,
                preview: SharePreview("idevice_log.txt", image: Image(systemName: "doc.text"))
            ) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(accentColor)
            }
            .buttonStyle(GlassOvalButtonStyle(height: 36, strokeOpacity: 0.18))
            .accessibilityLabel("Export app logs")
        } else {
            Button {
                alertTitle = "Export Failed"
                alertMessage = "No idevice logs found"
                isError = true
                showingCustomAlert = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(accentColor)
            }
            .buttonStyle(GlassOvalButtonStyle(height: 36, strokeOpacity: 0.18))
            .accessibilityLabel("Export app logs")
        }
    }
    
    private func createLogAttributedString(_ logEntry: LogManager.LogEntry) -> NSAttributedString {
        let fullString = NSMutableAttributedString()
        
        let timestampString = "[\(formatTime(date: logEntry.timestamp))]"
        let timestampAttr = NSAttributedString(
            string: timestampString,
            attributes: [.foregroundColor: colorScheme == .dark ? UIColor.gray : UIColor.darkGray]
        )
        fullString.append(timestampAttr)
        fullString.append(NSAttributedString(string: " "))
        
        let typeString = "[\(logEntry.type.rawValue)]"
        let typeColor = UIColor(colorForLogType(logEntry.type))
        let typeAttr = NSAttributedString(
            string: typeString,
            attributes: [.foregroundColor: typeColor]
        )
        fullString.append(typeAttr)
        fullString.append(NSAttributedString(string: " "))
        
        let messageAttr = NSAttributedString(
            string: logEntry.message,
            attributes: [.foregroundColor: colorScheme == .dark ? UIColor.white : UIColor.black]
        )
        fullString.append(messageAttr)
        
        return fullString
    }
    private func formatTime(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func colorForLogType(_ type: LogManager.LogEntry.LogType) -> Color {
        switch type {
        case .info:
            return .green
        case .error:
            return .red
        case .debug:
            return accentColor
        case .warning:
            return .orange
        }
    }
    
    private func loadIdeviceLogsAsync() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true
        
        let logPath = URL.documentsDirectory.appendingPathComponent("idevice_log.txt").path
        
        guard FileManager.default.fileExists(atPath: logPath) else {
            await MainActor.run {
                logManager.addInfoLog("No idevice logs found (Restart the app to continue reading)")
                isLoadingLogs = false
            }
            return
        }
        
        do {
            let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = logContent.components(separatedBy: .newlines)
            
            let maxLines = 500
            let startIndex = max(0, lines.count - maxLines)
            let recentLines = Array(lines[startIndex..<lines.count])
            
            lastProcessedLineCount = lines.count
            
            await MainActor.run {
                logManager.clearLogs()
                
                for line in recentLines {
                    if line.isEmpty { continue }
                    
                    if line.contains("=== DEVICE INFORMATION ===") ||
                       line.contains("Version:") ||
                       line.contains("Name:") ||
                       line.contains("Model:") ||
                       line.contains("=== LOG ENTRIES ===") {
                        continue
                    }
                    
                    if line.contains("ERROR") || line.contains("Error") {
                        logManager.addErrorLog(line)
                    } else if line.contains("WARNING") || line.contains("Warning") {
                        logManager.addWarningLog(line)
                    } else if line.contains("DEBUG") {
                        logManager.addDebugLog(line)
                    } else {
                        logManager.addInfoLog(line)
                    }
                }

                if jitIsAtBottom, let last = logManager.logs.last {
                    jitScrollView?.scrollTo(last.id, anchor: .bottom)
                }
            }
        } catch {
            await MainActor.run {
                logManager.addErrorLog("Failed to read idevice logs: \(error.localizedDescription)")
            }
        }
        
        await MainActor.run {
            isLoadingLogs = false
        }
    }
    
    private func startLogCheckTimer() {
        logCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            if isViewActive {
                Task {
                    await checkForNewLogs()
                }
            }
        }
    }
    
    private func checkForNewLogs() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true
        
        let logPath = URL.documentsDirectory.appendingPathComponent("idevice_log.txt").path
        
        guard FileManager.default.fileExists(atPath: logPath) else {
            isLoadingLogs = false
            return
        }
        
        do {
            let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = logContent.components(separatedBy: .newlines)
            
            if lines.count > lastProcessedLineCount {
                let newLines = Array(lines[lastProcessedLineCount..<lines.count])
                lastProcessedLineCount = lines.count
                
                await MainActor.run {
                    for line in newLines {
                        if line.isEmpty { continue }
                        
                        if line.contains("ERROR") || line.contains("Error") {
                            logManager.addErrorLog(line)
                        } else if line.contains("WARNING") || line.contains("Warning") {
                            logManager.addWarningLog(line)
                        } else if line.contains("DEBUG") {
                            logManager.addDebugLog(line)
                        } else {
                            logManager.addInfoLog(line)
                        }
                    }
                    
                    let maxLines = 500
                    if logManager.logs.count > maxLines {
                        let excessCount = logManager.logs.count - maxLines
                        logManager.removeOldestLogs(count: excessCount)
                    }

                    if jitIsAtBottom, let last = logManager.logs.last {
                        jitScrollView?.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        } catch {
            await MainActor.run {
                logManager.addErrorLog("Failed to read new logs: \(error.localizedDescription)")
            }
        }
        
        isLoadingLogs = false
    }
    
    private func stopLogCheckTimer() {
        logCheckTimer?.invalidate()
        logCheckTimer = nil
    }
}

private struct GlassOvalButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    var strokeOpacity: Double = 0.16
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: configuration.isPressed ? 4 : 10, x: 0, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ConsoleLogsView_Previews: PreviewProvider {
    static var previews: some View {
        ConsoleLogsView()
            .themeExpansionManager(ThemeExpansionManager(previewUnlocked: true))
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
