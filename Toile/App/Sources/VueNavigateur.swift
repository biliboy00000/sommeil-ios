import SwiftUI
import UIKit
import WebKit

enum Feuille: String, Identifiable {
    case menu, favoris, telechargements
    var id: String { rawValue }
}

/// L'écran du navigateur : la page de l'onglet actif et la barre du bas.
struct VueNavigateur: View {
    @ObservedObject private var navigateur = Navigateur.shared
    @ObservedObject private var telechargements = Telechargements.shared
    @Environment(\.scenePhase) private var phase
    @State private var edition = false
    @State private var clavier = false
    @State private var feuille: Feuille?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let onglet = navigateur.actif {
                    VuePage(onglet: onglet)
                        .id(onglet.id)
                    // Clavier ouvert pour la page : la barre s'efface, la page garde toute la place.
                    if !clavier {
                        BarreDuBas(onglet: onglet, edition: $edition, feuille: $feuille)
                    }
                }
            }
            .ignoresSafeArea(.keyboard)

            if edition, let onglet = navigateur.actif {
                VueSaisie(onglet: onglet, edition: $edition)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { bandeauTelechargement }
        .animation(.easeOut(duration: 0.15), value: edition)
        .sheet(item: $feuille) { f in
            switch f {
            case .menu: VueMenu()
            case .favoris: VueMenu(ecran: .favoris)
            case .telechargements: VueMenu(ecran: .telechargements)
            }
        }
        .fullScreenCover(isPresented: $navigateur.afficherOnglets) {
            VueOnglets()
        }
        .task {
            await Bloqueur.shared.demarrer()
        }
        .onAppear {
            if navigateur.editionDemandee {
                navigateur.editionDemandee = false
                edition = true
            }
        }
        .onChange(of: navigateur.editionDemandee) { _, demande in
            guard demande else { return }
            navigateur.editionDemandee = false
            edition = true
        }
        .onChange(of: phase) { _, nouvelle in
            if nouvelle == .background {
                navigateur.sauvegarder()
                Historique.shared.sauvegarder()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            clavier = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            clavier = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            navigateur.signalerFond(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            navigateur.signalerFond(false)
        }
    }

    @ViewBuilder
    private var bandeauTelechargement: some View {
        if let element = telechargements.annonce {
            Button {
                telechargements.annonce = nil
                feuille = .telechargements
            } label: {
                Label("Téléchargé : \(element.nom)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thickMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: element.id) {
                try? await Task.sleep(for: .seconds(4))
                if telechargements.annonce?.id == element.id {
                    withAnimation { telechargements.annonce = nil }
                }
            }
        }
    }
}

/// La page d'un onglet, avec ses cartes « page bloquée » et « page inaccessible ».
struct VuePage: View {
    @ObservedObject var onglet: Onglet

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if onglet.adresse == nil && !onglet.estCree {
                PageNouvelOnglet(onglet: onglet)
            } else {
                ConteneurWeb(onglet: onglet)
            }
            if let url = onglet.pageBloquee {
                CartePageBloquee(onglet: onglet, url: url)
            } else if let erreur = onglet.erreur {
                CarteErreur(onglet: onglet, message: erreur)
            }
        }
    }
}

/// Accueille la WKWebView de l'onglet (une même page passe d'un conteneur à l'autre).
struct ConteneurWeb: UIViewRepresentable {
    let onglet: Onglet

    func makeUIView(context: Context) -> UIView {
        let vue = UIView()
        vue.backgroundColor = .systemBackground
        return vue
    }

    func updateUIView(_ vue: UIView, context: Context) {
        let page = onglet.webView
        guard page.superview !== vue else { return }
        vue.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        vue.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: vue.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: vue.trailingAnchor),
            page.topAnchor.constraint(equalTo: vue.topAnchor),
            page.bottomAnchor.constraint(equalTo: vue.bottomAnchor),
        ])
    }
}

/// Barre du bas : adresse, puis précédent, suivant, partager, favoris, onglets, menu.
struct BarreDuBas: View {
    @ObservedObject var onglet: Onglet
    @ObservedObject private var navigateur = Navigateur.shared
    @Binding var edition: Bool
    @Binding var feuille: Feuille?

    var body: some View {
        VStack(spacing: 6) {
            champ
            HStack {
                bouton("chevron.backward", actif: onglet.peutReculer || onglet.pageBloquee != nil || onglet.erreur != nil) {
                    onglet.reculer()
                }
                Spacer()
                bouton("chevron.forward", actif: onglet.peutAvancer) { onglet.avancer() }
                Spacer()
                if let url = onglet.adresse {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").frame(width: 44, height: 40)
                    }
                } else {
                    bouton("square.and.arrow.up", actif: false) {}
                }
                Spacer()
                bouton("book", actif: true) { feuille = .favoris }
                Spacer()
                Button {
                    navigateur.montrerOnglets()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(lineWidth: 1.8)
                            .frame(width: 22, height: 22)
                        Text("\(navigateur.onglets.filter { $0.prive == onglet.prive }.count)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .frame(width: 44, height: 40)
                }
                .accessibilityLabel("Onglets")
                Spacer()
                bouton("ellipsis.circle", actif: true) { feuille = .menu }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 8)
        .background(fond.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            if onglet.charge {
                ProgressView(value: max(0.05, onglet.progression))
                    .progressViewStyle(.linear)
                    .tint(onglet.prive ? Color.purple : Color.accentColor)
                    .frame(height: 2)
                    .offset(y: -1)
            }
        }
        .environment(\.colorScheme, onglet.prive ? .dark : environnement)
    }

    @Environment(\.colorScheme) private var environnement

    private var fond: some View {
        Group {
            if onglet.prive {
                Color(red: 0.13, green: 0.10, blue: 0.20)
            } else {
                Color(.secondarySystemBackground)
            }
        }
    }

    private var champ: some View {
        HStack(spacing: 8) {
            Image(systemName: icone)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(texte)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(onglet.adresse == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity)
            if onglet.adresse != nil {
                Button {
                    onglet.charge ? onglet.arreter() : onglet.recharger()
                } label: {
                    Image(systemName: onglet.charge ? "xmark" : "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(Capsule().fill(onglet.prive ? Color.white.opacity(0.12) : Color(.tertiarySystemBackground)))
        .contentShape(Capsule())
        .onTapGesture { edition = true }
        .padding(.horizontal, 12)
    }

    private var texte: String {
        guard let url = onglet.adresse else {
            return onglet.prive ? "Onglet privé : rechercher ou saisir" : "Rechercher ou saisir une adresse"
        }
        if let recherche = MoteurRecherche.recherche(dans: url) { return recherche }
        if let hote = url.host { return Navigateur.domaine(hote) }
        return url.absoluteString
    }

    private var icone: String {
        if onglet.pageBloquee != nil { return "shield.lefthalf.filled" }
        guard let url = onglet.adresse else { return onglet.prive ? "hand.raised.fill" : "magnifyingglass" }
        if onglet.prive { return "hand.raised.fill" }
        return url.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    private func bouton(_ image: String, actif: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 40)
        }
        .disabled(!actif)
    }
}

/// Saisie d'une adresse ou d'une recherche, avec suggestions (favoris, historique).
struct VueSaisie: View {
    @ObservedObject var onglet: Onglet
    @Binding var edition: Bool
    @State private var texte = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lignes) { ligne in
                        Button {
                            ouvrir(ligne)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: ligne.icone)
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ligne.titre).lineLimit(1).foregroundStyle(.primary)
                                    if let detail = ligne.detail {
                                        Text(detail).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 54)
                    }
                }
                .padding(.top, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { edition = false }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Rechercher ou saisir une adresse", text: $texte)
                        .focused($focus)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { valider(texte) }
                    if !texte.isEmpty {
                        Button {
                            texte = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Capsule().fill(Color(.tertiarySystemBackground)))
                Button("Annuler") { edition = false }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
        }
        .background(.regularMaterial)
        .onAppear {
            if let url = onglet.adresse {
                texte = MoteurRecherche.recherche(dans: url) ?? url.absoluteString
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            focus = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            // Comme Safari : tout le texte sélectionné, pour taper directement une autre adresse.
            guard let champ = note.object as? UITextField else { return }
            Task { @MainActor in champ.selectAll(nil) }
        }
    }

    private struct Ligne: Identifiable {
        let id: String
        let icone: String
        let titre: String
        let detail: String?
        let url: URL?
        let saisie: String?
    }

    private var lignes: [Ligne] {
        let t = texte.nettoye
        guard !t.isEmpty, t != onglet.adresse?.absoluteString else { return [] }
        var resultat: [Ligne] = []
        let moteur = Reglages.shared.moteur
        if let cible = Navigateur.adresse(pour: t), MoteurRecherche.recherche(dans: cible) == nil {
            resultat.append(Ligne(id: "aller", icone: "globe", titre: Navigateur.domaine(cible.host ?? t),
                                  detail: cible.absoluteString, url: cible, saisie: nil))
        }
        resultat.append(Ligne(id: "chercher", icone: "magnifyingglass", titre: "Rechercher « \(t) »",
                              detail: moteur.nom, url: nil, saisie: t))
        for s in Navigateur.shared.suggestions(pour: t) {
            resultat.append(Ligne(id: s.id, icone: s.favori ? "star" : "clock",
                                  titre: s.titre.isEmpty ? (s.url.host ?? s.url.absoluteString) : s.titre,
                                  detail: s.url.absoluteString, url: s.url, saisie: nil))
        }
        return resultat
    }

    private func ouvrir(_ ligne: Ligne) {
        if let url = ligne.url {
            onglet.charger(url)
        } else if let saisie = ligne.saisie, let url = Reglages.shared.moteur.adresse(pour: saisie) {
            onglet.charger(url)
        }
        edition = false
    }

    private func valider(_ saisie: String) {
        guard !saisie.nettoye.isEmpty else {
            edition = false
            return
        }
        onglet.charger(saisie)
        edition = false
    }
}

/// Page d'un nouvel onglet : favoris et dernières pages.
struct PageNouvelOnglet: View {
    @ObservedObject var onglet: Onglet
    @ObservedObject private var favoris = Favoris.shared
    @ObservedObject private var historique = Historique.shared
    private let colonnes = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if onglet.prive {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Onglet privé", systemImage: "hand.raised.fill").font(.headline)
                        Text("Pas d'historique, et les cookies s'effacent quand tu fermes le dernier onglet privé. "
                             + "Les sites voient quand même ta visite.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.purple.opacity(0.16)))
                }
                if !favoris.liste.isEmpty {
                    Text("Favoris").font(.title3.bold())
                    LazyVGrid(columns: colonnes, spacing: 16) {
                        ForEach(favoris.liste.prefix(12)) { favori in
                            Button {
                                onglet.charger(favori.url)
                            } label: {
                                VStack(spacing: 6) {
                                    Pastille(texte: favori.titre, url: favori.url)
                                    Text(favori.titre)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !onglet.prive && !historique.visites.isEmpty {
                    Text("Récemment").font(.title3.bold())
                    VStack(spacing: 0) {
                        ForEach(historique.visites.prefix(6)) { visite in
                            Button {
                                onglet.charger(visite.url)
                            } label: {
                                HStack(spacing: 12) {
                                    Pastille(texte: visite.titre, url: visite.url, taille: 34)
                                    LigneSite(titre: visite.titre, url: visite.url)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(onglet.prive ? Color(red: 0.08, green: 0.06, blue: 0.12) : Color(.systemBackground))
        .environment(\.colorScheme, onglet.prive ? .dark : environnement)
    }

    @Environment(\.colorScheme) private var environnement
}

/// Carré coloré avec l'initiale d'un site.
struct Pastille: View {
    let texte: String
    let url: URL
    var taille: CGFloat = 58

    var body: some View {
        let nom = Navigateur.domaine(url.host ?? texte)
        let initiale = (texte.isEmpty ? nom : texte).prefix(1).uppercased()
        let teinte = Double(nom.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(initiale)
            .font(.system(size: taille * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: taille, height: taille)
            .background(RoundedRectangle(cornerRadius: taille * 0.24, style: .continuous)
                .fill(Color(hue: teinte, saturation: 0.55, brightness: 0.78)))
    }
}

struct LigneSite: View {
    let titre: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titre.isEmpty ? (url.host ?? url.absoluteString) : titre)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(url.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

/// La page est une adresse de pub ou de pistage connue.
struct CartePageBloquee: View {
    @ObservedObject var onglet: Onglet
    let url: URL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text("Page bloquée").font(.title2.bold())
            Text("Le bloqueur de pubs empêche d'ouvrir \(url.host ?? url.absoluteString) : c'est une adresse "
                 + "de publicité ou de pistage connue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Ouvrir quand même") { onglet.ouvrirQuandMeme() }
                .buttonStyle(.borderedProminent)
            Button("Retour") { onglet.reculer() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct CarteErreur: View {
    @ObservedObject var onglet: Onglet
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Page inaccessible").font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Réessayer") { onglet.recharger() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
