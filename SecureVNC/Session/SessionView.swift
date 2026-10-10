import SecureVNCKit
import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SessionModel
    @State private var keyboard = false
    @State private var trackpad = true
    @State private var barVisible = true
    @State private var copied = false

    init(host: Host) { _model = StateObject(wrappedValue: SessionModel(host: host)) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let client = model.client, model.phase == .live {
                ScreenView(client: client, trackpad: trackpad, keyboard: $keyboard)
                    .ignoresSafeArea(.container)
                topBar
            } else if let terminal = model.terminal {
                TerminalView(terminal: terminal, title: model.host.name, phase: model.phase,
                             reconnect: { model.connect(store: store) }, close: { dismiss() })
            } else {
                statusView
            }
        }
        .statusBarHidden(isScreenLive)
        .persistentSystemOverlays(isScreenLive ? .hidden : .automatic)
        .onAppear { model.connect(store: store) }
        .onDisappear { model.disconnect() }
        .onChange(of: scenePhase) { _, p in
            if p == .background { model.enterBackground() }
            if p == .active { model.enterForeground() }
        }
        .alert(item: $model.trustPrompt) { prompt in
            Alert(title: Text("Trust \(model.host.name)?"),
                  message: Text("First connection to \(model.host.sshHost). Check this matches the server:\n\n\(prompt.algorithm)\n\(prompt.fingerprint)"),
                  primaryButton: .default(Text("Trust")) { model.answerTrust(true) },
                  secondaryButton: .cancel { model.answerTrust(false) })
        }
        .task(id: barVisible) {
            guard barVisible, isScreenLive else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { barVisible = false }
        }
    }

    private var isScreenLive: Bool { model.phase == .live && model.client != nil }

    @ViewBuilder private var topBar: some View {
        if barVisible {
            HStack(spacing: 20) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Disconnect")
                Text(model.host.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Button { keyboard.toggle(); barVisible = true } label: {
                    Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel("Keyboard")
                Button { trackpad.toggle(); barVisible = true } label: {
                    Image(systemName: trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
                }
                .accessibilityLabel(trackpad ? "Trackpad mode" : "Touch mode")
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button { withAnimation { barVisible = true } } label: {
                Capsule().fill(.white.opacity(0.5)).frame(width: 44, height: 5).padding(12)
            }
            .accessibilityLabel("Show controls")
        }
    }

    private var statusView: some View {
        VStack(spacing: 18) {
            Spacer()
            switch model.phase {
            case .connecting(let text):
                ProgressView().controlSize(.large).tint(.white)
                Text(text).foregroundStyle(.white.opacity(0.85))
                Button("Cancel") { dismiss() }.foregroundStyle(.white.opacity(0.7))
            case .failed(let text, let keyRejected):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(text).multilineTextAlignment(.center).foregroundStyle(.white).padding(.horizontal, 32)
                    .textSelection(.enabled)
                if keyRejected {
                    Button(copied ? "Copied" : "Copy install command") {
                        UIPasteboard.general.string = model.installCommand
                        copied = true
                    }
                    .buttonStyle(.bordered).tint(.white)
                }
                HStack(spacing: 16) {
                    Button("Close") { dismiss() }.buttonStyle(.bordered).tint(.white)
                    Button("Reconnect") { model.connect(store: store) }.buttonStyle(.borderedProminent)
                }
            case .live:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ScreenView: UIViewRepresentable {
    let client: RFBClient
    let trackpad: Bool
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView()
        view.attach(client)
        view.onKeyboardHidden = { keyboard = false }
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.trackpadMode = trackpad
        if keyboard, !view.isFirstResponder { view.becomeFirstResponder() }
        if !keyboard, view.isFirstResponder { view.resignFirstResponder() }
    }

    static func dismantleUIView(_ view: RemoteScreenView, coordinator: ()) { view.detach() }
}
