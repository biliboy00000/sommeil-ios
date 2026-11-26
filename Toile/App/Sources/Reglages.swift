import Foundation
import SwiftUI

/// Moteurs de recherche proposés.
enum MoteurRecherche: String, CaseIterable, Identifiable {
    case google, duckduckgo, qwant, ecosia, bing

    var id: String { rawValue }

    var nom: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .qwant: return "Qwant"
        case .ecosia: return "Ecosia"
        case .bing: return "Bing"
        }
    }

    private var page: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckduckgo: return "https://duckduckgo.com/"
        case .qwant: return "https://www.qwant.com/"
        case .ecosia: return "https://www.ecosia.org/search"
        case .bing: return "https://www.bing.com/search"
        }
    }

    /// Adresse de la page de résultats pour une recherche.
    func adresse(pour texte: String) -> URL? {
        guard var composants = URLComponents(string: page) else { return nil }
        composants.queryItems = [URLQueryItem(name: "q", value: texte)]
        // « + » veut dire espace pour les moteurs : on l'encode pour chercher « C++ ».
        composants.percentEncodedQuery = composants.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return composants.url
    }

    /// La recherche à afficher dans la barre, si l'adresse est une page de résultats d'un moteur.
    static func recherche(dans url: URL) -> String? {
        guard let hote = url.host?.lowercased(),
              let composants = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let pages = [("google.", "/search"), ("duckduckgo.com", "/"), ("qwant.com", "/"), ("ecosia.org", "/search"),
                     ("bing.com", "/search")]
        guard pages.contains(where: { hote.contains($0.0) && composants.path == $0.1 }) else { return nil }
        return composants.queryItems?.first(where: { $0.name == "q" })?.value
    }
}

/// Catégorie de passages de SponsorBlock.
struct CategorieSponsor: Identifiable {
    let id: String
    let nom: String
    let detail: String
}

/// Réglages du navigateur, gardés dans UserDefaults.
@MainActor
final class Reglages: ObservableObject {
    static let shared = Reglages()

    static let categoriesSponsor = [
        CategorieSponsor(id: "sponsor", nom: "Sponsors", detail: "Placements de produits payés"),
        CategorieSponsor(id: "selfpromo", nom: "Autopromotion", detail: "Produits du vidéaste, dons, boutique"),
        CategorieSponsor(id: "interaction", nom: "Rappels d'abonnement", detail: "« Abonne-toi, mets un like… »"),
        CategorieSponsor(id: "intro", nom: "Intros", detail: "Génériques et animations de début"),
        CategorieSponsor(id: "outro", nom: "Fins", detail: "Écrans de fin et crédits"),
        CategorieSponsor(id: "preview", nom: "Aperçus", detail: "Résumés de ce qui va suivre"),
        CategorieSponsor(id: "filler", nom: "Remplissage", detail: "Digressions hors sujet"),
        CategorieSponsor(id: "music_offtopic", nom: "Hors musique", detail: "Passages non musicaux des clips"),
    ]

    private let stock = UserDefaults.standard

    @Published var moteur: MoteurRecherche {
        didSet { stock.set(moteur.rawValue, forKey: "moteur") }
    }
    /// Bloqueur de pubs et de traqueurs.
    @Published var bloqueur: Bool {
        didSet { stock.set(bloqueur, forKey: "bloqueur"); Navigateur.shared.reglagesModifies() }
    }
    /// Sites où le bloqueur est coupé (domaines).
    @Published var sitesAutorises: [String] {
        didSet { stock.set(sitesAutorises, forKey: "sitesAutorises"); Navigateur.shared.reglagesModifies() }
    }
    @Published var sponsorBlock: Bool {
        didSet { stock.set(sponsorBlock, forKey: "sponsorBlock"); Navigateur.shared.reglagesModifies() }
    }
    /// Catégories de passages à sauter.
    @Published var categories: Set<String> {
        didSet { stock.set(Array(categories).sorted(), forKey: "categories") }
    }
    /// YouTube : retirer les pubs vidéo.
    @Published var pubsYouTube: Bool {
        didSet { stock.set(pubsYouTube, forKey: "pubsYouTube"); Navigateur.shared.reglagesModifies() }
    }
    /// YouTube : le son continue en arrière-plan.
    @Published var arrierePlan: Bool {
        didSet { stock.set(arrierePlan, forKey: "arrierePlan"); Navigateur.shared.reglagesModifies() }
    }

    private init() {
        stock.register(defaults: [
            "moteur": MoteurRecherche.google.rawValue, "bloqueur": true, "sponsorBlock": true,
            "categories": ["sponsor", "selfpromo", "interaction", "intro"], "pubsYouTube": true, "arrierePlan": true,
        ])
        moteur = MoteurRecherche(rawValue: stock.string(forKey: "moteur") ?? "") ?? .google
        bloqueur = stock.bool(forKey: "bloqueur")
        sitesAutorises = stock.stringArray(forKey: "sitesAutorises") ?? []
        sponsorBlock = stock.bool(forKey: "sponsorBlock")
        categories = Set(stock.stringArray(forKey: "categories") ?? [])
        pubsYouTube = stock.bool(forKey: "pubsYouTube")
        arrierePlan = stock.bool(forKey: "arrierePlan")
    }

    /// Le bloqueur est coupé pour ce site.
    func estAutorise(_ hote: String) -> Bool {
        let h = hote.lowercased()
        return sitesAutorises.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Allume ou coupe le bloqueur pour un site.
    func definirBloqueur(_ actif: Bool, pour hote: String) {
        let domaine = Navigateur.domaine(hote)
        if actif {
            let h = hote.lowercased()
            sitesAutorises.removeAll { h == $0 || h.hasSuffix("." + $0) }
        } else if !estAutorise(hote) {
            sitesAutorises.append(domaine)
            sitesAutorises.sort()
        }
    }
}

extension String {
    var nettoye: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
