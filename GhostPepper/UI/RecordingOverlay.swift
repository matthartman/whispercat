import SwiftUI
import AppKit

enum OverlayMessage: Equatable {
    case recording
    case modelLoading
    case cleaningUp
    case transcribing
    case clipboardFallback
    case noSoundDetected
    case learnedCorrection(MisheardReplacement)

    var primaryText: String {
        switch self {
        case .recording:
            return "Recording..."
        case .modelLoading:
            return "Loading models..."
        case .cleaningUp:
            return "Cleaning up..."
        case .transcribing:
            return "Transcribing..."
        case .clipboardFallback:
            return "Copied to clipboard"
        case .noSoundDetected:
            return "No sound detected"
        case .learnedCorrection:
            return "Learned correction"
        }
    }

    var secondaryText: String? {
        switch self {
        case .clipboardFallback:
            return "⌘V to paste"
        case .noSoundDetected:
            return "Check your mic in Settings → Recording"
        case .learnedCorrection(let replacement):
            return "\(replacement.wrong) -> \(replacement.right)"
        default:
            return nil
        }
    }
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentMessage: OverlayMessage?
    var onNoSoundSettingsTapped: (() -> Void)?
    var audioLevelMonitor: AudioLevelMonitor?

    func show(message: OverlayMessage = .recording) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let hostingView = hostingView, let panel = panel {
            let size = panelSize(for: message)
            hostingView.rootView = OverlayPillView(
                message: message,
                audioLevelMonitor: message == .recording ? audioLevelMonitor : nil,
                onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil
            )
            panel.setContentSize(size)
            panel.ignoresMouseEvents = message != .noSoundDetected
            panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            position(panel: panel)
            panel.orderFrontRegardless()
            currentMessage = message
            scheduleDismissIfNeeded(for: message)
            return
        }

        let size = panelSize(for: message)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = message != .noSoundDetected
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: OverlayPillView(
            message: message,
            audioLevelMonitor: message == .recording ? audioLevelMonitor : nil,
            onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil
        ))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let contentViewController = NSViewController()
        contentViewController.view = container
        panel.contentViewController = contentViewController
        self.hostingView = hosting

        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel
        currentMessage = message
        scheduleDismissIfNeeded(for: message)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        currentMessage = nil
    }

    func dismiss(ifShowing message: OverlayMessage) {
        guard currentMessage == message else {
            return
        }

        dismiss()
    }

    private func position(panel: NSPanel) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func panelSize(for message: OverlayMessage) -> NSSize {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            return NSSize(width: 420, height: 84)
        case .recording:
            return NSSize(width: 300, height: 72)
        default:
            return NSSize(width: 300, height: 60)
        }
    }

    private func scheduleDismissIfNeeded(for message: OverlayMessage) {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            let delay: TimeInterval = message == .noSoundDetected ? 5 : 3
            let workItem = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        default:
            return
        }
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    @ObservedObject private var levelMonitor: AudioLevelMonitor
    var onTap: (() -> Void)?
    @State private var isPulsing = false

    init(message: OverlayMessage, audioLevelMonitor: AudioLevelMonitor? = nil, onTap: (() -> Void)? = nil) {
        self.message = message
        self.levelMonitor = audioLevelMonitor ?? AudioLevelMonitor()
        self.onTap = onTap
    }

    private var dotColor: Color {
        switch message {
        case .recording:
            return .red
        case .modelLoading:
            return .orange
        case .cleaningUp, .transcribing, .clipboardFallback:
            return .blue
        case .noSoundDetected:
            return .orange
        case .learnedCorrection:
            return .green
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if message == .modelLoading {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else if case .learnedCorrection = message {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
            } else if message == .recording {
                AudioWaveformView(levels: levelMonitor.levels)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .opacity(isPulsing ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.primaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                if message == .recording && levelMonitor.isSilent {
                    Text("No audio detected — check your mic")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                } else if message == .recording, let deviceName = levelMonitor.activeDeviceName {
                    Text(deviceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                } else if let secondaryText = message.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .onAppear { isPulsing = true }
        .onTapGesture {
            onTap?()
        }
    }
}

struct AudioWaveformView: View {
    let levels: [Float]
    @State private var animationPhase: Double = 0

    // Base heights per bar so they look like a waveform even at idle
    private let basePattern: [CGFloat] = [0.35, 0.55, 0.7, 0.5, 0.3]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { index in
                let audioLevel = CGFloat(levels[index])
                let phase = sin(animationPhase + Double(index) * 1.3) * 0.15
                let base = basePattern[index] + CGFloat(phase)
                let height = audioLevel > 0.01
                    ? max(base, audioLevel) * 30
                    : 4.0

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3, height: max(4, height))
                    .animation(.easeOut(duration: audioLevel > 0.01 ? 0.08 : 0.25), value: audioLevel)
            }
        }
        .frame(height: 30)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                animationPhase = .pi * 2
            }
        }
    }
}
