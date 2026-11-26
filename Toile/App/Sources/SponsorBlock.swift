import CryptoKit
import Foundation
import WebKit

/// Passage d'une vidéo à sauter.
struct SegmentSponsor: Sendable {
    let debut: Double
    let fin: Double
    let categorie: String
}

/// Client de l'API SponsorBlock (sponsor.ajay.app), en mode « préfixe d'empreinte » : on n'envoie que
/// les 4 premiers caractères de l'empreinte SHA-256 de l'identifiant de la vidéo, jamais la vidéo elle-même.
actor ClientSponsorBlock {
    static let shared = ClientSponsorBlock()

    private var cache: [String: (date: Date, segments: [SegmentSponsor])] = [:]

    private struct VideoSB: Decodable {
        let videoID: String
        let segments: [SegmentSB]
    }

    private struct SegmentSB: Decodable {
        let segment: [Double]
        let category: String
        let actionType: String?
    }

    func segments(video: String, categories: [String]) async -> [SegmentSponsor] {
        guard !categories.isEmpty else { return [] }
        let cle = video + "|" + categories.sorted().joined(separator: ",")
        if let deja = cache[cle], Date().timeIntervalSince(deja.date) < 1800 {
            return deja.segments
        }
        let empreinte = SHA256.hash(data: Data(video.utf8)).map { String(format: "%02x", $0) }.joined()
        guard var composants = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(empreinte.prefix(4))") else {
            return []
        }
        let liste = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        composants.queryItems = [URLQueryItem(name: "categories", value: liste),
                                 URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        guard let url = composants.url else { return [] }
        do {
            let (donnees, reponse) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? 0
            var resultat: [SegmentSponsor] = []
            if code == 200 {
                let videos = (try? JSONDecoder().decode([VideoSB].self, from: donnees)) ?? []
                let segments = videos.first(where: { $0.videoID == video })?.segments ?? []
                resultat = segments.compactMap { s -> SegmentSponsor? in
                    guard s.segment.count == 2, (s.actionType ?? "skip") == "skip", s.segment[1] > s.segment[0] else {
                        return nil
                    }
                    return SegmentSponsor(debut: s.segment[0], fin: s.segment[1], categorie: s.category)
                }
            } else if code != 404 {
                // 404 : aucun passage signalé. Autre erreur : on réessaiera à la prochaine ouverture.
                return []
            }
            cache[cle] = (Date(), resultat)
            return resultat
        } catch {
            return []
        }
    }
}

/// Reçoit les demandes du script SponsorBlock (monde isolé « Toile », invisible pour les pages).
@MainActor
final class GestionnaireSponsorBlock: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = GestionnaireSponsorBlock()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let hote = message.frameInfo.securityOrigin.host.lowercased()
        guard Reglages.shared.sponsorBlock, message.frameInfo.isMainFrame,
              hote == "youtube.com" || hote.hasSuffix(".youtube.com"),
              let corps = message.body as? [String: Any], let video = corps["video"] as? String,
              video.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            replyHandler([Any](), nil)
            return
        }
        let categories = Array(Reglages.shared.categories)
        Task {
            let segments = await ClientSponsorBlock.shared.segments(video: video, categories: categories)
            replyHandler(segments.map { ["debut": $0.debut, "fin": $0.fin, "categorie": $0.categorie] as [String: Any] }, nil)
        }
    }
}
