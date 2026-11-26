import Combine
import SwiftUI
import WebKit

/// Les onglets (normaux et privés), leur restauration et ce qui les concerne tous.
@MainActor
final class Navigateur: ObservableObject {
    static let shared = Navigateur()

    @Published private(set) var onglets: [Onglet] = []
    @Published var actifID: UUID?
    @Published var afficherOnglets = false
    /// Ouvrir la barre d'adresse (nouvel onglet vide).
    @Published var editionDemandee = false

    /// Sites ouverts malgré le bloqueur (« Ouvrir quand même »), jusqu'à la fermeture de Toile.
    var autorisationsTemporaires: Set<String> = []

    /// Stockage commun des onglets privés (cookies…), oublié quand le dernier onglet privé se ferme.
    private var magasinPrive: WKWebsiteDataStore?
    private var abonnements: Set<AnyCancellable> = []
    private var sauvegardePrevue = false

    var actif: Onglet? {
        onglets.first { $0.id == actifID } ?? onglets.last
    }

    private init() {
        restaurer()
        if onglets.isEmpty {
            nouvelOnglet()
        }
        Bloqueur.shared.$listes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.appliquerBloqueurPartout() }
            .store(in: &abonnements)
    }

    func magasin(prive: Bool) -> WKWebsiteDataStore {
        guard prive else { return .default() }
        if let magasinPrive { return magasinPrive }
        let nouveau = WKWebsiteDataStore.nonPersistent()
        magasinPrive = nouveau
        return nouveau
    }

    // MARK: - Onglets

    @discardableResult
    func nouvelOnglet(prive: Bool = false, adresse: URL? = nil, selectionner: Bool = true) -> Onglet {
        let onglet = Onglet(navigateur: self, prive: prive, adresse: adresse)
        if let a = actif, a.prive == prive, let i = onglets.firstIndex(where: { $0 === a }) {
            onglets.insert(onglet, at: i + 1)
        } else {
            onglets.append(onglet)
        }
        if selectionner {
            actifID = onglet.id
            afficherOnglets = false
            if adresse == nil { editionDemandee = true }
        } else if adresse != nil {
            // Ouvert en arrière-plan : la page commence à se charger tout de suite.
            _ = onglet.webView
        }
        prevoirSauvegarde()
        return onglet
    }

    /// Fenêtre demandée par une page (lien « nouvelle fenêtre ») : un onglet après celui de la page.
    func ouvrirFenetre(configuration: WKWebViewConfiguration, depuis parent: Onglet) -> WKWebView {
        let onglet = Onglet(navigateur: self, prive: parent.prive, configuration: configuration)
        if let i = onglets.firstIndex(where: { $0 === parent }) {
            onglets.insert(onglet, at: i + 1)
        } else {
            onglets.append(onglet)
        }
        actifID = onglet.id
        prevoirSauvegarde()
        return onglet.webView
    }

    func selectionner(_ onglet: Onglet) {
        actifID = onglet.id
        afficherOnglets = false
    }

    func fermer(_ onglet: Onglet) {
        guard let i = onglets.firstIndex(where: { $0 === onglet }) else { return }
        let etaitActif = onglet.id == actif?.id
        onglet.fermer()
        onglets.remove(at: i)
        if !onglets.contains(where: \.prive) {
            magasinPrive = nil
        }
        if onglets.isEmpty {
            nouvelOnglet(selectionner: !afficherOnglets)
        } else if etaitActif {
            // L'onglet d'avant (du même genre : normal ou privé), sinon le premier qui reste.
            let memes = onglets.indices.filter { onglets[$0].prive == onglet.prive }
            let index = memes.last(where: { $0 < i }) ?? memes.first ?? 0
            actifID = onglets[index].id
        }
        prevoirSauvegarde()
    }

    func fermerTout(prive: Bool) {
        for onglet in onglets where onglet.prive == prive {
            onglet.fermer()
        }
        onglets.removeAll { $0.prive == prive }
        if prive { magasinPrive = nil }
        if onglets.isEmpty {
            nouvelOnglet(selectionner: false)
            actifID = onglets.first?.id
        } else if !onglets.contains(where: { $0.id == actifID }) {
            actifID = onglets.last?.id
        }
        prevoirSauvegarde()
    }

    func montrerOnglets() {
        Task { @MainActor in
            await actif?.prendreApercu()
            afficherOnglets = true
        }
    }

    // MARK: - Ce qui concerne tous les onglets

    func reglagesModifies() {
        for onglet in onglets {
            onglet.reglagesModifies()
        }
    }

    func appliquerBloqueurPartout() {
        for onglet in onglets {
            onglet.appliquerBloqueur(pour: onglet.adresse?.host)
        }
    }

    func signalerFond(_ fond: Bool) {
        for onglet in onglets where onglet.estCree {
            onglet.signalerFond(fond)
        }
    }

    /// Lien ouvert depuis une autre app ou un Raccourci : « toile://exemple.com » ou « toile:https://… ».
    func ouvrirDepuisAutreApp(_ url: URL) {
        var texte = url.absoluteString
        for prefixe in ["toile://", "toile:"] where texte.lowercased().hasPrefix(prefixe) {
            texte = String(texte.dropFirst(prefixe.count))
            break
        }
        texte = texte.removingPercentEncoding ?? texte
        if let cible = Self.adresse(pour: texte) {
            nouvelOnglet(adresse: cible)
        }
    }

    // MARK: - Saisie

    /// Adresse d'une saisie de la barre : site (« lemonde.fr ») ou recherche.
    static func adresse(pour saisie: String) -> URL? {
        let texte = saisie.nettoye
        guard !texte.isEmpty else { return nil }
        if let url = URL(string: texte), let schema = url.scheme?.lowercased() {
            if (schema == "http" || schema == "https"), url.host != nil { return url }
            if schema == "about" { return url }
        }
        if !texte.contains(" "), let url = URL(string: "https://" + texte), let hote = url.host?.lowercased() {
            let morceaux = hote.split(separator: ".")
            let ip = morceaux.count == 4 && morceaux.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
            if ip || hote == "localhost" {
                return URL(string: "http://" + texte)
            }
            if morceaux.count >= 2, let fin = morceaux.last, fin.count >= 2, fin.allSatisfy(\.isLetter) {
                return url
            }
        }
        return Reglages.shared.moteur.adresse(pour: texte)
    }

    /// « www.exemple.com » → « exemple.com ».
    static func domaine(_ hote: String) -> String {
        let h = hote.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    struct Suggestion: Identifiable, Hashable {
        let url: URL
        let titre: String
        let favori: Bool
        var id: String { url.absoluteString }
    }

    func suggestions(pour saisie: String) -> [Suggestion] {
        let texte = saisie.nettoye.lowercased()
        guard !texte.isEmpty else { return [] }
        var vues = Set<String>()
        var resultat: [Suggestion] = []
        func correspond(_ titre: String, _ url: URL) -> Bool {
            titre.lowercased().contains(texte) || url.absoluteString.lowercased().contains(texte)
        }
        for f in Favoris.shared.liste where correspond(f.titre, f.url) {
            if vues.insert(f.url.absoluteString).inserted {
                resultat.append(Suggestion(url: f.url, titre: f.titre, favori: true))
            }
        }
        for v in Historique.shared.visites where resultat.count < 8 && correspond(v.titre, v.url) {
            if vues.insert(v.url.absoluteString).inserted {
                resultat.append(Suggestion(url: v.url, titre: v.titre, favori: false))
            }
        }
        return Array(resultat.prefix(8))
    }

    // MARK: - Restauration

    private struct OngletSauve: Codable {
        var id: UUID
        var titre: String
        var adresse: URL?
        var etat: Data?
    }

    private struct Sauvegarde: Codable {
        var onglets: [OngletSauve]
        var actif: UUID?
    }

    /// Onglets normaux seulement : les onglets privés ne laissent pas de trace.
    func sauvegarder() {
        let normaux = onglets.filter { !$0.prive }
        let actifNormal = actif.flatMap { $0.prive ? nil : $0.id } ?? normaux.last?.id
        let sauvegarde = Sauvegarde(onglets: normaux.map {
            OngletSauve(id: $0.id, titre: $0.titre, adresse: $0.adresse, etat: $0.etatSauvegarde)
        }, actif: actifNormal)
        Stockage.ecrire(sauvegarde, "onglets.json")
    }

    private func restaurer() {
        guard let sauvegarde = Stockage.lire(Sauvegarde.self, "onglets.json") else { return }
        onglets = sauvegarde.onglets.map {
            Onglet(navigateur: self, prive: false, id: $0.id, titre: $0.titre, adresse: $0.adresse, etat: $0.etat)
        }
        actifID = sauvegarde.actif ?? onglets.last?.id
    }

    private func prevoirSauvegarde() {
        guard !sauvegardePrevue else { return }
        sauvegardePrevue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            sauvegardePrevue = false
            sauvegarder()
        }
    }
}
