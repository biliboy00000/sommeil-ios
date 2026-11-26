import SwiftUI
import WebKit

enum Ecran: Hashable {
    case favoris, historique, telechargements, extensions, reglages
}

/// Menu « ⋯ » : la page, les onglets, puis favoris, historique, téléchargements, extensions et réglages.
struct VueMenu: View {
    @ObservedObject private var navigateur = Navigateur.shared
    @Environment(\.dismiss) private var fermer
    @State private var chemin: [Ecran]

    init(ecran: Ecran? = nil) {
        _chemin = State(initialValue: ecran.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $chemin) {
            List {
                if let onglet = navigateur.actif {
                    SectionPage(onglet: onglet) { fermer() }
                }
                Section {
                    Button {
                        fermer()
                        navigateur.nouvelOnglet()
                    } label: {
                        Label("Nouvel onglet", systemImage: "plus.square.on.square")
                    }
                    Button {
                        fermer()
                        navigateur.nouvelOnglet(prive: true)
                    } label: {
                        Label("Nouvel onglet privé", systemImage: "hand.raised")
                    }
                }
                Section {
                    NavigationLink(value: Ecran.favoris) { Label("Favoris", systemImage: "star") }
                    NavigationLink(value: Ecran.historique) { Label("Historique", systemImage: "clock") }
                    NavigationLink(value: Ecran.telechargements) { Label("Téléchargements", systemImage: "arrow.down.circle") }
                }
                Section {
                    NavigationLink(value: Ecran.extensions) { Label("Extensions", systemImage: "puzzlepiece.extension") }
                    NavigationLink(value: Ecran.reglages) { Label("Réglages", systemImage: "gearshape") }
                }
            }
            .navigationTitle("Toile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { fermer() }.bold()
                }
            }
            .navigationDestination(for: Ecran.self) { ecran in
                switch ecran {
                case .favoris: VueFavoris(ouvrir: ouvrir)
                case .historique: VueHistorique(ouvrir: ouvrir)
                case .telechargements: VueTelechargements()
                case .extensions: VueExtensions()
                case .reglages: VueReglages()
                }
            }
        }
    }

    private func ouvrir(_ url: URL) {
        navigateur.actif?.charger(url)
        fermer()
    }
}

/// Ce qui concerne la page ouverte.
struct SectionPage: View {
    @ObservedObject var onglet: Onglet
    @ObservedObject private var reglages = Reglages.shared
    @ObservedObject private var favoris = Favoris.shared
    let fermer: () -> Void

    var body: some View {
        if let url = onglet.adresse, let hote = url.host {
            Section {
                Button {
                    favoris.basculer(url, titre: onglet.titre)
                } label: {
                    Label(favoris.contient(url) ? "Retirer des favoris" : "Ajouter aux favoris",
                          systemImage: favoris.contient(url) ? "star.slash" : "star")
                }
                Button {
                    fermer()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        onglet.rechercherDansLaPage()
                    }
                } label: {
                    Label("Rechercher dans la page", systemImage: "doc.text.magnifyingglass")
                }
                if onglet.estYouTube {
                    Button {
                        fermer()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))
                            onglet.imageDansImage()
                        }
                    } label: {
                        Label("Image dans l'image", systemImage: "pip.enter")
                    }
                }
                Toggle(isOn: Binding(get: { onglet.versionOrdinateur }, set: { onglet.definirVersionOrdinateur($0) })) {
                    Label("Version ordinateur", systemImage: "desktopcomputer")
                }
                Toggle(isOn: Binding(get: { reglages.bloqueur && !reglages.estAutorise(hote) },
                                     set: { actif in
                                         reglages.definirBloqueur(actif, pour: hote)
                                         onglet.recharger()
                                     })) {
                    Label("Bloqueur sur ce site", systemImage: "shield.lefthalf.filled")
                }
                .disabled(!reglages.bloqueur)
            } header: {
                Text(Navigateur.domaine(hote))
            }
        }
    }
}

// MARK: - Extensions

struct VueExtensions: View {
    @ObservedObject private var reglages = Reglages.shared
    @ObservedObject private var bloqueur = Bloqueur.shared

    var body: some View {
        Form {
            Section {
                Toggle("Bloquer les pubs et les traqueurs", isOn: $reglages.bloqueur)
                etatBloqueur
                Button {
                    Task { await bloqueur.verifierMiseAJour() }
                } label: {
                    HStack {
                        Text("Chercher une mise à jour des listes")
                        if bloqueur.miseAJour {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(bloqueur.miseAJour)
                if let message = bloqueur.messageMiseAJour {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Bloqueur de pubs")
            } footer: {
                Text("Les listes d'uBlock : \(nomsDesListes). Converties pour le moteur de Safari et mises à jour "
                     + "chaque semaine. Une page bloquée en entier peut être ouverte quand même. Menu ⋯ › « Bloqueur "
                     + "sur ce site » pour le couper sur un site qui ne marche plus.")
            }

            if !reglages.sitesAutorises.isEmpty {
                Section("Sites sans bloqueur") {
                    ForEach(reglages.sitesAutorises, id: \.self) { Text($0) }
                        .onDelete { reglages.sitesAutorises.remove(atOffsets: $0) }
                }
            }

            Section {
                Toggle("SponsorBlock", isOn: $reglages.sponsorBlock)
                if reglages.sponsorBlock {
                    ForEach(Reglages.categoriesSponsor) { categorie in
                        Toggle(isOn: Binding(get: { reglages.categories.contains(categorie.id) }, set: { oui in
                            if oui { reglages.categories.insert(categorie.id) } else { reglages.categories.remove(categorie.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(categorie.nom)
                                Text(categorie.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Saute sur YouTube les passages signalés par les utilisateurs de SponsorBlock (sponsor.ajay.app), "
                     + "avec « Annuler » pour revenir en arrière. Seul le début d'une empreinte de l'identifiant de la "
                     + "vidéo est envoyé.")
            }

            Section {
                Toggle("Bloquer les pubs vidéo", isOn: $reglages.pubsYouTube)
                Toggle("Lecture en arrière-plan", isOn: $reglages.arrierePlan)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Pubs vidéo : retirées avant la lecture ; si une pub passe quand même, elle est coupée et sautée. "
                     + "YouTube change souvent ses pubs, ça peut cesser de marcher un temps. Arrière-plan : le son "
                     + "continue écran verrouillé ou dans une autre app (à l'essai). Image dans l'image : menu ⋯ "
                     + "pendant une vidéo. Les changements comptent au prochain chargement de la page.")
            }
        }
        .navigationTitle("Extensions")
    }

    private var nomsDesListes: String {
        let noms = bloqueur.manifeste?.listes?.map(\.nom) ?? []
        return noms.isEmpty ? "EasyList, EasyPrivacy, Liste FR, uBlock filters, Peter Lowe" : noms.joined(separator: ", ")
    }

    @ViewBuilder
    private var etatBloqueur: some View {
        switch bloqueur.etat {
        case .preparation:
            HStack(spacing: 10) {
                ProgressView()
                Text("Préparation des listes…").foregroundStyle(.secondary)
            }
        case .pret:
            if let m = bloqueur.manifeste {
                LabeledContent("Règles", value: m.regles.formatted())
                LabeledContent("Listes du", value: m.dateLisible)
            }
        case .vide:
            Text("Listes pas encore téléchargées.").foregroundStyle(.secondary)
        case .erreur(let message):
            if let m = bloqueur.manifeste {
                LabeledContent("Règles", value: m.regles.formatted())
            }
            Text(message).font(.footnote).foregroundStyle(.orange)
        }
    }
}

// MARK: - Réglages

struct VueReglages: View {
    @ObservedObject private var reglages = Reglages.shared
    @State private var confirmerHistorique = false
    @State private var confirmerDonnees = false
    @State private var donneesEffacees = false

    var body: some View {
        Form {
            Section("Recherche") {
                Picker("Moteur de recherche", selection: $reglages.moteur) {
                    ForEach(MoteurRecherche.allCases) { Text($0.nom).tag($0) }
                }
            }
            Section {
                Button("Effacer l'historique", role: .destructive) { confirmerHistorique = true }
                Button(donneesEffacees ? "Cookies et données effacés" : "Effacer cookies et données des sites",
                       role: .destructive) { confirmerDonnees = true }
                    .disabled(donneesEffacees)
            } header: {
                Text("Données")
            } footer: {
                Text("Effacer les cookies te déconnecte des sites (YouTube, Google…). Les onglets privés ne gardent "
                     + "rien de toute façon.")
            }
            Section {
                LabeledContent("Version", value: version)
                Link("Code source", destination: URL(string: "https://github.com/biliboy00000/sommeil-ios/tree/main/Toile")!)
            } header: {
                Text("À propos")
            } footer: {
                Text("Toile utilise le moteur de Safari (WebKit), comme tous les navigateurs sur iPhone. "
                     + "Ouvrir un lien depuis un Raccourci : toile://adresse.")
            }
        }
        .navigationTitle("Réglages")
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmerHistorique, titleVisibility: .visible) {
            Button("Effacer l'historique", role: .destructive) { Historique.shared.effacer() }
        }
        .confirmationDialog("Effacer cookies et données des sites ?", isPresented: $confirmerDonnees,
                            titleVisibility: .visible) {
            Button("Effacer", role: .destructive) {
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                        modifiedSince: .distantPast) {
                    donneesEffacees = true
                }
            }
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Favoris, historique, téléchargements

struct VueFavoris: View {
    @ObservedObject private var favoris = Favoris.shared
    let ouvrir: (URL) -> Void

    var body: some View {
        List {
            ForEach(favoris.liste) { favori in
                Button {
                    ouvrir(favori.url)
                } label: {
                    HStack(spacing: 12) {
                        Pastille(texte: favori.titre, url: favori.url, taille: 34)
                        LigneSite(titre: favori.titre, url: favori.url)
                    }
                }
            }
            .onDelete { favoris.liste.remove(atOffsets: $0) }
            .onMove { favoris.liste.move(fromOffsets: $0, toOffset: $1) }
        }
        .overlay {
            if favoris.liste.isEmpty {
                ContentUnavailableView("Pas de favoris", systemImage: "star",
                                       description: Text("Menu ⋯ › Ajouter aux favoris, sur la page à garder."))
            }
        }
        .navigationTitle("Favoris")
        .toolbar { EditButton() }
    }
}

struct VueHistorique: View {
    @ObservedObject private var historique = Historique.shared
    let ouvrir: (URL) -> Void
    @State private var recherche = ""
    @State private var confirmer = false

    private struct Jour: Identifiable {
        let date: Date
        let visites: [Visite]
        var id: Date { date }
    }

    private var jours: [Jour] {
        let filtrees = recherche.isEmpty ? Array(historique.visites.prefix(1500)) : historique.visites.filter {
            $0.titre.localizedCaseInsensitiveContains(recherche) || $0.url.absoluteString.localizedCaseInsensitiveContains(recherche)
        }
        let groupes = Dictionary(grouping: filtrees) { Calendar.current.startOfDay(for: $0.date) }
        return groupes.keys.sorted(by: >).map { Jour(date: $0, visites: groupes[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(jours) { jour in
                Section(titre(jour.date)) {
                    ForEach(jour.visites) { visite in
                        Button {
                            ouvrir(visite.url)
                        } label: {
                            LigneSite(titre: visite.titre, url: visite.url)
                        }
                    }
                    .onDelete { positions in
                        historique.supprimer(Set(positions.map { jour.visites[$0].id }))
                    }
                }
            }
        }
        .overlay {
            if historique.visites.isEmpty {
                ContentUnavailableView("Pas d'historique", systemImage: "clock")
            }
        }
        .searchable(text: $recherche, prompt: "Rechercher dans l'historique")
        .navigationTitle("Historique")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Effacer", role: .destructive) { confirmer = true }
                    .disabled(historique.visites.isEmpty)
            }
        }
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmer, titleVisibility: .visible) {
            Button("Effacer l'historique", role: .destructive) { historique.effacer() }
        }
    }

    private func titre(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Aujourd'hui" }
        if Calendar.current.isDateInYesterday(date) { return "Hier" }
        let texte = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
        return texte.prefix(1).uppercased() + texte.dropFirst()
    }
}

struct VueTelechargements: View {
    @ObservedObject private var telechargements = Telechargements.shared

    var body: some View {
        List {
            ForEach(telechargements.elements) { element in
                HStack(spacing: 12) {
                    Image(systemName: element.erreur != nil ? "exclamationmark.triangle" : (element.fini ? "doc.fill" : "arrow.down.circle"))
                        .foregroundStyle(element.erreur != nil ? Color.orange : Color.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(element.nom).lineLimit(1)
                        if let erreur = element.erreur {
                            Text(erreur).font(.caption).foregroundStyle(.secondary)
                        } else if !element.fini {
                            ProgressView(value: element.progression)
                        }
                    }
                    Spacer(minLength: 0)
                    if element.fini, let fichier = element.fichier {
                        ShareLink(item: fichier) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .overlay {
            if telechargements.elements.isEmpty {
                ContentUnavailableView("Aucun téléchargement", systemImage: "arrow.down.circle",
                                       description: Text("Les fichiers téléchargés vont dans Fichiers › Sur mon iPhone › Toile."))
            }
        }
        .navigationTitle("Téléchargements")
    }
}
