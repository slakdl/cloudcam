import CoreImage
import SwiftUI

struct ContentView: View {
    @State private var camera: CameraService
    @State private var renderer: CameraRenderer
    @AppStorage("mode") private var mode: CloudLook.Mode = .cloud
    @State private var isSaving = false
    @State private var flash = false
    @State private var message: String?
    @State private var showsSettings = false

    init() {
        let camera = CameraService()
        _camera = State(initialValue: camera)
        _renderer = State(initialValue: CameraRenderer(frames: camera.frames))
    }

    var body: some View {
        ZStack {
            // The camera fills the whole screen, but the buttons and messages
            // below stay clear of the notch and the home bar.
            Color.black.ignoresSafeArea()

            CameraPreviewView(
                renderer: renderer,
                mode: mode,
                showsTestPattern: camera.status == .unavailable
            )
            .ignoresSafeArea()

            // A quick white blink when the picture is taken.
            Color.white
                .ignoresSafeArea()
                .opacity(flash ? 0.85 : 0)
                .allowsHitTesting(false)

            VStack {
                if camera.status == .unavailable {
                    banner("No camera here (simulator), showing a test pattern")
                }
                if let message {
                    banner(message)
                }
                Spacer()
                modePicker
                controls
            }
            .padding()

            if camera.status == .denied {
                deniedMessage
            }
        }
        .task {
            try? await Publisher.shared.sendWaiting()  // anything left over from last time
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(8)
            .background(.black.opacity(0.5), in: Capsule())
            .foregroundStyle(.white)
            .transition(.opacity)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(CloudLook.Mode.allCases) { option in
                Button(option.rawValue) { mode = option }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .foregroundStyle(mode == option ? .black : .white)
                    .background(mode == option ? Color.white : Color.black.opacity(0.45), in: Capsule())
            }
        }
        .padding(.bottom, 16)
    }

    /// Settings on the left, the shutter (save) in the middle, save + publish on the right.
    private var controls: some View {
        HStack {
            sideButton("gearshape", label: "Publishing settings") { showsSettings = true }
            Spacer()
            shutterButton
            Spacer()
            sideButton("arrow.up.circle", label: "Save and publish") { takePhoto(publish: true) }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .sheet(isPresented: $showsSettings) { SettingsView() }
    }

    private func sideButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.35), in: Circle())
        }
        .disabled(isSaving || camera.status == .denied)
        .opacity(isSaving ? 0.5 : 1)
        .accessibilityLabel(label)
    }

    private var shutterButton: some View {
        Button { takePhoto(publish: false) } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                Circle().fill(.white).padding(7)
            }
            .frame(width: 76, height: 76)
            .opacity(isSaving ? 0.5 : 1)
        }
        .disabled(isSaving || camera.status == .denied)
        .accessibilityLabel("Take photo")
    }

    private func takePhoto(publish: Bool) {
        // Save exactly what's on screen. Encode now, because the picture changes every frame.
        guard let picture = renderer.snapshot(), let jpeg = PhotoSaver.jpeg(from: picture) else { return }
        if publish && Keychain.token == nil {
            showsSettings = true
            show("Add a GitHub token first, then publish")
            return
        }

        isSaving = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.08)) { flash = false }
        let takenAt = Date()

        Task {
            do {
                try await PhotoSaver.save(jpeg)
                show(publish ? "Saved, publishing…" : "Saved to Photos")
            } catch PhotoSaver.Failure.accessDenied {
                show("Photos access is off. Turn it on in Settings to save pictures.")
            } catch {
                show("Couldn't save the picture")
            }
            isSaving = false

            // Publishing carries on in the background, so you can keep shooting.
            guard publish else { return }
            do {
                let waiting = try await Publisher.shared.publish(jpeg, takenAt: takenAt)
                show(waiting == 0 ? "Published to the site" : "Published, \(waiting) still waiting")
            } catch Publisher.Failure.noToken {
                show("Add a GitHub token to publish")
            } catch Publisher.Failure.rejected(let status) where status == 401 || status == 403 {
                show("GitHub refused the token. Check it in settings.")
            } catch {
                show("No connection. It'll publish next time.")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if message == text { message = nil } }
        }
    }

    private var deniedMessage: some View {
        VStack(spacing: 12) {
            Text("Camera access is off")
                .font(.headline)
            Text("Turn it on in Settings to take pictures.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

#Preview {
    ContentView()
}
