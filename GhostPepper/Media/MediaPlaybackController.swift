import Foundation
import AppKit
import Darwin
import os.log

private let logger = Logger(subsystem: "com.github.matthartman.ghostpepper", category: "MediaPlayback")

/// Pauses system media playback during recording and resumes when done.
/// Uses MediaRemote (private) for the actual play/pause commands and
/// AppleScript to query whether Spotify or Music is currently playing.
final class MediaPlaybackController {
    private let enabled: () -> Bool

    private typealias SendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let sendCommand: SendCommandFunc?
    private var didPausePlayback = false

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled

        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        frameworkHandle = handle

        if let handle {
            sendCommand = dlsym(handle, "MRMediaRemoteSendCommand")
                .map { unsafeBitCast($0, to: SendCommandFunc.self) }
        } else {
            sendCommand = nil
        }
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    /// Pauses media if Spotify or Apple Music is currently playing.
    /// Uses AppleScript to query player state (requires NSAppleEventsUsageDescription
    /// in Info.plist so macOS can prompt the user for authorization).
    func pauseIfPlaying() async {
        guard enabled(), let sendCommand else { return }

        let isPlaying = await Self.queryMediaAppsIsPlaying()
        logger.debug("pauseIfPlaying: isPlaying=\(isPlaying)")

        if isPlaying {
            _ = sendCommand(Self.kMRPause, nil)
            didPausePlayback = true
        }
    }

    /// Resumes media playback only if we paused it. Call after recording ends.
    func resumeIfPaused() {
        guard enabled(), didPausePlayback, let sendCommand else { return }
        logger.debug("resumeIfPaused: sending kMRPlay")
        didPausePlayback = false
        _ = sendCommand(Self.kMRPlay, nil)
    }

    /// Asks Spotify and Apple Music (only if running) for their player state via AppleScript.
    /// Returns true if either reports "playing".
    private static func queryMediaAppsIsPlaying() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
                let candidates: [(bundleID: String, appName: String)] = [
                    ("com.spotify.client", "Spotify"),
                    ("com.apple.Music", "Music")
                ]
                for candidate in candidates {
                    guard runningBundleIDs.contains(candidate.bundleID) else { continue }
                    let script = "tell application id \"\(candidate.bundleID)\" to return player state as string"
                    var error: NSDictionary?
                    if let appleScript = NSAppleScript(source: script) {
                        let result = appleScript.executeAndReturnError(&error)
                        logger.debug("AppleScript \(candidate.appName): state=\(result.stringValue ?? "nil")")
                        if result.stringValue == "playing" {
                            continuation.resume(returning: true)
                            return
                        }
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }
}
