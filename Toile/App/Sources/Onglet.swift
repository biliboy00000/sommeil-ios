import SwiftUI
import UIKit
import WebKit

/// Un onglet : sa page (WKWebView, créée seulement quand on l'affiche), son état et ses réponses à WebKit.
@MainActor
final class Onglet: NSObject, ObservableObject, Identifiable {
    /// Autoriser sans ouvrir l'app associée au site (YouTube…) : on reste dans Toile.
    /// Valeur interne de WebKit (« WKNavigationActionPolicyAllow + 2 »), utilisée par Firefox et Brave.
    static let autoriserSansApp = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    let id: UUID
    let prive: Bool
    unowned let navigateur: Navigateur

    @Published private(set) var titre: String
    @Published private(set) var adresse: URL?
    @Published private(set) var progression: Double = 0
    @Published private(set) var charge = false
    @Published private(set) var peutReculer = false
    @Published private(set) var peutAvancer = false
    @Published private(set) var versionOrdinateur = false
    /// Image de la page pour la liste des onglets.
    @Published var apercu: UIImage?
    /// Page refusée par le bloqueur (adresse de pub ou de pistage connue).
    @Published var pageBloquee: URL?
    /// Page qui n'a pas pu s'ouvrir.
    @Published var erreur: String?

    private var vue: WKWebView?
    private var configurationImposee: WKWebViewConfiguration?
    private var etatARestaurer: Data?
    private var adresseARestaurer: URL?
    private var observations: [NSKeyValueObservation] = []
    private var listesInstallees: [String]?
    private var derniereDemande: URL?

    init(navigateur: Navigateur, prive: Bool, id: UUID = UUID(), titre: String = "", adresse: URL? = nil,
         etat: Data? = nil, configuration: WKWebViewConfiguration? = nil) {
        self.navigateur = navigateur
        self.prive = prive
        self.id = id
        self.titre = titre
        self.adresse = adresse
        self.adresseARestaurer = adresse
        self.etatARestaurer = etat
        self.configurationImposee = configuration
        super.init()
    }

    /// La page existe déjà (sinon : nouvel onglet vide, ou onglet restauré pas encore ouvert).
    var estCree: Bool { vue != nil }

    var webView: WKWebView {
        if let vue { return vue }
        return creer()
    }

    /// État de navigation (pages précédentes comprises) pour la restauration au prochain lancement.
    var etatSauvegarde: Data? {
        (vue?.interactionState as? Data) ?? etatARestaurer
    }

    var estYouTube: Bool {
        guard let hote = adresse?.host?.lowercased() else { return false }
        return hote == "youtube.com" || hote.hasSuffix(".youtube.com")
    }

    private func creer() -> WKWebView {
        let imposee = configurationImposee
        let configuration = imposee ?? Configuration.nouvelle(magasin: navigateur.magasin(prive: prive))
        configurationImposee = nil
        let w = WKWebView(frame: .zero, configuration: configuration)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.isFindInteractionEnabled = true
        w.scrollView.keyboardDismissMode = .interactive
        let rafraichir = UIRefreshControl()
        rafraichir.addTarget(self, action: #selector(tirerPourRecharger(_:)), for: .valueChanged)
        w.scrollView.refreshControl = rafraichir
        vue = w
        observer(w)
        appliquerBloqueur(pour: adresseARestaurer?.host)
        // Fenêtre ouverte par une page : WebKit charge lui-même la page demandée.
        if imposee == nil {
            let etat = etatARestaurer
            let adresseInitiale = adresseARestaurer
            etatARestaurer = nil
            adresseARestaurer = nil
            Task { @MainActor [weak w] in
                guard let w else { return }
                if let etat {
                    w.interactionState = etat
                } else if let adresseInitiale {
                    w.load(URLRequest(url: adresseInitiale))
                }
            }
        }
        return w
    }

    private func observer(_ w: WKWebView) {
        observations = [
            w.observe(\.title, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.titreChange(w.title ?? "") }
            },
            w.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { if let url = w.url { self?.adresse = url } }
            },
            w.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.progression = w.estimatedProgress }
            },
            w.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.charge = w.isLoading }
            },
            w.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.peutReculer = w.canGoBack }
            },
            w.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.peutAvancer = w.canGoForward }
            },
        ]
    }

    private func titreChange(_ nouveau: String) {
        titre = nouveau
        // Sites qui changent de page sans recharger (YouTube…) : le titre suit la nouvelle page.
        if !prive, !charge, !nouveau.isEmpty, let url = vue?.url {
            Historique.shared.noter(url, titre: nouveau)
        }
    }

    // MARK: - Actions

    func charger(_ saisie: String) {
        guard let url = Navigateur.adresse(pour: saisie) else { return }
        charger(url)
    }

    func charger(_ url: URL) {
        pageBloquee = nil
        erreur = nil
        if let vue {
            vue.load(URLRequest(url: url))
        } else {
            adresseARestaurer = url
            etatARestaurer = nil
            adresse = url
            _ = webView
        }
    }

    func reculer() {
        if pageBloquee != nil || erreur != nil {
            pageBloquee = nil
            erreur = nil
            if vue?.url != nil { return }
        }
        vue?.goBack()
    }

    func avancer() { vue?.goForward() }

    func arreter() { vue?.stopLoading() }

    func recharger() {
        pageBloquee = nil
        erreur = nil
        if let vue, vue.url != nil {
            vue.reload()
        } else if let a = derniereDemande ?? adresse {
            charger(a)
        }
    }

    @objc private func tirerPourRecharger(_ controle: UIRefreshControl) {
        recharger()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            controle.endRefreshing()
        }
    }

    func definirVersionOrdinateur(_ active: Bool) {
        versionOrdinateur = active
        vue?.reload()
    }

    /// Ouvre une page refusée par le bloqueur : le bloqueur est coupé pour ce site jusqu'à la fermeture de Toile.
    func ouvrirQuandMeme() {
        guard let url = pageBloquee else { return }
        if let hote = url.host?.lowercased() {
            navigateur.autorisationsTemporaires.insert(hote)
            appliquerBloqueur(pour: hote)
        }
        pageBloquee = nil
        charger(url)
    }

    func rechercherDansLaPage() {
        vue?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func imageDansImage() {
        vue?.evaluateJavaScript(Scripts.imageDansImage, completionHandler: nil)
    }

    /// Prévient la page que l'app passe en arrière-plan (lecture en arrière-plan de YouTube).
    func signalerFond(_ fond: Bool) {
        guard estYouTube else { return }
        vue?.evaluateJavaScript("window.__toileFond && window.__toileFond(\(fond))", completionHandler: nil)
    }

    func prendreApercu() async {
        guard let vue, vue.window != nil else { return }
        let reglage = WKSnapshotConfiguration()
        reglage.snapshotWidth = 320
        let image: UIImage? = await withCheckedContinuation { suite in
            vue.takeSnapshot(with: reglage) { image, _ in suite.resume(returning: image) }
        }
        if let image { apercu = image }
    }

    /// Réglages des extensions ou du bloqueur modifiés.
    func reglagesModifies() {
        if let contenu = vue?.configuration.userContentController {
            Configuration.installerScripts(dans: contenu)
        }
        appliquerBloqueur(pour: adresse?.host)
    }

    /// Met les listes du bloqueur sur la page, sauf si le bloqueur est coupé pour ce site.
    func appliquerBloqueur(pour hote: String?) {
        guard let contenu = vue?.configuration.userContentController else { return }
        let reglages = Reglages.shared
        var actif = reglages.bloqueur
        if let h = hote?.lowercased(), reglages.estAutorise(h) || navigateur.autorisationsTemporaires.contains(h) {
            actif = false
        }
        let voulues = actif ? Bloqueur.shared.listes : []
        let identifiants = voulues.map(\.identifier)
        guard identifiants != listesInstallees else { return }
        contenu.removeAllContentRuleLists()
        for liste in voulues {
            contenu.add(liste)
        }
        listesInstallees = identifiants
    }

    func fermer() {
        vue?.stopLoading()
        vue?.navigationDelegate = nil
        vue?.uiDelegate = nil
        vue?.removeFromSuperview()
        observations.removeAll()
        vue = nil
    }

    private func echec(_ erreur: Error) {
        let e = erreur as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" {
            // 104 : refusée par le bloqueur de contenu.
            if e.code == 104 || e.localizedDescription.lowercased().contains("content blocker") {
                pageBloquee = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? derniereDemande ?? adresse
                return
            }
            // 102 : chargement remplacé (téléchargement, autre page…).
            if e.code == 102 { return }
        }
        self.erreur = e.localizedDescription
    }
}

// MARK: - Navigation

extension Onglet: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url, let schema = url.scheme?.lowercased() else {
            decisionHandler(.cancel, preferences)
            return
        }
        if !["http", "https", "about", "data", "blob", "file", "javascript"].contains(schema) {
            // Téléphone, mail, App Store, autres apps : seulement si on a touché le lien.
            let surs = ["tel", "mailto", "sms", "facetime", "facetime-audio", "itms-apps", "itms-appss", "maps"]
            if navigationAction.navigationType == .linkActivated || surs.contains(schema) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let cadre = navigationAction.targetFrame, cadre.isMainFrame {
            pageBloquee = nil
            erreur = nil
            derniereDemande = url
            appliquerBloqueur(pour: url.host)
            preferences.preferredContentMode = versionOrdinateur ? .desktop : .mobile
            if schema == "http" || schema == "https" {
                decisionHandler(Self.autoriserSansApp, preferences)
                return
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Telechargements.shared.suivre(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Telechargements.shared.suivre(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        erreur = nil
        pageBloquee = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !prive, let url = webView.url {
            Historique.shared.noter(url, titre: webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        echec(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Fenêtres, alertes, menus

extension Onglet: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        navigateur.ouvrirFenetre(configuration: configuration, depuis: self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        navigateur.fermer(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alerte = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alerte.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        Fenetres.presenter(alerte, sinon: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alerte = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alerte.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        alerte.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        Fenetres.presenter(alerte) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alerte = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
        alerte.addTextField { $0.text = defaultText }
        alerte.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(nil) })
        alerte.addAction(UIAlertAction(title: "OK", style: .default) { [weak alerte] _ in
            completionHandler(alerte?.textFields?.first?.text ?? "")
        })
        Fenetres.presenter(alerte) { completionHandler(nil) }
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let lien = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let navigateur = self.navigateur
        let prive = self.prive
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: lien.absoluteString, children: [
                UIAction(title: "Ouvrir dans un nouvel onglet", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    MainActor.assumeIsolated { _ = navigateur.nouvelOnglet(prive: prive, adresse: lien, selectionner: false) }
                },
                UIAction(title: "Ouvrir dans un onglet privé", image: UIImage(systemName: "hand.raised")) { _ in
                    MainActor.assumeIsolated { _ = navigateur.nouvelOnglet(prive: true, adresse: lien) }
                },
                UIAction(title: "Copier le lien", image: UIImage(systemName: "doc.on.doc")) { _ in
                    MainActor.assumeIsolated { UIPasteboard.general.url = lien }
                },
                UIAction(title: "Partager…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    MainActor.assumeIsolated { Fenetres.partager([lien]) }
                },
            ])
        })
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Toile demande à chaque fois (« Autoriser l'appareil photo pour ce site ? »).
        decisionHandler(.prompt)
    }
}

/// Fenêtres d'iOS présentées par-dessus l'app (alertes des pages, partage).
@MainActor
enum Fenetres {
    static var dessus: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controleur = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let suivant = controleur?.presentedViewController, !suivant.isBeingDismissed {
            controleur = suivant
        }
        return controleur
    }

    static func presenter(_ controleur: UIViewController, sinon: @escaping () -> Void) {
        guard let dessus else {
            sinon()
            return
        }
        dessus.present(controleur, animated: true)
    }

    static func partager(_ elements: [Any]) {
        let feuille = UIActivityViewController(activityItems: elements, applicationActivities: nil)
        presenter(feuille) {}
    }
}
