import SwiftUI
import FilmCore

/// Réglages : pellicule et effets, outils de visée, vidéo, photo.
struct SettingsView: View {
    @ObservedObject var model: CineModel
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(FilmStock.allCases, id: \.self) { stock in
                        Button {
                            model.render.stock = stock
                        } label: {
                            HStack(spacing: 12) {
                                Text(stock.code)
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(stock == model.render.stock ? .black : Palette.amber)
                                    .frame(width: 50, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(stock == model.render.stock ? Palette.amber : Color.white.opacity(0.08)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stock.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(stock.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if stock == model.render.stock {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.amber)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Pellicule")
                } footer: {
                    Text("S'applique aux photos et aux vidéos. Bouton « pellicule » en bas à droite pour changer en un geste.")
                }

                Section {
                    LabeledPicker(title: "Grain", selection: $model.render.grain, values: GrainLevel.allCases) { $0.shortLabel }
                    LabeledPicker(title: "Halation", selection: $model.render.halation, values: HalationLevel.allCases) { $0.shortLabel }
                    LabeledPicker(title: "Diffusion", selection: $model.render.diffusion, values: DiffusionLevel.allCases) { $0.shortLabel }
                    LabeledPicker(title: "Flares anamorphiques", selection: $model.render.streaks, values: StreakLevel.allCases) { $0.shortLabel }
                    Toggle("Vignettage léger", isOn: $model.render.vignette)
                        .tint(Palette.amber)
                } header: {
                    Text("Effets optiques")
                } footer: {
                    Text("Halation : halo rouge orangé autour des lumières fortes. Diffusion : voile lumineux d'un filtre Black Pro-Mist (1/8 à 1/2). Flares : traits bleutés le long de l'image depuis les lumières vives, comme avec un objectif anamorphique.")
                }

                Section {
                    Toggle("Zébras (zones brûlées)", isOn: $model.tools.zebras)
                    Toggle("Focus peaking", isOn: $model.tools.peaking)
                    Toggle("Histogramme", isOn: $model.tools.histogram)
                    Toggle("Niveau", isOn: $model.tools.level)
                    Toggle("Grille des tiers", isOn: $model.showGrid)
                } header: {
                    Text("Visée")
                } footer: {
                    Text("Zébras : rayures sur ce qui sera blanc. Focus peaking : les contours nets en ambre. Rien de tout cela n'apparaît sur les photos ni les vidéos.")
                }
                .tint(Palette.amber)

                Section {
                    LabeledPicker(title: "Format", selection: $model.format, values: AspectFormat.allCases) { $0.label }
                } header: {
                    Text("Format de l'image (\(camera.mode == .video ? "vidéo" : "photo"))")
                } footer: {
                    Text("Retenu séparément en photo et en vidéo. Les formats larges coupent le haut et le bas : tiens l'iPhone à l'horizontale pour un cadre de cinéma (2,39:1 = Scope).")
                }

                Section {
                    LabeledPicker(title: "Définition", selection: $model.video.resolution, values: VideoResolution.allCases) { $0.shortLabel }
                    Picker("Cadence", selection: $model.video.frameRate) {
                        ForEach(FrameRate.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledPicker(title: "Stabilisation", selection: $model.video.stabilization, values: StabilizationChoice.allCases) { $0.label }
                    Toggle("Son", isOn: $model.video.audio)
                        .tint(Palette.amber)
                } header: {
                    Text("Vidéo")
                } footer: {
                    Text("24 i/s avec l'obturateur à 180° (1/48 s) : le flou de mouvement du cinéma. Sous des lampes en France, 25 i/s évite le scintillement. Le ralenti est enregistré sans son. Le rendu pellicule est appliqué à chaque image pendant l'enregistrement (HEVC, BT.709).")
                }

                Section {
                    LabeledPicker(title: "Retardateur", selection: $model.selfTimer, values: SelfTimer.allCases) { $0.label }
                    Toggle("Garder aussi le RAW (DNG)", isOn: $model.keepRaw)
                        .tint(Palette.amber)
                    Toggle("Enregistrer le lieu", isOn: $model.saveLocation)
                        .tint(Palette.amber)
                    if model.saveLocation, model.location.denied {
                        Text("Lieu refusé : Réglages › Ciné › Position.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Photo")
                } footer: {
                    Text("Le RAW est joint à la photo dans Photos (environ 25 Mo de plus). Le lieu est ajouté aux photos et aux vidéos.")
                }

                Section("Développement") {
                    LabeledContent("Capture photo", value: camera.rawAvailable ? "RAW du capteur" : "HEIF (pas de RAW sur cet objectif)")
                    Text("Ciné récupère les données brutes du capteur et les développe lui-même : pas de Smart HDR, pas de Deep Fusion, pas de renforcement de netteté ni de tone mapping local. Puis vient la courbe de la pellicule. Photos en HEIF 10 bits (Display P3).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink("Journal") {
                        ScrollView {
                            Text(Log.shared.recent())
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("Journal")
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

/// Titre et choix segmenté sur deux lignes (les libellés ont la place).
struct LabeledPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
