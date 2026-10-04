//
//  TeleprompterManager.swift
//  boringNotch
//
//  Scroll state for the teleprompter tab. The script scrolls right under the
//  camera, so reading it keeps your eyes close to the lens.
//

import Combine
import Defaults
import Foundation

@MainActor
final class TeleprompterManager: ObservableObject {
    static let shared = TeleprompterManager()

    static let speedRange: ClosedRange<Double> = 10...160
    static let fontSizeRange: ClosedRange<Double> = 14...40

    @Published private(set) var isRunning = false
    /// Distance scrolled while paused; the live offset adds elapsed time × speed on top.
    @Published private(set) var baseOffset: CGFloat = 0
    @Published private(set) var startedAt: Date?

    /// Height of the rendered script, reported by the view so scrolling can stop at the end.
    var contentHeight: CGFloat = 0 {
        didSet {
            if isRunning, contentHeight != oldValue { scheduleEnd() }
        }
    }

    private var endTask: Task<Void, Never>?
    private var holdsNotchOpen = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Keep the reading position stable when the speed changes mid-scroll.
        Defaults.publisher(.teleprompterSpeed, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.pause()
                    self.start()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.teleprompterText, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.reset() }
            }
            .store(in: &cancellables)
    }

    func offset(at date: Date) -> CGFloat {
        guard let startedAt else { return baseOffset }
        let scrolled = baseOffset + CGFloat(date.timeIntervalSince(startedAt) * Defaults[.teleprompterSpeed])
        return contentHeight > 0 ? min(scrolled, contentHeight) : scrolled
    }

    var isAtEnd: Bool {
        contentHeight > 0 && offset(at: Date()) >= contentHeight
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        if isAtEnd { baseOffset = 0 }
        startedAt = Date()
        isRunning = true
        holdNotchOpen(true)
        scheduleEnd()
    }

    func pause() {
        guard isRunning else { return }
        baseOffset = offset(at: Date())
        startedAt = nil
        isRunning = false
        endTask?.cancel()
        holdNotchOpen(false)
    }

    func reset() {
        pause()
        baseOffset = 0
    }

    /// Nudges the script by `delta` points, e.g. from the scroll wheel.
    func scrub(by delta: CGFloat) {
        let current = offset(at: Date())
        let upperBound = contentHeight > 0 ? contentHeight : .greatestFiniteMagnitude
        baseOffset = min(max(0, current + delta), upperBound)
        if isRunning {
            startedAt = Date()
            scheduleEnd()
        }
    }

    /// Pauses automatically once the end of the script has scrolled past.
    private func scheduleEnd() {
        endTask?.cancel()
        guard contentHeight > 0 else { return }
        let remaining = max(0, Double(contentHeight - offset(at: Date())) / Defaults[.teleprompterSpeed])
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            self.pause()
        }
    }

    /// While the script scrolls, the notch must not close when the pointer leaves it.
    private func holdNotchOpen(_ hold: Bool) {
        guard hold != holdsNotchOpen else { return }
        holdsNotchOpen = hold
        if hold {
            SharingStateManager.shared.beginInteraction()
        } else {
            SharingStateManager.shared.endInteraction()
        }
    }
}
