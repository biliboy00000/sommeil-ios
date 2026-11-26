import CryptoKit
import Foundation
import WebKit

/// Bloqueur de pubs et de traqueurs : les listes d'uBlock (EasyList, EasyPrivacy, Liste FR…) converties
/// en règles du moteur de Safari (WKContentRuleList) sur GitHub (Toile/filtres/convertir.py).
///
/// Une copie des listes est dans l'app (dossier « Filtres ») ; une version plus récente est cherchée
/// chaque semaine dans la version « filtres » du dépôt. WebKit garde les listes compilées : la
/// compilation (quelques secondes) n'a lieu qu'au premier lancement et après une mise à jour.
@MainActor
final class Bloqueur: ObservableObject {
    static let shared = Bloqueur()
    static let adresseMiseAJour = URL(string: "https://github.com/biliboy00000/sommeil-ios/releases/download/filtres/")!

    enum Etat: Equatable {
        case preparation
        case pret
        case vide
        case erreur(String)
    }

    struct Manifeste: Codable, Equatable {
        struct Fichier: Codable, Equatable {
            let nom: String
            let regles: Int
            let sha256: String
        }
        struct Liste: Codable, Equatable {
            let nom: String
            let version: String?
        }
        let version: String
        let date: String
        let fichiers: [Fichier]
        let listes: [Liste]?

        var numero: Int { Int(version) ?? 0 }
        var regles: Int { fichiers.reduce(0) { $0 + $1.regles } }
        var dateLisible: String {
            guard let d = ISO8601DateFormatter().date(from: date) else { return date }
            return d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
        }
    }

    enum Erreur: LocalizedError {
        case empreinte, illisible, reseau(Int), aucuneListe
        var errorDescription: String? {
            switch self {
            case .empreinte: return "fichier abîmé (empreinte différente)"
            case .illisible: return "fichier illisible"
            case .reseau(let code): return "réponse \(code) de GitHub"
            case .aucuneListe: return "aucune liste n'a pu être préparée"
            }
        }
    }

    /// Listes compilées, à ajouter à chaque onglet.
    @Published private(set) var listes: [WKContentRuleList] = []
    @Published private(set) var etat: Etat = .preparation
    @Published private(set) var manifeste: Manifeste?
    @Published private(set) var miseAJour = false
    @Published private(set) var messageMiseAJour: String?

    private let magasin: WKContentRuleListStore = WKContentRuleListStore.default()
    private var demarre = false

    private var derniereVerification: Date? {
        get { UserDefaults.standard.object(forKey: "filtres.verification") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "filtres.verification") }
    }

    nonisolated private static var dossierTelecharge: URL {
        Stockage.dossier.appendingPathComponent("Filtres", isDirectory: true)
    }

    nonisolated private static var dossierInclus: URL? {
        Bundle.main.url(forResource: "Filtres", withExtension: nil)
    }

    private init() {}

    /// Au lancement : les listes les plus récentes (de l'app ou téléchargées), puis la vérification hebdomadaire.
    func demarrer() async {
        guard !demarre else { return }
        demarre = true
        var candidats: [(Manifeste, URL)] = []
        if let dossier = Self.dossierInclus, let m = Self.lireManifeste(dans: dossier) {
            candidats.append((m, dossier))
        }
        if let m = Self.lireManifeste(dans: Self.dossierTelecharge) {
            candidats.append((m, Self.dossierTelecharge))
        }
        if let choix = candidats.max(by: { $0.0.numero < $1.0.numero }) {
            _ = await installer(choix.0, depuis: choix.1)
        } else {
            etat = .vide
        }
        let semaine: TimeInterval = 6 * 86_400
        if derniereVerification.map({ Date().timeIntervalSince($0) > semaine }) ?? true {
            await verifierMiseAJour()
        }
    }

    /// Cherche une version plus récente des listes sur GitHub.
    func verifierMiseAJour() async {
        guard !miseAJour else { return }
        miseAJour = true
        messageMiseAJour = nil
        defer { miseAJour = false }
        do {
            let adresse = Self.adresseMiseAJour.appendingPathComponent("manifeste.json")
            let (donnees, reponse) = try await URLSession.shared.data(
                for: URLRequest(url: adresse, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw Erreur.reseau(code) }
            let nouveau = try JSONDecoder().decode(Manifeste.self, from: donnees)
            derniereVerification = Date()
            guard nouveau.numero > (manifeste?.numero ?? 0) else {
                messageMiseAJour = "Les listes sont à jour."
                return
            }
            let gestionnaire = FileManager.default
            let provisoire = Stockage.dossier.appendingPathComponent("Filtres-nouveau", isDirectory: true)
            try? gestionnaire.removeItem(at: provisoire)
            try gestionnaire.createDirectory(at: provisoire, withIntermediateDirectories: true)
            for fichier in nouveau.fichiers {
                let nom = fichier.nom + ".json.deflate"
                let (contenu, r) = try await URLSession.shared.data(
                    for: URLRequest(url: Self.adresseMiseAJour.appendingPathComponent(nom),
                                    cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120))
                let c = (r as? HTTPURLResponse)?.statusCode ?? 0
                guard c == 200 else { throw Erreur.reseau(c) }
                let cible = provisoire.appendingPathComponent(nom)
                try contenu.write(to: cible)
                let empreinte = fichier.sha256
                _ = try await Task.detached(priority: .utility) { try Bloqueur.lire(cible, sha256: empreinte) }.value
            }
            try donnees.write(to: provisoire.appendingPathComponent("manifeste.json"))
            try? gestionnaire.removeItem(at: Self.dossierTelecharge)
            try gestionnaire.moveItem(at: provisoire, to: Self.dossierTelecharge)
            if await installer(nouveau, depuis: Self.dossierTelecharge) {
                messageMiseAJour = "Listes mises à jour (\(nouveau.dateLisible))."
            }
        } catch {
            messageMiseAJour = "Mise à jour impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Installation

    /// Compile (ou retrouve déjà compilées) les listes d'un manifeste, puis les publie.
    private func installer(_ m: Manifeste, depuis dossier: URL) async -> Bool {
        if listes.isEmpty { etat = .preparation }
        var nouvelles: [WKContentRuleList] = []
        var probleme: String?
        for fichier in m.fichiers {
            let identifiant = "toile-\(fichier.nom)-\(fichier.sha256.prefix(16))"
            if let deja = await chercher(identifiant) {
                nouvelles.append(deja)
                continue
            }
            do {
                let url = dossier.appendingPathComponent(fichier.nom + ".json.deflate")
                let empreinte = fichier.sha256
                let texte = try await Task.detached(priority: .userInitiated) {
                    try Bloqueur.lire(url, sha256: empreinte)
                }.value
                nouvelles.append(try await compilerAvecRepli(identifiant, texte))
            } catch {
                probleme = "Liste « \(fichier.nom) » : \(error.localizedDescription)"
            }
        }
        guard !nouvelles.isEmpty else {
            etat = .erreur(probleme ?? Erreur.aucuneListe.localizedDescription)
            return false
        }
        listes = nouvelles
        manifeste = m
        etat = probleme.map { Etat.erreur($0) } ?? Etat.pret
        await nettoyer(garder: Set(nouvelles.compactMap(\.identifier)))
        return true
    }

    nonisolated private static func lireManifeste(dans dossier: URL) -> Manifeste? {
        guard let donnees = try? Data(contentsOf: dossier.appendingPathComponent("manifeste.json")) else { return nil }
        return try? JSONDecoder().decode(Manifeste.self, from: donnees)
    }

    /// Lit un fichier de règles (DEFLATE brut) et vérifie son empreinte.
    nonisolated static func lire(_ url: URL, sha256: String?) throws -> String {
        let brut = try Data(contentsOf: url)
        let donnees = try (brut as NSData).decompressed(using: .zlib) as Data
        if let sha256, hex(SHA256.hash(data: donnees)) != sha256 {
            throw Erreur.empreinte
        }
        guard let texte = String(data: donnees, encoding: .utf8) else { throw Erreur.illisible }
        return texte
    }

    nonisolated static func hex(_ octets: some Sequence<UInt8>) -> String {
        octets.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - WebKit

    private func chercher(_ identifiant: String) async -> WKContentRuleList? {
        await withCheckedContinuation { (suite: CheckedContinuation<WKContentRuleList?, Never>) in
            magasin.lookUpContentRuleList(forIdentifier: identifiant) { liste, _ in
                suite.resume(returning: liste)
            }
        }
    }

    private func compiler(_ identifiant: String, _ texte: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { (suite: CheckedContinuation<WKContentRuleList, Error>) in
            magasin.compileContentRuleList(forIdentifier: identifiant, encodedContentRuleList: texte) { liste, erreur in
                if let liste {
                    suite.resume(returning: liste)
                } else {
                    suite.resume(throwing: erreur ?? Erreur.illisible)
                }
            }
        }
    }

    /// Une règle refusée par WebKit empêche toute sa liste de marcher : si la compilation échoue,
    /// on retrouve les règles refusées par moitiés et on compile le reste.
    private func compilerAvecRepli(_ identifiant: String, _ texte: String) async throws -> WKContentRuleList {
        do {
            return try await compiler(identifiant, texte)
        } catch {
            guard let regles = try? JSONSerialization.jsonObject(with: Data(texte.utf8)) as? [Any] else { throw error }
            let gardees = await acceptees(regles)
            await retirer("toile-essai")
            let donnees = try JSONSerialization.data(withJSONObject: gardees)
            return try await compiler(identifiant, String(decoding: donnees, as: UTF8.self))
        }
    }

    private func acceptees(_ regles: [Any]) async -> [Any] {
        guard !regles.isEmpty else { return [] }
        if let donnees = try? JSONSerialization.data(withJSONObject: regles),
           (try? await compiler("toile-essai", String(decoding: donnees, as: UTF8.self))) != nil {
            return regles
        }
        if regles.count == 1 { return [] }
        let milieu = regles.count / 2
        let debut = await acceptees(Array(regles[..<milieu]))
        let fin = await acceptees(Array(regles[milieu...]))
        return debut + fin
    }

    private func retirer(_ identifiant: String) async {
        await withCheckedContinuation { (suite: CheckedContinuation<Void, Never>) in
            magasin.removeContentRuleList(forIdentifier: identifiant) { _ in suite.resume() }
        }
    }

    /// Retire les anciennes listes compilées.
    private func nettoyer(garder: Set<String>) async {
        let identifiants = await withCheckedContinuation { (suite: CheckedContinuation<[String], Never>) in
            magasin.getAvailableContentRuleListIdentifiers { suite.resume(returning: $0 ?? []) }
        }
        for identifiant in identifiants where identifiant.hasPrefix("toile-") && !garder.contains(identifiant) {
            await retirer(identifiant)
        }
    }
}
