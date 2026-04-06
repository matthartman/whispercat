import Cocoa
import AVFoundation
import CoreGraphics
import IOKit.hidsystem

enum MicrophonePermissionStatus: Equatable {
    case authorized
    case denied
    case notDetermined
}

class PermissionChecker {
    struct Client {
        let checkAccessibility: () -> Bool
        let promptAccessibility: () -> Void
        let microphoneStatus: () -> MicrophonePermissionStatus
        let requestMicrophoneAccess: () async -> Bool
        let openAccessibilitySettings: () -> Void
        let openMicrophoneSettings: () -> Void
    }

    static let defaultClient: Client = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return Client.test
        }
        return Client.live
    }()

    static var current = defaultClient

    static func checkAccessibility() -> Bool {
        current.checkAccessibility()
    }

    static func promptAccessibility() {
        current.promptAccessibility()
    }

    static func microphoneStatus() -> MicrophonePermissionStatus {
        current.microphoneStatus()
    }

    static func checkMicrophone() async -> Bool {
        let status = microphoneStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await current.requestMicrophoneAccess()
        case .denied:
            return false
        }
    }

    static func openAccessibilitySettings() {
        current.openAccessibilitySettings()
    }

    static func openMicrophoneSettings() {
        current.openMicrophoneSettings()
    }

    static func checkInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension PermissionChecker.Client {
    static let live = PermissionChecker.Client(
        checkAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        promptAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        },
        microphoneStatus: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .notDetermined:
                return .notDetermined
            default:
                return .denied
            }
        },
        requestMicrophoneAccess: {
            await AVCaptureDevice.requestAccess(for: .audio)
        },
        openAccessibilitySettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                NSWorkspace.shared.open(url)
            }
        },
        openMicrophoneSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    )

    static let test = PermissionChecker.Client(
        checkAccessibility: { false },
        promptAccessibility: {},
        microphoneStatus: { .denied },
        requestMicrophoneAccess: { false },
        openAccessibilitySettings: {},
        openMicrophoneSettings: {}
    )
}
