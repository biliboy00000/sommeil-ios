import SwiftUI
import FilmCore

/// L'écran de prise de vue : viseur avec le rendu pellicule en direct, réglages manuels, déclencheur.
struct CameraView: View {
    @ObservedObject var model: CineModel
    @ObservedObject var camera: CameraController
    @ObservedObject var gallery: Gallery
    @ObservedObject var developer: Developer
    @ObservedObject var motion: OrientationTracker

    @State var activeControl: CameraControl?
    @State var focusPoint: CGPoint?
    @State var focusToken = 0
    @State var lastTouch: CGPoint = .zero
    @State var showSettings = false
    @State var showGallery = false
    @State var gallerySelection: String?

    private var rotation: Angle { .degrees(motion.orientation.iconRotation) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.access == .denied {
                AccessDeniedView()
            } else {
                content
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) { RenderSettingsView(model: model, camera: camera) }
        .fullScreenCover(isPresented: $showGallery) { GalleryViewer(gallery: gallery, selection: $gallerySelection) }
        .modifier(HardwareShutter(action: model.shoot))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: motion.orientation)
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .frame(height: 52)
            viewfinder
            controlStrip
                .padding(.horizontal, 10)
                .padding(.top, 10)
            Spacer(minLength: 6)
            bottomBar
                .padding(.horizontal, 30)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .top) { toast }
    }

    // MARK: Barre du haut

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .rotationEffect(rotation)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Réglages du rendu")

            Spacer(minLength: 0)
            readout
            Spacer(minLength: 0)

            Menu {
                Picker("Format", selection: $model.format) {
                    ForEach(AspectFormat.allCases, id: \.self) { format in
                        Text(format.label).tag(format)
                    }
                }
            } label: {
                Text(model.format.label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.format == .standard ? .white : Palette.amber)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .rotationEffect(rotation)
            }
            .accessibilityLabel("Format de l'image")
        }
        .foregroundStyle(.white)
    }

    private var readout: some View {
        HStack(spacing: 10) {
            Text(camera.rawAvailable ? "RAW" : "HEIF")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(camera.rawAvailable ? .black : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(camera.rawAvailable ? Palette.amber : Color.white.opacity(0.2)))
            Text(ExposureText.iso(camera.manualISO ?? camera.liveISO))
                .foregroundStyle(camera.manualISO == nil ? .white : Palette.amber)
            Text(ExposureText.shutter(camera.manualShutter ?? camera.liveShutter))
                .foregroundStyle(camera.manualShutter == nil ? .white : Palette.amber)
            Text(ExposureText.kelvin(camera.manualKelvin ?? camera.liveKelvin))
                .foregroundStyle(camera.manualKelvin == nil ? .white : Palette.amber)
        }
        .font(Palette.readout)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .monospacedDigit()
    }

    // MARK: Viseur

    private var viewfinder: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                PreviewView(renderer: camera.renderer)
                FormatMatte(format: model.format, showGrid: model.showGrid)
                if let focusPoint {
                    FocusReticle(locked: camera.locked, rotation: rotation)
                        .position(focusPoint)
                        .id(focusToken)
                }
                Color.black
                    .opacity(model.flash ? 0.9 : 0)
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    viewfinderBottom
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                if !model.showLook {
                    VStack {
                        Text("APERÇU BRUT")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .rotationEffect(rotation)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { lastTouch = $0.startLocation })
            .onTapGesture { location in tapped(at: location, in: size, lock: false) }
            .onLongPressGesture(minimumDuration: 0.5) { tapped(at: lastTouch, in: size, lock: true) }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
    }

    @ViewBuilder private var viewfinderBottom: some View {
        if let control = activeControl {
            dial(for: control)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if camera.lenses.count > 1 {
            lensPicker
                .transition(.opacity)
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach(camera.lenses) { lens in
                let selected = lens.id == camera.lensID
                Button {
                    model.selectLens(lens)
                } label: {
                    Text(lens.label)
                        .font(.system(size: selected ? 13 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Palette.amber : .white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(Circle().fill(.black.opacity(selected ? 0.6 : 0.4)))
                        .rotationEffect(rotation)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Objectif \(lens.label), \(Int(lens.focal.rounded())) mm")
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.25)))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: camera.lensID)
    }

    private func tapped(at point: CGPoint, in size: CGSize, lock: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        if activeControl != nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { activeControl = nil }
            if !lock { return }
        }
        focusToken += 1
        focusPoint = point
        // Repère du capteur (couché) pour l'objectif arrière tenu en portrait.
        let devicePoint = CGPoint(x: min(max(point.y / size.height, 0), 1), y: min(max(1 - point.x / size.width, 0), 1))
        camera.focus(at: devicePoint, lock: lock)
        if lock { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        let token = focusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard token == focusToken, !camera.locked else { return }
            withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
        }
    }

    // MARK: Réglages manuels

    private var controlStrip: some View {
        HStack(spacing: 2) {
            ForEach(CameraControl.allCases) { control in
                ControlChip(control: control, value: chipValue(control), isManual: isManual(control),
                            isSelected: activeControl == control) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        activeControl = activeControl == control ? nil : control
                    }
                }
            }
        }
    }

    private func isManual(_ control: CameraControl) -> Bool {
        switch control {
        case .ev: return abs(camera.ev) > 0.01
        case .iso: return camera.manualISO != nil
        case .shutter: return camera.manualShutter != nil
        case .kelvin: return camera.manualKelvin != nil
        case .focus: return camera.manualFocus != nil
        }
    }

    private func chipValue(_ control: CameraControl) -> String {
        switch control {
        case .ev:
            if camera.manualISO != nil {
                // Exposition manuelle : écart avec ce que mesure l'appareil.
                return ExposureText.ev(camera.exposureOffset)
            }
            return ExposureText.ev(camera.ev)
        case .iso: return "\(Int((camera.manualISO ?? camera.liveISO).rounded()))"
        case .shutter: return ExposureText.shutter(camera.manualShutter ?? camera.liveShutter)
        case .kelvin: return "\(Int(((camera.manualKelvin ?? camera.liveKelvin) / 50).rounded() * 50))"
        case .focus:
            if let focus = camera.manualFocus { return String(format: "%.2f", focus).replacingOccurrences(of: ".", with: ",") }
            return camera.locked ? "VERR." : "AUTO"
        }
    }

    private static let focusSteps: [Double] = stride(from: 0.0, through: 1.0001, by: 0.02).map { ($0 * 50).rounded() / 50 }

    @ViewBuilder private func dial(for control: CameraControl) -> some View {
        switch control {
        case .ev:
            let values = ExposureSteps.evValues.filter { $0 >= camera.evRange.lowerBound - 1e-6 && $0 <= camera.evRange.upperBound + 1e-6 }
            ValueDial(labels: values.map(ExposureText.ev),
                      index: ExposureSteps.nearestIndex(values, to: camera.ev, logarithmic: false),
                      isAuto: abs(camera.ev) < 0.01,
                      disabledReason: camera.manualISO != nil ? "Exposition manuelle (ISO et vitesse)" : nil,
                      onChange: { camera.setEV(values[$0]) },
                      onAuto: { camera.setEV(0) })
        case .iso:
            let values = ExposureSteps.within(ExposureSteps.isoValues, min: camera.isoRange.lowerBound, max: camera.isoRange.upperBound)
            ValueDial(labels: values.map { "ISO \(Int($0))" },
                      index: ExposureSteps.nearestIndex(values, to: camera.manualISO ?? max(camera.liveISO, 1)),
                      isAuto: camera.manualISO == nil,
                      onChange: { camera.setManualExposure(iso: values[$0]) },
                      onAuto: { camera.setAutoExposure() })
        case .shutter:
            let values = ExposureSteps.within(ExposureSteps.shutterValues, min: camera.shutterRange.lowerBound, max: camera.shutterRange.upperBound)
            ValueDial(labels: values.map(ExposureText.shutter),
                      index: ExposureSteps.nearestIndex(values, to: camera.manualShutter ?? max(camera.liveShutter, 1e-4)),
                      isAuto: camera.manualShutter == nil,
                      onChange: { camera.setManualExposure(shutter: values[$0]) },
                      onAuto: { camera.setAutoExposure() })
        case .kelvin:
            let values = ExposureSteps.kelvinValues
            ValueDial(labels: values.map(ExposureText.kelvin),
                      index: ExposureSteps.nearestIndex(values, to: camera.manualKelvin ?? max(camera.liveKelvin, 2000)),
                      isAuto: camera.manualKelvin == nil,
                      onChange: { camera.setKelvin(values[$0]) },
                      onAuto: { camera.setKelvin(nil) })
        case .focus:
            let values = Self.focusSteps
            ValueDial(labels: values.map { $0 == 0 ? "Près" : ($0 == 1 ? "Loin" : String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",")) },
                      index: ExposureSteps.nearestIndex(values, to: camera.manualFocus ?? camera.liveFocus, logarithmic: false),
                      isAuto: camera.manualFocus == nil,
                      disabledReason: camera.manualFocusSupported ? nil : "Mise au point manuelle indisponible",
                      onChange: { camera.setFocus(values[$0]) },
                      onAuto: { camera.setFocus(nil) })
        }
    }

    // MARK: Barre du bas

    private var bottomBar: some View {
        HStack {
            thumbnail
                .rotationEffect(rotation)
            Spacer()
            ShutterButton(busy: developer.pending > 0, action: model.shoot)
            Spacer()
            lookToggle
                .rotationEffect(rotation)
        }
        .frame(height: 96)
    }

    private var thumbnail: some View {
        Button {
            gallerySelection = gallery.items.first?.id
            showGallery = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                if let image = gallery.lastThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .id(gallery.items.first?.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if developer.pending > 0 {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.45))
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 54, height: 54)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: gallery.items.first?.id)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Dernières photos")
    }

    private var lookToggle: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) { model.showLook.toggle() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: model.showLook ? "film" : "film.fill")
                    .font(.system(size: 18, weight: .medium))
                    .symbolEffect(.bounce, value: model.showLook)
                Text(model.showLook ? "FILM" : "BRUT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(model.showLook ? Palette.amber : .white)
            .frame(width: 54, height: 54)
            .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(model.showLook ? "Aperçu avec le rendu pellicule" : "Aperçu brut")
    }

    @ViewBuilder private var toast: some View {
        if let message = model.toast {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Réglages du rendu (avant chaque photo).
struct RenderSettingsView: View {
    @ObservedObject var model: CineModel
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Grain", selection: $model.choices.grain) {
                        ForEach(GrainLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Grain")
                } footer: {
                    Text("Grain fin et régulier, surtout visible dans les tons moyens, comme sur une pellicule.")
                }

                Section {
                    Picker("Halation", selection: $model.choices.halation) {
                        ForEach(HalationLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Halation")
                } footer: {
                    Text("Halo rouge orangé autour des lumières fortes (lampes, reflets, ciel), et léger voile lumineux.")
                }

                Section {
                    Toggle("Vignettage léger", isOn: $model.choices.vignette)
                    Toggle("Grille des tiers", isOn: $model.showGrid)
                }
                .tint(Palette.amber)

                Section {
                    Picker("Format", selection: $model.format) {
                        ForEach(AspectFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Format")
                } footer: {
                    Text("Le capteur fait du 4:3 ; les autres formats sont recadrés au centre. Tiens l'iPhone à l'horizontale pour un cadre de cinéma (2,39:1 = format Scope).")
                }

                Section {
                    Toggle("Garder aussi le RAW (DNG)", isOn: $model.keepRaw)
                        .tint(Palette.amber)
                } footer: {
                    Text("Le fichier du capteur est joint à la photo dans Photos, pour la retoucher ailleurs. Environ 25 Mo de plus par photo.")
                }

                Section("Développement") {
                    LabeledContent("Capture", value: camera.rawAvailable ? "RAW du capteur" : "HEIF (pas de RAW sur cet objectif)")
                    Text("Ciné récupère les données brutes du capteur et les développe lui-même : pas de Smart HDR, pas de Deep Fusion, pas de renforcement de netteté ni de tone mapping local. Puis vient la courbe de pellicule : noirs laiteux, hautes lumières qui s'arrondissent, peaux chaudes, verts olive. L'image est enregistrée en HEIF 10 bits (Display P3).")
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
            .navigationTitle("Rendu")
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

struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Palette.amber)
            Text("Ciné a besoin de l'appareil photo")
                .font(.title3.weight(.semibold))
            Text("Autorise l'accès dans Réglages › Ciné › Appareil photo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Ouvrir les Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(GlassButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}
