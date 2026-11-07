import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// L'écran complet de la Télécommande avec son modèle (ouvert par l'app Gadget).
struct TeleRoot: View {
    @StateObject private var model = TeleModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.appairage == nil {
                TeleAppairageView()
            } else {
                TelePrincipal()
            }
        }
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .onAppear { if model.appairage != nil { model.connecter() } }
        .onDisappear { model.deconnecter() }
        .onChange(of: scenePhase) { _, phase in
            // en arrière-plan, on garde la connexion seulement si le son passe par le téléphone
            if phase == .background, !model.sonSurTelephone { model.deconnecter() }
            if phase == .active, model.appairage != nil, model.connexion != .connecte { model.connecter() }
        }
        .alert("Télécommande", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
    }
}

// MARK: - Appairage

struct TeleAppairageView: View {
    @EnvironmentObject var model: TeleModel
    @State private var scanner = false
    @State private var codeInconnu = false
    @State private var hote = ""
    @State private var port = "8765"
    @State private var cle = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.tint)
                        Text("Relie ton PC").font(.title2.bold())
                        Text("Lance le programme « Télécommande » sur ton PC : il affiche un QR code. Le téléphone doit être sur le même Wi-Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button {
                        Task { await ouvrirScanner() }
                    } label: {
                        Label("Scanner le QR code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                }
                Section("Ou à la main") {
                    TextField("Adresse (ex. 192.168.1.20)", text: $hote)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Clé d'accès", text: $cle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Relier") {
                        model.appairage = TeleAppairage(hote: hote.trimmingCharacters(in: .whitespaces),
                                                        port: Int(port) ?? 8765,
                                                        cle: cle.trimmingCharacters(in: .whitespaces), nom: hote)
                        model.connecter()
                    }
                    .disabled(hote.isEmpty || cle.isEmpty)
                }
            }
            .navigationTitle("Télécommande")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { GadgetExitButton() }
            }
            .sheet(isPresented: $scanner) {
                ZStack(alignment: .top) {
                    TeleScanner { code in
                        guard let a = TeleAppairage(lien: code) else {
                            codeInconnu = true
                            return
                        }
                        scanner = false
                        model.appairage = a
                        model.connecter()
                    }
                    .ignoresSafeArea()

                    HStack {
                        Text(codeInconnu ? "Ce QR code ne vient pas du programme Télécommande."
                                         : "Vise le QR code affiché dans la fenêtre du PC.")
                            .font(.footnote.weight(.medium))
                        Spacer()
                        Button("Fermer") { scanner = false }
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                }
            }
        }
    }

    /// iOS ne déclare le scanner « disponible » qu'une fois l'appareil photo autorisé :
    /// on demande donc l'autorisation d'abord, puis on ouvre le scanner.
    private func ouvrirScanner() async {
        guard DataScannerViewController.isSupported else {
            model.message = "Cet iPhone ne sait pas scanner de QR code ici : saisis l'adresse et la clé à la main."
            return
        }
        let autorise = await AVCaptureDevice.requestAccess(for: .video)
        guard autorise else {
            model.message = "L'appareil photo est refusé : autorise-le dans Réglages › Gadget, ou saisis l'adresse et la clé à la main."
            return
        }
        codeInconnu = false
        scanner = true
    }
}

struct TeleScanner: UIViewControllerRepresentable {
    let trouve: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(trouve: trouve) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let trouve: (String) -> Void
        init(trouve: @escaping (String) -> Void) { self.trouve = trouve }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let texte = code.payloadStringValue {
                    trouve(texte)
                }
            }
        }
    }
}

// MARK: - Écran principal

enum TeleOnglet: String, CaseIterable, Identifiable {
    case pave = "Pavé", lecture = "Lecture", systeme = "Système"
    var id: String { rawValue }
}

struct TelePrincipal: View {
    @EnvironmentObject var model: TeleModel
    @State private var onglet: TeleOnglet = .pave

    var body: some View {
        VStack(spacing: 12) {
            entete
            TeleSortieSon()
            Picker("Onglet", selection: $onglet) {
                ForEach(TeleOnglet.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch onglet {
            case .pave: TelePave()
            case .lecture: TeleLecture()
            case .systeme: TeleSysteme()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea())
    }

    private var entete: some View {
        HStack(spacing: 10) {
            GadgetExitButton()
            Circle()
                .fill(couleurEtat)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.nomPC.isEmpty ? "PC" : model.nomPC)
                    .font(.headline)
                    .lineLimit(1)
                Text(texteEtat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.connexion != .connecte {
                Button("Réessayer") { model.connecter() }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private var couleurEtat: Color {
        switch model.connexion {
        case .connecte: return .green
        case .connexion: return .orange
        default: return .red
        }
    }

    private var texteEtat: String {
        switch model.connexion {
        case .connecte: return model.sonSurTelephone ? "Connecté · son sur le téléphone" : "Connecté"
        case .connexion: return "Connexion…"
        case .deconnecte: return "Déconnecté"
        case .erreur(let e): return e
        }
    }
}

/// Le bouton demandé : où sort le son de l'ordinateur.
struct TeleSortieSon: View {
    @EnvironmentObject var model: TeleModel

    var body: some View {
        HStack(spacing: 6) {
            choix("PC", icone: "desktopcomputer", actif: !model.sonSurTelephone) {
                model.basculerSon(versTelephone: false)
            }
            choix("Téléphone", icone: "iphone.radiowaves.left.and.right", actif: model.sonSurTelephone) {
                model.basculerSon(versTelephone: true)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(alignment: .trailing) {
            if model.basculeEnCours { ProgressView().padding(.trailing, 14) }
        }
        .disabled(model.connexion != .connecte || model.basculeEnCours)
        .opacity(model.connexion == .connecte ? 1 : 0.5)
    }

    private func choix(_ titre: String, icone: String, actif: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icone)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Son").font(.caption2).opacity(0.7)
                    Text(titre).font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(actif ? Color.black : Color.white)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(actif ? Color(red: 1.0, green: 0.78, blue: 0.35) : Color.clear))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: actif)
    }
}

// MARK: - Pavé tactile et clavier

struct TelePave: View {
    @EnvironmentObject var model: TeleModel
    @State private var texte = ""
    @State private var ignorer = false
    @FocusState private var clavier: Bool

    var body: some View {
        VStack(spacing: 10) {
            TeleTouchPadView(vitesse: model.vitesse,
                             bouger: { model.bouger($0, $1) },
                             defiler: { model.defiler(0, $0) },
                             clic: { model.clic($0) },
                             glisser: { model.bouton("gauche", appui: $0) })
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                )
                .overlay(alignment: .bottom) {
                    Text("1 doigt : souris · toucher : clic · 2 doigts : défiler / clic droit · appui long : glisser")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .allowsHitTesting(false)
                }

            HStack(spacing: 8) {
                gros("Clic", "cursorarrow.click") { model.clic("gauche") }
                gros("Clic droit", "contextualmenu.and.cursorarrow") { model.clic("droit") }
            }

            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField("Écrire sur l'ordinateur", text: $texte)
                    .focused($clavier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.return)
                    .onChange(of: texte) { ancien, nouveau in envoyerDiff(ancien, nouveau) }
                    .onSubmit {
                        model.touche("entree")
                        ignorer = true
                        texte = ""
                        clavier = true
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    touche("delete.left") { model.touche("retour") }
                    touche("return") { model.touche("entree") }
                    touche(texte: "Échap") { model.touche("echap") }
                    touche(texte: "Tab") { model.touche("tab") }
                    touche("arrow.left") { model.touche("gauche") }
                    touche("arrow.up") { model.touche("haut") }
                    touche("arrow.down") { model.touche("bas") }
                    touche("arrow.right") { model.touche("droite") }
                    touche(texte: "Alt+Tab") { model.combinaison(["alt", "tab"]) }
                    touche(texte: "Copier") { model.combinaison(["ctrl", "c"]) }
                    touche(texte: "Coller") { model.combinaison(["ctrl", "v"]) }
                    touche(texte: "Tout") { model.combinaison(["ctrl", "a"]) }
                }
            }
        }
    }

    /// Envoie seulement ce qui a changé : lettres ajoutées, ou effacements.
    private func envoyerDiff(_ ancien: String, _ nouveau: String) {
        if ignorer { ignorer = false; return }
        let a = Array(ancien), n = Array(nouveau)
        var p = 0
        while p < a.count, p < n.count, a[p] == n[p] { p += 1 }
        let effaces = a.count - p
        if effaces > 0 { model.touche("retour", n: effaces) }
        if p < n.count { model.taper(String(n[p...])) }
    }

    private func gros(_ titre: String, _ icone: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(titre, systemImage: icone)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func touche(_ icone: String = "", texte: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if texte.isEmpty { Image(systemName: icone) } else { Text(texte) }
            }
            .font(.footnote.weight(.semibold))
            .frame(minWidth: 44, minHeight: 38)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Le pavé tactile : gestes UIKit, plus précis que ceux de SwiftUI pour piloter une souris.
struct TeleTouchPadView: UIViewRepresentable {
    var vitesse: Double
    var bouger: (Double, Double) -> Void
    var defiler: (Double) -> Void
    var clic: (String) -> Void
    var glisser: (Bool) -> Void

    func makeUIView(context: Context) -> TeleTouchPad {
        let v = TeleTouchPad()
        v.backgroundColor = UIColor(white: 1, alpha: 0.045)
        return v
    }

    func updateUIView(_ v: TeleTouchPad, context: Context) {
        v.vitesse = vitesse
        v.bouger = bouger
        v.defiler = defiler
        v.clic = clic
        v.glisser = glisser
    }
}

final class TeleTouchPad: UIView {
    var vitesse: Double = 1.4
    var bouger: (Double, Double) -> Void = { _, _ in }
    var defiler: (Double) -> Void = { _ in }
    var clic: (String) -> Void = { _ in }
    var glisser: (Bool) -> Void = { _ in }

    private var cumulDefilement: Double = 0
    private var dernierePosition: CGPoint = .zero
    private let impact = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true

        let appuiLong = UILongPressGestureRecognizer(target: self, action: #selector(long(_:)))
        appuiLong.minimumPressDuration = 0.35
        appuiLong.allowableMovement = 8
        addGestureRecognizer(appuiLong)

        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(pan1(_:)))
        pan1.maximumNumberOfTouches = 1
        addGestureRecognizer(pan1)

        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(pan2(_:)))
        pan2.minimumNumberOfTouches = 2
        pan2.maximumNumberOfTouches = 2
        addGestureRecognizer(pan2)

        let tap1 = UITapGestureRecognizer(target: self, action: #selector(tap1))
        addGestureRecognizer(tap1)

        let tap2 = UITapGestureRecognizer(target: self, action: #selector(tap2))
        tap2.numberOfTouchesRequired = 2
        addGestureRecognizer(tap2)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Accélération : les petits gestes restent précis, les grands traversent l'écran.
    private func envoyerMouvement(_ d: CGPoint) {
        let v = hypot(d.x, d.y)
        let f = vitesse * (1 + min(Double(v), 40) / 14)
        bouger(Double(d.x) * f, Double(d.y) * f)
    }

    @objc private func pan1(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if g.state == .changed { envoyerMouvement(t) }
    }

    @objc private func pan2(_ g: UIPanGestureRecognizer) {
        if g.state == .began { cumulDefilement = 0 }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        cumulDefilement += Double(t.y) / 22
        let pas = cumulDefilement.rounded(.towardZero)
        if pas != 0 {
            defiler(pas)
            cumulDefilement -= pas
        }
    }

    @objc private func long(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dernierePosition = p
            impact.impactOccurred(intensity: 0.8)
            glisser(true)
        case .changed:
            envoyerMouvement(CGPoint(x: p.x - dernierePosition.x, y: p.y - dernierePosition.y))
            dernierePosition = p
        case .ended, .cancelled, .failed:
            glisser(false)
        default:
            break
        }
    }

    @objc private func tap1() {
        impact.impactOccurred(intensity: 0.5)
        clic("gauche")
    }

    @objc private func tap2() {
        impact.impactOccurred(intensity: 0.7)
        clic("droit")
    }
}

// MARK: - Lecture

struct TeleLecture: View {
    @EnvironmentObject var model: TeleModel
    @State private var stats = ""
    private let minuteur = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    rond("backward.end.fill", 56) { model.touche("precedent") }
                    rond("playpause.fill", 84, plein: true) { model.touche("lecture") }
                    rond("forward.end.fill", 56) { model.touche("suivant") }
                }
                .padding(.top, 8)

                HStack(spacing: 8) {
                    bouton("gobackward.5", "−5 s") { model.touche("gauche") }
                    bouton("space", "Espace") { model.touche("espace") }
                    bouton("goforward.5", "+5 s") { model.touche("droite") }
                }
                HStack(spacing: 8) {
                    bouton("arrow.up.left.and.arrow.down.right", "Plein écran") { model.touche("f") }
                    bouton("captions.bubble", "Sous-titres") { model.touche("c") }
                    bouton("speaker.slash", "Muet") { model.touche("muet") }
                }

                carte {
                    if model.sonSurTelephone {
                        Label("Volume du téléphone", systemImage: "iphone").font(.subheadline.weight(.semibold))
                        Slider(value: $model.gainTelephone, in: 0...1)
                        Text("Les boutons de volume du téléphone marchent aussi.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Volume du PC", systemImage: "desktopcomputer").font(.subheadline.weight(.semibold))
                        Slider(value: Binding(get: { model.volumePC }, set: { model.reglerVolumePC($0) }), in: 0...1)
                    }
                }

                if model.sonSurTelephone {
                    carte {
                        Label("Délai du son", systemImage: "timer").font(.subheadline.weight(.semibold))
                        Slider(value: $model.latenceMs, in: 40...300, step: 10)
                        Text("\(Int(model.latenceMs)) ms · plus bas = mieux synchronisé avec l'image, plus haut = moins de coupures. \(stats)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(minuteur) { _ in
            guard model.sonSurTelephone else { return }
            stats = "Tampon \(Int(model.audio.enAttenteMs)) ms, \(model.audio.coupures) coupure(s)."
        }
    }

    private func rond(_ icone: String, _ taille: CGFloat, plein: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icone)
                .font(.system(size: taille * 0.36, weight: .semibold))
                .frame(width: taille, height: taille)
                .foregroundStyle(plein ? Color.black : Color.white)
                .background(Circle().fill(plein ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func bouton(_ icone: String, _ titre: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icone).font(.title3)
                Text(titre).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func carte<C: View>(@ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { contenu() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Système

struct TeleSysteme: View {
    @EnvironmentObject var model: TeleModel
    @State private var adresse = ""
    @State private var confirmer: String?

    private let actions: [(String, String, String)] = [
        ("verrouiller", "Verrouiller", "lock"),
        ("ecran", "Écran noir", "display"),
        ("veille", "Veille", "moon"),
        ("redemarrer", "Redémarrer", "arrow.clockwise"),
        ("eteindre", "Éteindre", "power"),
        ("annuler", "Annuler l'arrêt", "xmark.circle"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titre("Web")
                HStack(spacing: 8) {
                    site("YouTube", "https://www.youtube.com")
                    site("Netflix", "https://www.netflix.com")
                    site("Google", "https://www.google.com")
                }
                HStack {
                    TextField("Adresse ou recherche", text: $adresse)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .onSubmit(ouvrirAdresse)
                    Button(action: ouvrirAdresse) { Image(systemName: "arrow.up.right.circle.fill").font(.title2) }
                        .disabled(adresse.isEmpty)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))

                titre("Alimentation")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(actions, id: \.0) { a in
                        Button {
                            if ["veille", "redemarrer", "eteindre"].contains(a.0) { confirmer = a.0 } else { model.alimentation(a.0) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: a.2).font(.title3)
                                Text(a.1).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(a.0 == "eteindre" ? Color.red : Color.white)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                titre("Réglages")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vitesse de la souris").font(.subheadline)
                    Slider(value: $model.vitesse, in: 0.5...3)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))

                Button(role: .destructive) { model.oublier() } label: {
                    Label("Oublier ce PC", systemImage: "trash")
                }
                .padding(.top, 4)
            }
        }
        .confirmationDialog(texteConfirmation, isPresented: Binding(get: { confirmer != nil }, set: { if !$0 { confirmer = nil } }),
                            titleVisibility: .visible) {
            Button(boutonConfirmation, role: .destructive) {
                if let a = confirmer { model.alimentation(a) }
                confirmer = nil
            }
            Button("Annuler", role: .cancel) { confirmer = nil }
        }
    }

    private var texteConfirmation: String {
        switch confirmer {
        case "veille": return "Mettre le PC en veille ?"
        case "redemarrer": return "Redémarrer le PC ? (dans 5 s)"
        default: return "Éteindre le PC ? (dans 15 s, « Annuler l'arrêt » pour stopper)"
        }
    }

    private var boutonConfirmation: String {
        switch confirmer {
        case "veille": return "Mettre en veille"
        case "redemarrer": return "Redémarrer"
        default: return "Éteindre"
        }
    }

    private func ouvrirAdresse() {
        guard !adresse.isEmpty else { return }
        model.ouvrir(adresse)
        adresse = ""
    }

    private func titre(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func site(_ nom: String, _ url: String) -> some View {
        Button { model.ouvrir(url) } label: {
            Text(nom)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
