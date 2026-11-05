import ARKit
import SceneKit
import SwiftUI
import UIKit

@main
struct SonarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showScans = false

    var body: some View {
        ZStack {
            HiddenVolumeView()
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)

            ARPreview(session: model.tracker.session)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(model.recording ? 0.35 : 0.55).ignoresSafeArea())

            VStack(spacing: 14) {
                statusBar
                if model.mode.ultrasonic, model.recording || model.echogram != nil {
                    EchogramView(image: model.echogram, range: model.echoRange)
                }
                Spacer(minLength: 0)
                if model.recording {
                    Text(model.mode.hint)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    settings
                }
                controls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { model.appear() }
        .sheet(isPresented: $showScans) {
            ScansView().environmentObject(model)
        }
        .alert("Sonar", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.trackingOK ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(model.trackingText)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Spacer()
            if model.tracker.lidarActive {
                Text("LiDAR")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.25), in: Capsule())
            }
            if model.recording {
                Text(timeString(model.elapsed))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $model.mode) {
                ForEach(ScanMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(model.mode.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.mode.ultrasonic {
                row("Cadence") {
                    Picker("Cadence", selection: $model.preset) {
                        ForEach(RangePreset.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }

            row("Micro") {
                Picker("Micro", selection: $model.micID) {
                    ForEach(model.micOptions) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
            }

            row("Volume") {
                Slider(value: $model.volume, in: 0.05...1)
                    .frame(maxWidth: 170)
                Text("\(Int(model.volume * 100)) %")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }

            if model.systemVolume < 0.9 && !model.mode.ultrasonic {
                Label("Volume de l'iPhone à \(Int(model.systemVolume * 100)) % : monte-le avec les boutons, sinon la mesure est trop faible.",
                      systemImage: "speaker.wave.1.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Toggle(isOn: $model.lidar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiDAR (référence)")
                    Text(model.lidarSupported ? "Enregistre le maillage LiDAR à côté, pour comparer. Le scan reste 100 % sonore."
                                              : "Pas de LiDAR sur cet appareil.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.lidarSupported)

            if model.mode.ultrasonic {
                Text("17,5–20 kHz : inaudible pour la plupart des adultes, mais pas forcément pour les enfants, chiens et chats.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private var controls: some View {
        HStack {
            Button { showScans = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.recording)

            Spacer()

            Button { model.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: model.recording ? 8 : 32)
                        .fill(Color.red)
                        .frame(width: model.recording ? 32 : 64, height: model.recording ? 32 : 64)
                }
                .animation(.easeInOut(duration: 0.2), value: model.recording)
            }

            Spacer()

            LevelMeter(db: model.levelDB, active: model.recording)
                .frame(width: 52, height: 52)
        }
        .padding(.horizontal, 8)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct EchogramView: View {
    let image: CGImage?
    let range: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Échos").font(.footnote.weight(.semibold))
                Spacer()
                Text("plus récent en haut").font(.caption2).foregroundStyle(.secondary)
            }
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                } else {
                    Text("En attente des premiers échos…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("0 m")
                Spacer()
                Text(String(format: "%.1f m", range / 2))
                Spacer()
                Text(String(format: "%.1f m", range))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LevelMeter: View {
    let db: Float
    let active: Bool

    var body: some View {
        let v = active ? CGFloat(max(0, min(1, (db + 80) / 80))) : 0
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle()
                .trim(from: 0, to: v)
                .stroke(v > 0.95 ? Color.red : Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
            Image(systemName: "mic.fill").font(.footnote)
        }
    }
}

struct ScansView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.scans.isEmpty {
                    Text("Aucun scan pour l'instant.").foregroundStyle(.secondary)
                }
                ForEach(model.scans) { scan in
                    Button { model.export(scan) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scan.name).font(.subheadline.monospaced())
                                Text(ByteCountFormatter.string(fromByteCount: scan.sizeBytes, countStyle: .file)
                                     + (scan.hasMesh ? " · maillage LiDAR" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .onDelete { idx in idx.map { model.scans[$0] }.forEach(model.delete) }
            }
            .navigationTitle("Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .overlay {
                if model.preparingShare { ProgressView("Compression…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .sheet(item: $model.share) { item in
                ActivityView(items: [item.url])
            }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Image de la caméra, seulement pour que tu voies ce que tu scannes (et pour aider le suivi).
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}
