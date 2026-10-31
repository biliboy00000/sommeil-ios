import AVKit
import SwiftUI
import FilmCore

enum Palette {
    /// Ambre « tungstène » : réglages manuels, sélection, mise au point.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let dim = Color.white.opacity(0.55)
    static let readout = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let record = Color(red: 1.0, green: 0.23, blue: 0.19)
}

/// Réglage choisi sous le viseur.
enum CameraControl: String, CaseIterable, Identifiable {
    case ev, iso, shutter, kelvin, focus

    var id: String { rawValue }

    func title(_ mode: CaptureMode) -> String {
        switch self {
        case .ev: return "EXPO"
        case .iso: return "ISO"
        case .shutter: return mode == .video ? "OBTURAT." : "VITESSE"
        case .kelvin: return "BALANCE"
        case .focus: return "MAP"
        }
    }
}

/// Molette horizontale à crans (comme le zoom de l'appareil photo d'iOS) : on fait glisser la règle.
struct ValueDial: View {
    let labels: [String]
    let index: Int
    let isAuto: Bool
    var disabledReason: String?
    let onChange: (Int) -> Void
    let onAuto: () -> Void

    @State var position: CGFloat = 0
    @State var dragStart: CGFloat?
    @State var lastEmitted = 0
    let spacing: CGFloat = 12
    let haptics = UISelectionFeedbackGenerator()

    private var currentLabel: String {
        let i = min(max(Int(position.rounded()), 0), max(labels.count - 1, 0))
        return labels.isEmpty ? "—" : labels[i]
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(disabledReason ?? currentLabel)
                .font(.system(size: disabledReason == nil ? 15 : 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(disabledReason != nil ? Palette.dim : (isAuto ? .white : Palette.amber))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: currentLabel)
            HStack(spacing: 10) {
                Button(action: {
                    onAuto()
                    UISelectionFeedbackGenerator().selectionChanged()
                }) {
                    Text("AUTO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(isAuto ? .black : .white)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Capsule().fill(isAuto ? Palette.amber : Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                ruler
                    .opacity(disabledReason == nil ? 1 : 0.3)
                    .allowsHitTesting(disabledReason == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.55)))
        .onAppear {
            position = CGFloat(index)
            lastEmitted = index
            haptics.prepare()
        }
        .onChange(of: index) { _, newValue in
            guard dragStart == nil else { return }
            lastEmitted = newValue
            withAnimation(.easeOut(duration: 0.25)) { position = CGFloat(newValue) }
        }
    }

    private var ruler: some View {
        GeometryReader { geometry in
            ZStack {
                DialTicks(position: position, count: labels.count, spacing: spacing, major: false)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                DialTicks(position: position, count: labels.count, spacing: spacing, major: true)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.2)
                Capsule()
                    .fill(Palette.amber)
                    .frame(width: 2.5, height: geometry.size.height)
            }
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
            .contentShape(Rectangle())
            .gesture(drag)
        }
        .frame(height: 30)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = position }
                let target = (dragStart ?? 0) - value.translation.width / spacing
                position = min(max(target, 0), CGFloat(max(labels.count - 1, 0)))
                emit(Int(position.rounded()))
            }
            .onEnded { value in
                // Petit élan : on suit la vitesse du geste, puis on se cale sur un cran.
                let start = dragStart ?? position
                dragStart = nil
                let predicted = start - value.predictedEndTranslation.width / spacing
                let fling = position + (predicted - position) * 0.35
                let snapped = min(max(fling.rounded(), 0), CGFloat(max(labels.count - 1, 0)))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { position = snapped }
                emit(Int(snapped))
            }
    }

    private func emit(_ i: Int) {
        guard i != lastEmitted, labels.indices.contains(i) else { return }
        lastEmitted = i
        haptics.selectionChanged()
        onChange(i)
    }
}

/// Graduations de la molette (animables : la règle glisse vers le cran choisi).
struct DialTicks: Shape {
    var position: CGFloat
    let count: Int
    let spacing: CGFloat
    let major: Bool

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX
        for i in 0..<max(count, 0) where (i % 3 == 0) == major {
            let x = mid + (CGFloat(i) - position) * spacing
            guard x >= rect.minX - 2, x <= rect.maxX + 2 else { continue }
            let height: CGFloat = major ? rect.height * 0.62 : rect.height * 0.34
            path.move(to: CGPoint(x: x, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: x, y: rect.midY + height / 2))
        }
        return path
    }
}

/// Un réglage sous le viseur : titre et valeur.
struct ControlChip: View {
    let control: CameraControl
    let mode: CaptureMode
    let value: String
    let isManual: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(control.title(mode))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(isSelected ? Palette.amber : Palette.dim)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isManual || isSelected ? Palette.amber : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Circle()
                    .fill(isManual ? Palette.amber : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Bouton de déclenchement : photo (blanc), ou enregistrement (rouge, carré pendant l'enregistrement).
struct ShutterButton: View {
    let mode: CaptureMode
    let recording: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                if mode == .photo {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 8 : 32, style: .continuous)
                        .fill(Palette.record)
                        .frame(width: recording ? 32 : 64, height: recording ? 32 : 64)
                }
                if busy, !recording {
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Palette.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 78, height: 78)
                        .modifier(Spinning())
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: recording)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: mode)
        }
        .buttonStyle(ShutterStyle())
        .accessibilityLabel(mode == .photo ? "Prendre une photo" : (recording ? "Arrêter l'enregistrement" : "Filmer"))
    }
}

struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Spinning: ViewModifier {
    @State var angle = 0.0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// Bandes noires du format choisi. Le grand côté du capteur suit toujours le grand côté de l'iPhone :
/// les formats plus larges que le capteur coupent le petit côté, les plus étroits coupent le grand.
struct FormatMatte: View {
    let format: AspectFormat
    let showGrid: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let crop = format.crop(width: Double(width), height: Double(height))
            let cropWidth = CGFloat(crop.width), cropHeight = CGFloat(crop.height)
            let side = max(0, (width - cropWidth) / 2)
            let band = max(0, (height - cropHeight) / 2)
            ZStack {
                HStack(spacing: 0) {
                    Color.black.opacity(0.66).frame(width: side)
                    Spacer(minLength: 0)
                    Color.black.opacity(0.66).frame(width: side)
                }
                VStack(spacing: 0) {
                    Color.black.opacity(0.66).frame(height: band)
                    Spacer(minLength: 0)
                    Color.black.opacity(0.66).frame(height: band)
                }
                .padding(.horizontal, side)
                if side > 0.5 || band > 0.5 {
                    Rectangle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                        .frame(width: cropWidth, height: cropHeight)
                }
                if showGrid {
                    ThirdsGrid()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                        .frame(width: cropWidth, height: cropHeight)
                }
            }
            .frame(width: width, height: height)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: format)
        }
        .allowsHitTesting(false)
    }
}

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// Carré de mise au point.
struct FocusReticle: View {
    let locked: Bool
    let rotation: Angle
    @State var appeared = false

    var body: some View {
        VStack(spacing: 6) {
            if locked {
                Text("AE/AF VERROUILLÉS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.amber))
                    .rotationEffect(rotation)
            }
            RoundedRectangle(cornerRadius: 3)
                .stroke(Palette.amber, lineWidth: 1.2)
                .frame(width: 72, height: 72)
                .scaleEffect(appeared ? 1 : 1.35)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { appeared = true }
        }
        .allowsHitTesting(false)
    }
}

/// Boutons de volume (et bouton Commande de l'appareil photo) : déclenchent comme le gros bouton. iOS 18 et plus.
struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}

/// Sélecteur PHOTO / VIDÉO (au-dessus du déclencheur).
struct ModeSwitcher: View {
    let mode: CaptureMode
    let disabled: Bool
    let select: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 22) {
            item(.photo, "PHOTO")
            item(.video, "VIDÉO")
        }
        .font(.system(size: 13, weight: .semibold))
        .tracking(1.2)
        .opacity(disabled ? 0.35 : 1)
        .allowsHitTesting(!disabled)
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.width < -20 { select(.video) }
            if value.translation.width > 20 { select(.photo) }
        })
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: mode)
    }

    private func item(_ target: CaptureMode, _ title: String) -> some View {
        Button {
            select(target)
        } label: {
            Text(title)
                .foregroundStyle(mode == target ? Palette.amber : Palette.dim)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pastille d'enregistrement : point rouge clignotant et code temporel.
struct RecordingBadge: View {
    let start: Date?
    let fps: Int
    let slowMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / Double(max(fps, 1)))) { context in
            let elapsed = start.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.record)
                    .frame(width: 8, height: 8)
                    .opacity(Int(elapsed * 2) % 2 == 0 ? 1 : 0.25)
                Text(Timecode.text(seconds: elapsed, fps: fps))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                if slowMotion {
                    Text("RALENTI")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.record.opacity(0.85)))
        }
    }
}

/// Niveau sonore du micro (dB, −160 à 0).
struct AudioMeter: View {
    let level: Double

    var body: some View {
        let fraction = min(max((level + 50) / 50, 0), 1)
        HStack(spacing: 4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .bold))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(level > -3 ? Palette.record : (level > -12 ? Palette.amber : Color.green))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 44, height: 4)
        }
        .foregroundStyle(.white.opacity(0.85))
        .animation(.linear(duration: 0.15), value: fraction)
    }
}

/// Histogramme de la luminance (64 cases).
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                let y = size.height * (1 - CGFloat(min(max(value, 0), 1)))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.55)))
            // Zone des blancs.
            let clip = CGRect(x: size.width * 0.95, y: 0, width: size.width * 0.05, height: size.height)
            context.fill(Path(clip), with: .color(Palette.record.opacity(0.25)))
        }
        .frame(width: 96, height: 42)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45)))
        .allowsHitTesting(false)
    }
}

/// Niveau : un trait qui reste parallèle à l'horizon, ambre quand l'iPhone est droit.
struct LevelIndicator: View {
    let roll: Double
    let baseRotation: Double

    var body: some View {
        let level = abs(roll) < 1
        ZStack {
            Capsule()
                .fill(level ? Palette.amber : Color.white.opacity(0.8))
                .frame(width: 120, height: level ? 2 : 1.5)
                .rotationEffect(.degrees(baseRotation - roll))
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 34, height: 1.5)
                .rotationEffect(.degrees(baseRotation))
                .offset(x: 0)
                .opacity(level ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: roll)
        .allowsHitTesting(false)
    }
}

/// Bandeau des pellicules (au bas du viseur).
struct StockStrip: View {
    let selected: FilmStock
    let showLook: Bool
    let select: (FilmStock) -> Void
    let setShowLook: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(selected.summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilmStock.allCases, id: \.self) { stock in
                        Button {
                            select(stock)
                        } label: {
                            VStack(spacing: 3) {
                                Text(stock.code)
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                Text(stock.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(stock == selected ? .black : .white)
                            .frame(width: 78, height: 46)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(stock == selected ? Palette.amber : Color.white.opacity(0.14)))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 12)
            }
            // Maintenir pour voir l'image sans le rendu.
            Text(showLook ? "Maintenir ici pour comparer avec l'image brute" : "IMAGE BRUTE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(showLook ? Palette.dim : Palette.amber)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                    setShowLook(!pressing)
                })
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.6)))
    }
}

/// Compte à rebours du retardateur.
struct CountdownView: View {
    let value: Int
    let rotation: Angle

    var body: some View {
        Text("\(value)")
            .font(.system(size: 96, weight: .thin, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 8)
            .rotationEffect(rotation)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: value)
            .allowsHitTesting(false)
    }
}

/// Le niveau, redessiné seul quand l'iPhone bouge.
struct LevelOverlay: View {
    @ObservedObject var level: LevelState
    let baseRotation: Double

    var body: some View {
        LevelIndicator(roll: level.roll, baseRotation: baseRotation)
    }
}

/// L'histogramme, redessiné seul à chaque mesure.
struct HistogramOverlay: View {
    @ObservedObject var state: HistogramState

    var body: some View {
        if !state.bins.isEmpty {
            HistogramView(bins: state.bins)
        }
    }
}
