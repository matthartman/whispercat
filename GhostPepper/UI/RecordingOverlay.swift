import SwiftUI
import AppKit

enum OverlayMessage: String {
    case recording = "Recording..."
    case modelLoading = "Model still loading..."
    case cleaningUp = "Cleaning up..."
    case transcribing = "Transcribing..."
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?
    private var currentMessage: OverlayMessage = .recording

    func show(message: OverlayMessage = .recording) {
        currentMessage = message

        if let hostingView = hostingView {
            hostingView.rootView = OverlayPillView(message: message)
            panel?.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: OverlayPillView(message: message))
        panel.contentView = hosting
        self.hostingView = hosting

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 110
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    @State private var isPulsing = false

    private var dotColor: Color {
        switch message {
        case .recording: return .red
        case .modelLoading: return .orange
        case .cleaningUp, .transcribing: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .opacity(isPulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)

            Text(message.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .onAppear { isPulsing = true }
    }
}
