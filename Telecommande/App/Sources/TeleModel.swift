import Foundation
import SwiftUI

/// Le PC appairé : adresse, port et clé d'accès (donnés par le QR code du programme PC).
struct TeleAppairage: Codable, Equatable {
    var hote: String
    var port: Int
    var cle: String
    var nom: String

    /// Lit « gadget-telecommande://192.168.1.20:8765/?k=CLE&nom=PC ».
    init?(lien: String) {
        guard let c = URLComponents(string: lien.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "gadget-telecommande", let h = c.host, !h.isEmpty,
              let k = c.queryItems?.first(where: { $0.name == "k" })?.value, !k.isEmpty
        else { return nil }
        hote = h
        port = c.port ?? 8765
        cle = k
        nom = c.queryItems?.first(where: { $0.name == "nom" })?.value ?? h
    }

    init(hote: String, port: Int, cle: String, nom: String) {
        self.hote = hote; self.port = port; self.cle = cle; self.nom = nom
    }

    func url(_ chemin: String) -> URL? {
        var c = URLComponents()
        c.scheme = "ws"; c.host = hote; c.port = port; c.path = chemin
        c.queryItems = [URLQueryItem(name: "k", value: cle)]
        return c.url
    }
}

enum TeleConnexion: Equatable {
    case deconnecte, connexion, connecte
    case erreur(String)
}

/// Connexion au programme PC, état partagé (volume, sortie du son) et envoi des commandes.
final class TeleModel: ObservableObject {
    @Published var appairage: TeleAppairage? {
        didSet { enregistrer() }
    }
    @Published private(set) var connexion: TeleConnexion = .deconnecte
    @Published private(set) var nomPC = ""
    @Published private(set) var volumePC: Double = 0.5
    @Published private(set) var muetPC = false
    /// Où va le son : sur le PC ou sur le téléphone.
    @Published private(set) var sonSurTelephone = false
    @Published private(set) var basculeEnCours = false
    @Published var message: String?

    @Published var gainTelephone: Double = 1 { didSet { audio.gain = Float(gainTelephone) } }
    @Published var latenceMs: Double = UserDefaults.standard.object(forKey: "tele.latence") as? Double ?? 100 {
        didSet {
            audio.latenceMs = latenceMs
            UserDefaults.standard.set(latenceMs, forKey: "tele.latence")
        }
    }
    @Published var vitesse: Double = UserDefaults.standard.object(forKey: "tele.vitesse") as? Double ?? 1.4 {
        didSet { UserDefaults.standard.set(vitesse, forKey: "tele.vitesse") }
    }

    let audio = TeleAudio()
    private var tache: URLSessionWebSocketTask?
    private var veutEtreConnecte = false
    private var essais = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "tele.appairage"),
           let a = try? JSONDecoder().decode(TeleAppairage.self, from: data) {
            appairage = a
        }
        audio.latenceMs = latenceMs
    }

    private func enregistrer() {
        if let appairage, let data = try? JSONEncoder().encode(appairage) {
            UserDefaults.standard.set(data, forKey: "tele.appairage")
        } else {
            UserDefaults.standard.removeObject(forKey: "tele.appairage")
        }
    }

    // MARK: Connexion

    func connecter() {
        guard let appairage, let url = appairage.url("/ws") else { return }
        veutEtreConnecte = true
        tache?.cancel(with: .goingAway, reason: nil)
        connexion = .connexion
        nomPC = appairage.nom
        let t = URLSession.shared.webSocketTask(with: url)
        tache = t
        t.resume()
        recevoir(t)
        envoyer(["t": "bonjour"])
    }

    func deconnecter() {
        veutEtreConnecte = false
        if sonSurTelephone { envoyer(["t": "son", "vers": "pc"]) }
        audio.arreter()
        sonSurTelephone = false
        let t = tache
        tache = nil
        // laisse partir le dernier message avant de fermer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { t?.cancel(with: .goingAway, reason: nil) }
        connexion = .deconnecte
    }

    func oublier() {
        deconnecter()
        appairage = nil
    }

    private func recevoir(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] resultat in
            DispatchQueue.main.async {
                guard let self, t === self.tache else { return }
                switch resultat {
                case .success(.string(let texte)):
                    self.traiter(texte)
                    self.recevoir(t)
                case .success:
                    self.recevoir(t)
                case .failure(let e):
                    self.perdu(e)
                }
            }
        }
    }

    private func perdu(_ e: Error) {
        tache = nil
        if sonSurTelephone {
            audio.arreter()
            sonSurTelephone = false
        }
        guard veutEtreConnecte else { connexion = .deconnecte; return }
        connexion = .erreur("PC injoignable. Le programme tourne-t-il ? Même Wi-Fi ?")
        essais += 1
        let delai = min(8.0, Double(essais))
        DispatchQueue.main.asyncAfter(deadline: .now() + delai) { [weak self] in
            guard let self, self.veutEtreConnecte, self.tache == nil else { return }
            self.connecter()
        }
    }

    private func traiter(_ texte: String) {
        guard let data = texte.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["t"] as? String {
        case "infos":
            connexion = .connecte
            essais = 0
            nomPC = msg["nom"] as? String ?? nomPC
            volumePC = msg["volume"] as? Double ?? volumePC
            muetPC = msg["muet"] as? Bool ?? muetPC
            let surTel = (msg["sortie"] as? String) == "telephone"
            appliquerSortie(surTel)
            if let err = msg["erreur_audio"] as? String, surTel {
                message = "Le PC n'arrive pas à capturer son son : \(err)"
            }
        case "erreur":
            message = msg["message"] as? String
        default:
            break
        }
    }

    // MARK: Son

    /// Le bouton « Son : PC / Téléphone ».
    func basculerSon(versTelephone: Bool) {
        guard connexion == .connecte else { return }
        basculeEnCours = true
        envoyer(["t": "son", "vers": versTelephone ? "telephone" : "pc"])
    }

    private func appliquerSortie(_ surTel: Bool) {
        basculeEnCours = false
        guard surTel != sonSurTelephone || (surTel && !audio.enMarche) else { return }
        if surTel {
            guard let url = appairage?.url("/audio") else { return }
            do {
                try audio.demarrer(url: url)
                sonSurTelephone = true
            } catch {
                message = "Lecture impossible sur le téléphone : \(error.localizedDescription)"
                envoyer(["t": "son", "vers": "pc"])
            }
        } else {
            audio.arreter()
            sonSurTelephone = false
        }
    }

    // MARK: Commandes

    func envoyer(_ msg: [String: Any]) {
        guard let tache, let data = try? JSONSerialization.data(withJSONObject: msg),
              let texte = String(data: data, encoding: .utf8) else { return }
        tache.send(.string(texte)) { _ in }
    }

    func bouger(_ dx: Double, _ dy: Double) { envoyer(["t": "bouger", "dx": dx, "dy": dy]) }
    func clic(_ b: String = "gauche", n: Int = 1) { envoyer(["t": "clic", "b": b, "n": n]) }
    func bouton(_ b: String, appui: Bool) { envoyer(["t": "bouton", "b": b, "appui": appui]) }
    func defiler(_ dx: Double, _ dy: Double) { envoyer(["t": "defiler", "dx": dx, "dy": dy]) }
    func taper(_ texte: String) { envoyer(["t": "texte", "texte": texte]) }
    func touche(_ k: String, n: Int = 1) { envoyer(["t": "touche", "k": k, "n": n]) }
    func combinaison(_ touches: [String]) { envoyer(["t": "combinaison", "touches": touches]) }
    func alimentation(_ a: String) { envoyer(["t": "alimentation", "a": a]) }
    func ouvrir(_ url: String) { envoyer(["t": "ouvrir", "url": url]) }

    func reglerVolumePC(_ v: Double) {
        volumePC = v
        envoyer(["t": "volume", "v": v])
    }
}
