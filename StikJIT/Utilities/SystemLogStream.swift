//
//  SystemLogStream.swift
//  StikJIT
//
//  Created by Stephen on 09/21/2025.
//

import Foundation

@MainActor
final class SystemLogStream: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let raw: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String? = nil
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published var updateInterval: TimeInterval = 0 {
        didSet {
            if updateInterval < 0 { updateInterval = 0 }
            flushTimer?.invalidate()
            flushTimer = nil
            flushImmediatelyIfNeeded()
        }
    }

    private let maxEntries = 1500
    private var pendingEntries: [Entry] = []
    private var flushTimer: Timer?
    private var retryTimer: Timer?

    func start() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard !isStreaming else {
            if isPaused { resume() }
            return
        }
        isStreaming = true
        isPaused = false
        lastError = nil

        JITEnableContext.shared.startSyslogRelay(handler: { [weak self] line in
            guard let line else { return }
            self?.handleLine(line)
        }, onError: { [weak self] error in
            self?.handleError(error as NSError?)
        })
    }

    func stop() {
        guard isStreaming else { return }
        isStreaming = false
        isPaused = false
        JITEnableContext.shared.stopSyslogRelay()
        flushTimer?.invalidate()
        flushTimer = nil
        pendingEntries.removeAll()
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func clear() {
        entries.removeAll()
        pendingEntries.removeAll()
        flushTimer?.invalidate()
        flushTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        flushTimer?.invalidate()
        flushTimer = nil
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        flushImmediatelyIfNeeded()
    }

    private func handleLine(_ line: String) {
        guard isStreaming else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = Entry(timestamp: Date(), message: prettify(line: trimmed), raw: trimmed)
        pendingEntries.append(entry)
        if pendingEntries.count > maxEntries {
            pendingEntries.removeFirst(pendingEntries.count - maxEntries)
        }
        if updateInterval == 0 && !isPaused {
            flushImmediatelyIfNeeded()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func handleError(_ error: NSError?) {
        isStreaming = false
        isPaused = false
        flushTimer?.invalidate()
        flushTimer = nil
        lastError = error?.localizedDescription ?? "System log stream stopped"
        scheduleAutoRetry()
    }

    private func prettify(line: String) -> String {
        if let range = line.range(of: ": ") {
            let messagePart = line[range.upperBound...]
            return String(messagePart)
        }
        return line
    }

    func concatenatedLog(limit: Int = 500) -> String {
        let slice = entries.suffix(limit)
        return slice.map { "[\(DateFormatter.consoleFormatter.string(from: $0.timestamp))] \($0.raw)" }
            .joined(separator: "\n")
    }

    private func appendEntry(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func flushImmediatelyIfNeeded() {
        guard !isPaused else { return }
        if updateInterval == 0 {
            while !pendingEntries.isEmpty {
                let next = pendingEntries.removeFirst()
                appendEntry(next)
            }
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        guard !isPaused else { return }
        guard !pendingEntries.isEmpty else { return }
        guard flushTimer == nil else { return }

        if updateInterval <= 0 {
            flushImmediatelyIfNeeded()
            return
        }

        flushTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.flushTimer = nil
            guard !self.isPaused else { return }
            if let next = self.pendingEntries.first {
                self.pendingEntries.removeFirst()
                self.appendEntry(next)
            }
            if !self.pendingEntries.isEmpty {
                self.scheduleFlushIfNeeded()
            }
        }

        if let flushTimer {
            RunLoop.main.add(flushTimer, forMode: .common)
        }
    }

    private func scheduleAutoRetry() {
        guard !isStreaming else { return }
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimer = nil
            if !self.isStreaming && !self.isPaused {
                self.start()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private extension DateFormatter {
    static let consoleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
