import Cocoa
import CoreGraphics

/// Monitors Control key press/release for hold-to-talk functionality using CGEvent tap.
/// Requires Accessibility permission to create the event tap.
final class HotkeyMonitor {

    // MARK: - Constants

    private static let minimumHoldDuration: TimeInterval = 0.3

    // MARK: - Callbacks

    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?

    // MARK: - State

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: DispatchSourceTimer?
    private var isRecording = false
    private var controlPressed = false

    // MARK: - Public API

    /// Starts monitoring for Control key events.
    /// - Returns: `false` if Accessibility permission is denied (event tap creation fails).
    func start() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Stops monitoring and cleans up the event tap.
    func stop() {
        cancelHoldTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRecording = false
        controlPressed = false
    }

    // MARK: - Static Helpers

    /// Returns `true` if only the Control modifier is active (no Cmd, Shift, Alt, etc.).
    static func isControlOnly(flags: CGEventFlags) -> Bool {
        let modifierMask: CGEventFlags = [.maskControl, .maskCommand, .maskShift, .maskAlternate]
        let activeModifiers = flags.intersection(modifierMask)
        return activeModifiers == .maskControl
    }

    /// Returns `true` if the given duration meets the minimum hold threshold (0.3s).
    func isHoldLongEnough(duration: TimeInterval) -> Bool {
        return duration >= HotkeyMonitor.minimumHoldDuration
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown()
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags

        if HotkeyMonitor.isControlOnly(flags: flags) && !controlPressed {
            // Control just pressed alone
            controlPressed = true
            startHoldTimer()
        } else if controlPressed && !flags.contains(.maskControl) {
            // Control released
            controlPressed = false
            cancelHoldTimer()
            if isRecording {
                isRecording = false
                onRecordingStop?()
            }
        }
    }

    private func handleKeyDown() {
        // Another key pressed while Control is held — cancel the timer
        if controlPressed && !isRecording {
            cancelHoldTimer()
            controlPressed = false
        }
    }

    // MARK: - Timer

    private func startHoldTimer() {
        cancelHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + HotkeyMonitor.minimumHoldDuration)
        timer.setEventHandler { [weak self] in
            guard let self, self.controlPressed else { return }
            self.isRecording = true
            self.onRecordingStart?()
        }
        timer.resume()
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }
}

// MARK: - C Callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }

    // Re-enable tap if it was disabled by the system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleEvent(type, event: event)
    return Unmanaged.passRetained(event)
}
