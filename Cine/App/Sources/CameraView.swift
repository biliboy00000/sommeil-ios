import SwiftUI
import FilmCore

/// L'écran de prise de vue : viseur avec le rendu pellicule en direct, outils de visée, réglages manuels,
/// photo ou vidéo.
struct CameraView: View {
    @ObservedObject var model: CineModel
    @ObservedObject var camera: CameraController
    @ObservedObject var gallery: Gallery
    @ObservedObject var developer: Developer
    @ObservedObject var motion: OrientationTracker

    @State var activeControl: CameraControl?
    @State var showStocks = false
    @State var focusPoint: CGPoint?
    @State var focusToken = 0
    @State var lastTouch: CGPoint = .zero
    @State var showSettings = false
    @State var showGallery = false
    @State var gallerySelection: String?

    private var rotation: Angle { .degrees(motion.orientation.iconRotation) }
    private var isVideo: Bool { camera.mode == .video }

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
        .sheet(isPresented: $showSettings) { SettingsView(model: model, camera: camera) }
        .fullScreenCover(isPresented: $showGallery) { GalleryViewer(gallery: gallery, selection: $gallerySelection) }
        .modifier(HardwareShutter(action: model.shutterPressed))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: motion.orientation)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: camera.mode)
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .frame(height: 50)
            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controlStrip
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ModeSwitcher(mode: camera.mode, disabled: camera.isRecording || model.countdown != nil) { mode in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    activeControl = nil
                    showStocks = false
                }
                model.setMode(mode)
            }
            .padding(.top, 4)
            bottomBar
                .padding(.horizontal, 30)
                .padding(.bottom, 8)
        }
        .overlay(alignment: .top) { toast }
    }

    // MARK: Barre du haut

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .rotationEffect(rotation)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Réglages")
            .disabled(camera.isRecording)

            Button {
                let all = SelfTimer.allCases
                let next = all[((all.firstIndex(of: model.selfTimer) ?? 0) + 1) % all.count]
                model.selfTimer = next
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 14, weight: .semibold))
                    if model.selfTimer != .off {
                        Text("\(model.selfTimer.rawValue)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(model.selfTimer == .off ? .white : Palette.amber)
                .frame(minWidth: 36, minHeight: 36)
                .padding(.horizontal, model.selfTimer == .off ? 0 : 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .rotationEffect(rotation)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Retardateur : \(model.selfTimer.label)")
            .disabled(camera.isRecording)

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
                    .foregroundStyle(model.format == (isVideo ? AspectFormat.wide : AspectFormat.standard) ? Color.white : Palette.amber)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .rotationEffect(rotation)
            }
            .disabled(camera.isRecording)
            .accessibilityLabel("Format de l'image")
        }
        .foregroundStyle(.white)
    }

    private var readout: some View {
        HStack(spacing: 9) {
            if !isVideo {
                Text(camera.rawAvailable ? "RAW" : "HEIF")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(camera.rawAvailable ? .black : .white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(camera.rawAvailable ? Palette.amber : Color.white.opacity(0.2)))
            }
            Text(ExposureText.iso(camera.manualISO ?? camera.liveISO))
                .foregroundStyle(camera.manualISO == nil ? .white : Palette.amber)
            Text(shutterReadout)
                .foregroundStyle(isVideo ? (camera.shutterAngle == nil ? .white : Palette.amber)
                                         : (camera.manualShutter == nil ? .white : Palette.amber))
            Text(ExposureText.kelvin(camera.manualKelvin ?? camera.liveKelvin))
                .foregroundStyle(camera.manualKelvin == nil ? .white : Palette.amber)
        }
        .font(Palette.readout)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .monospacedDigit()
    }

    private var currentFPS: Double { Double(camera.videoConfig.frameRate.capture) }

    private var shutterReadout: String {
        if isVideo {
            let angle = camera.shutterAngle ?? ShutterAngle.angle(duration: camera.liveShutter, fps: currentFPS)
            return ShutterAngle.text((angle * 10).rounded() / 10)
        }
        return ExposureText.shutter(camera.manualShutter ?? camera.liveShutter)
    }

    // MARK: Viseur

    private var viewfinder: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                PreviewView(processor: camera.processor)
                FormatMatte(format: model.format, showGrid: model.showGrid)
                if model.tools.level {
                    LevelOverlay(level: motion.level, baseRotation: motion.orientation.iconRotation)
                }
                if let focusPoint {
                    FocusReticle(locked: camera.locked, rotation: rotation)
                        .position(focusPoint)
                        .id(focusToken)
                }
                if let countdown = model.countdown {
                    CountdownView(value: countdown, rotation: rotation)
                }
                Color.black
                    .opacity(model.flash ? 0.9 : 0)
                    .allowsHitTesting(false)
                if camera.isRecording {
                    Rectangle()
                        .stroke(Palette.record, lineWidth: 3)
                        .allowsHitTesting(false)
                }
                VStack {
                    viewfinderTop
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                    Spacer()
                    viewfinderBottom
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { lastTouch = $0.startLocation })
            .onTapGesture { location in tapped(at: location, in: size, lock: false) }
            .onLongPressGesture(minimumDuration: 0.5) { tapped(at: lastTouch, in: size, lock: true) }
        }
        .aspectRatio(isVideo ? 9.0 / 16.0 : 3.0 / 4.0, contentMode: .fit)
        .clipped()
    }

    private var viewfinderTop: some View {
        HStack(alignment: .top) {
            if model.tools.histogram {
                HistogramOverlay(state: model.histogram)
                    .transition(.opacity)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if isVideo {
                    if camera.isRecording {
                        RecordingBadge(start: camera.recordingStart, fps: camera.videoConfig.frameRate.playback,
                                       slowMotion: camera.videoConfig.frameRate.isSlowMotion)
                    } else {
                        videoMenu
                    }
                    if camera.audioActive, !camera.videoConfig.frameRate.isSlowMotion {
                        AudioMeter(level: camera.audioLevel)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.45)))
                    }
                    if camera.underexposed {
                        badge("SOUS-EXPOSÉ · ISO MAX", color: Palette.record)
                    }
                }
                if !model.showLook { badge("IMAGE BRUTE", color: .black.opacity(0.5)) }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .allowsHitTesting(false)
    }

    /// Définition et cadence de la vidéo, et temps d'enregistrement restant.
    private var videoMenu: some View {
        Menu {
            Picker("Définition", selection: $model.video.resolution) {
                ForEach(VideoResolution.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Cadence", selection: $model.video.frameRate) {
                ForEach(FrameRate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text(camera.videoDescription.isEmpty ? "—" : camera.videoDescription)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Text(remainingText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.5)))
            .rotationEffect(rotation)
        }
    }

    private var remainingText: String {
        let resolution = camera.videoConfig.resolution
        let crop = model.format.evenCrop(width: resolution.width, height: resolution.height)
        let bits = RecordingBudget.bitsPerSecond(width: crop.width, height: crop.height, frameRate: currentFPS)
        let minutes = RecordingBudget.minutes(freeBytes: model.freeBytes, bitsPerSecond: bits)
        if minutes >= 120 { return "≈ \(Int(minutes / 60)) h libres" }
        return "≈ \(Int(minutes)) min libres"
    }

    @ViewBuilder private var viewfinderBottom: some View {
        if let control = activeControl {
            dial(for: control)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if showStocks {
            StockStrip(selected: model.render.stock, showLook: model.showLook,
                       select: { stock in
                           UISelectionFeedbackGenerator().selectionChanged()
                           model.render.stock = stock
                       },
                       setShowLook: { model.showLook = $0 })
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
        .opacity(camera.isRecording ? 0.4 : 1)
        .disabled(camera.isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: camera.lensID)
    }

    private func tapped(at point: CGPoint, in size: CGSize, lock: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        if activeControl != nil || showStocks {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                activeControl = nil
                showStocks = false
            }
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
                ControlChip(control: control, mode: camera.mode, value: chipValue(control), isManual: isManual(control),
                            isSelected: activeControl == control) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showStocks = false
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
        case .shutter: return isVideo ? camera.shutterAngle != nil : camera.manualShutter != nil
        case .kelvin: return camera.manualKelvin != nil
        case .focus: return camera.manualFocus != nil
        }
    }

    /// Exposition entièrement manuelle (l'écart mesuré remplace la correction).
    private var fullyManual: Bool {
        isVideo ? (camera.manualISO != nil && camera.shutterAngle != nil) : camera.manualISO != nil
    }

    private func chipValue(_ control: CameraControl) -> String {
        switch control {
        case .ev:
            return fullyManual ? ExposureText.ev(camera.exposureOffset) : ExposureText.ev(camera.ev)
        case .iso:
            return "\(Int((camera.manualISO ?? camera.liveISO).rounded()))"
        case .shutter:
            if isVideo { return camera.shutterAngle.map(ShutterAngle.text) ?? "AUTO" }
            return ExposureText.shutter(camera.manualShutter ?? camera.liveShutter)
        case .kelvin:
            return "\(Int(((camera.manualKelvin ?? camera.liveKelvin) / 50).rounded() * 50))"
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
                      disabledReason: fullyManual ? "Exposition manuelle (ISO et \(isVideo ? "obturateur" : "vitesse"))" : nil,
                      onChange: { camera.setEV(values[$0]) },
                      onAuto: { camera.setEV(0) })
        case .iso:
            let values = ExposureSteps.within(ExposureSteps.isoValues, min: camera.isoRange.lowerBound, max: camera.isoRange.upperBound)
            ValueDial(labels: values.map { "ISO \(Int($0))" },
                      index: ExposureSteps.nearestIndex(values, to: camera.manualISO ?? max(camera.liveISO, 1)),
                      isAuto: camera.manualISO == nil,
                      onChange: { index in
                          if isVideo { camera.setVideoISO(values[index]) } else { camera.setManualExposure(iso: values[index]) }
                      },
                      onAuto: { if isVideo { camera.setVideoISO(nil) } else { camera.setAutoExposure() } })
        case .shutter:
            if isVideo {
                let values = camera.angleValues
                ValueDial(labels: values.map { "\(ShutterAngle.text($0)) · \(ExposureText.shutter(ShutterAngle.duration(angle: $0, fps: currentFPS)))" },
                          index: ExposureSteps.nearestIndex(values, to: camera.shutterAngle ?? 180),
                          isAuto: camera.shutterAngle == nil,
                          onChange: { camera.setShutterAngle(values[$0]) },
                          onAuto: { camera.setShutterAngle(nil) })
            } else {
                let values = ExposureSteps.within(ExposureSteps.shutterValues, min: camera.shutterRange.lowerBound, max: camera.shutterRange.upperBound)
                ValueDial(labels: values.map(ExposureText.shutter),
                          index: ExposureSteps.nearestIndex(values, to: camera.manualShutter ?? max(camera.liveShutter, 1e-4)),
                          isAuto: camera.manualShutter == nil,
                          onChange: { camera.setManualExposure(shutter: values[$0]) },
                          onAuto: { camera.setAutoExposure() })
            }
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
            ShutterButton(mode: camera.mode, recording: camera.isRecording, busy: developer.pending > 0,
                          action: model.shutterPressed)
            Spacer()
            stockButton
                .rotationEffect(rotation)
        }
        .frame(height: 92)
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
                if gallery.items.first?.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
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
        .disabled(camera.isRecording)
        .accessibilityLabel("Dernières photos et vidéos")
    }

    /// La pellicule chargée (comme l'étiquette d'une boîte de film) : ouvre le choix des pellicules.
    private var stockButton: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                activeControl = nil
                showStocks.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "film")
                    .font(.system(size: 15, weight: .medium))
                Text(model.render.stock.code)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(showStocks ? .black : Palette.amber)
            .frame(width: 54, height: 54)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(showStocks ? Palette.amber : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.amber.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Pellicule : \(model.render.stock.label)")
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
