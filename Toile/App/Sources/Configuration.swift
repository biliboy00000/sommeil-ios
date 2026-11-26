import UIKit
import WebKit

/// Réglages de WebKit communs aux onglets : stockage, lecture des vidéos, scripts et bloqueur.
@MainActor
enum Configuration {
    /// Monde isolé des scripts de Toile : la page ne voit ni leurs variables ni leur canal vers l'app.
    static let monde = WKContentWorld.world(name: "Toile")

    /// Fin de l'identifiant envoyé aux sites, comme Safari (sans elle, certains sites donnent une version réduite).
    static var nomApplication: String {
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }

    static func nouvelle(magasin: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = magasin
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.applicationNameForUserAgent = nomApplication
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        let contenu = WKUserContentController()
        contenu.addScriptMessageHandler(GestionnaireSponsorBlock.shared, contentWorld: monde, name: "sponsorblock")
        installerScripts(dans: contenu)
        configuration.userContentController = contenu
        return configuration
    }

    /// (Ré)installe les scripts selon les réglages ; effet au prochain chargement de page.
    static func installerScripts(dans contenu: WKUserContentController) {
        contenu.removeAllUserScripts()
        let reglages = Reglages.shared
        if reglages.pubsYouTube {
            contenu.addUserScript(WKUserScript(source: Scripts.pubsYouTube, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: .page))
        }
        if reglages.arrierePlan {
            contenu.addUserScript(WKUserScript(source: Scripts.arrierePlan, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
        }
        if reglages.sponsorBlock {
            contenu.addUserScript(WKUserScript(source: Scripts.sponsorBlock, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: monde))
        }
    }
}
