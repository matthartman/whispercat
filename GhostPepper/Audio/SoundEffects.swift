import AppKit

class SoundEffects {
    private let startSound: NSSound?
    private let stopSound: NSSound?

    init() {
        startSound = NSSound(named: "Tink")
        stopSound = NSSound(named: "Pop")
    }

    func playStart() {
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        stopSound?.stop()
        stopSound?.play()
    }
}
