import Foundation

/// Scripts ajoutés aux pages (les « extensions »). Chacun vérifie d'abord qu'il est sur YouTube.
enum Scripts {
    /// Pubs vidéo de YouTube (monde de la page, au tout début du chargement).
    /// 1. Retire les pubs des réponses de YouTube avant la lecture (comme « json-prune » d'uBlock).
    /// 2. Si une pub passe quand même : son coupé, pub avancée à la fin, bouton « Passer » touché.
    /// 3. Cache les emplacements de pub dans les listes de vidéos.
    static let pubsYouTube = #"""
    (() => {
      'use strict';
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname) || window.__toilePubs) return;
      window.__toilePubs = true;
      const CLES = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'adBreakParams'];
      const nettoyer = (o, profondeur = 0) => {
        if (!o || typeof o !== 'object' || profondeur > 3) return o;
        try {
          for (const k of CLES) if (Object.prototype.hasOwnProperty.call(o, k)) delete o[k];
          if (o.playerResponse) nettoyer(o.playerResponse, profondeur + 1);
          if (Array.isArray(o)) for (const x of o) nettoyer(x, profondeur + 1);
        } catch (e) {}
        return o;
      };
      const parse = JSON.parse;
      JSON.parse = function () { return nettoyer(parse.apply(this, arguments)); };
      try {
        const json = Response.prototype.json;
        Response.prototype.json = function () { return json.apply(this, arguments).then((r) => nettoyer(r)); };
      } catch (e) {}
      let initiale;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: () => initiale,
          set: (v) => { initiale = nettoyer(v); },
        });
      } catch (e) {}
      const css = [
        'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-video-renderer', 'ytm-companion-ad-renderer',
        'ytm-companion-slot', 'ad-slot-renderer', 'ytm-ad-slot-renderer', 'ytm-in-feed-ad-layout-renderer',
        'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-promoted-sparkles-web-renderer',
        'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer', '#player-ads', '#masthead-ad',
        '.ytp-ad-overlay-container', '.ytp-ad-image-overlay', 'ytm-mealbar-promo-renderer',
      ].join(',') + '{display:none!important}';
      const style = () => {
        if (document.getElementById('toile-pubs')) return;
        const s = document.createElement('style');
        s.id = 'toile-pubs';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      style();
      document.addEventListener('DOMContentLoaded', style);
      const passer = () => {
        const v = document.querySelector('video');
        if (!v) return;
        if (document.querySelector('.ad-showing, .ad-interrupting')) {
          if (!v.dataset.toileMuet) { v.dataset.toileMuet = v.muted ? 'deja' : 'oui'; v.muted = true; }
          if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.2) {
            try { v.currentTime = v.duration; } catch (e) {}
          }
          const boutons = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytm-skip-ad-button, [class*="skip-ad-button"]';
          for (const b of document.querySelectorAll(boutons)) { try { b.click(); } catch (e) {} }
        } else if (v.dataset.toileMuet) {
          if (v.dataset.toileMuet === 'oui') v.muted = false;
          delete v.dataset.toileMuet;
        }
      };
      setInterval(passer, 300);
    })();
    """#

    /// Lecture en arrière-plan sur YouTube (monde de la page, cadre principal).
    /// La page croit rester visible ; si WebKit met la vidéo en pause au moment où l'app passe en
    /// arrière-plan, elle est relancée (Toile appelle `__toileFond(true)` juste avant).
    static let arrierePlan = #"""
    (() => {
      'use strict';
      if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__toileFond) return;
      const toujours = (nom, valeur) => {
        try { Object.defineProperty(Document.prototype, nom, { configurable: true, get: () => valeur }); } catch (e) {}
      };
      toujours('hidden', false);
      toujours('webkitHidden', false);
      toujours('visibilityState', 'visible');
      toujours('webkitVisibilityState', 'visible');
      const bloquer = (e) => { if (e.target === window || e.target === document) e.stopImmediatePropagation(); };
      for (const type of ['visibilitychange', 'webkitvisibilitychange', 'blur']) {
        window.addEventListener(type, bloquer, true);
        document.addEventListener(type, bloquer, true);
      }
      let fond = 0;
      let jouait = false;
      window.__toileFond = (f) => {
        if (f) {
          const v = document.querySelector('video');
          jouait = !!(v && !v.paused && !v.ended);
          fond = Date.now();
        } else {
          fond = 0;
        }
      };
      document.addEventListener('pause', (e) => {
        const v = e.target;
        if (!(v instanceof HTMLMediaElement) || !fond || !jouait) return;
        // Pause demandée plus tard (écran verrouillé, Centre de contrôle) : c'est toi, on la laisse.
        if (Date.now() - fond > 4000) return;
        setTimeout(() => { v.play().catch(() => {}); }, 60);
      }, true);
    })();
    """#

    /// SponsorBlock (monde isolé « Toile », cadre principal) : demande les passages à Toile, qui
    /// interroge sponsor.ajay.app, puis les saute pendant la lecture, avec « Annuler ».
    static let sponsorBlock = #"""
    (() => {
      'use strict';
      if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
      const NOMS = {
        sponsor: 'Sponsor', selfpromo: 'Autopromotion', interaction: "Rappel d'abonnement", intro: 'Intro',
        outro: 'Fin', preview: 'Aperçu', filler: 'Remplissage', music_offtopic: 'Passage hors musique',
      };
      let courante = null;
      let segments = [];
      let faits = new Set();
      const identifiant = () => {
        try {
          const u = new URL(location.href);
          if (u.pathname === '/watch') return u.searchParams.get('v');
          const m = u.pathname.match(/^\/(?:shorts|live|embed)\/([A-Za-z0-9_-]{11})/);
          return m ? m[1] : null;
        } catch (e) { return null; }
      };
      const charger = async (id) => {
        try {
          const r = await window.webkit.messageHandlers.sponsorblock.postMessage({ video: id });
          if (courante === id && Array.isArray(r)) {
            segments = r.filter((s) => typeof s.debut === 'number' && typeof s.fin === 'number' && s.fin > s.debut);
          }
        } catch (e) {}
      };
      let bulle = null;
      let minuterie = null;
      const annoncer = (texte, annuler) => {
        if (!document.body) return;
        if (!bulle) {
          const hote = document.createElement('div');
          hote.style.cssText = 'position:fixed;left:0;right:0;bottom:28px;display:flex;justify-content:center;z-index:2147483647;pointer-events:none';
          const ombre = hote.attachShadow({ mode: 'closed' });
          ombre.innerHTML = '<style>div{pointer-events:auto;display:flex;gap:16px;align-items:center;background:rgba(22,22,26,.94);color:#fff;font:600 14px -apple-system,system-ui,sans-serif;padding:10px 16px;border-radius:20px;box-shadow:0 4px 18px rgba(0,0,0,.35)}button{all:unset;color:#7cc4ff;font-weight:700;cursor:pointer}</style><div><span></span><button>Annuler</button></div>';
          bulle = { hote, texte: ombre.querySelector('span'), bouton: ombre.querySelector('button') };
        }
        bulle.texte.textContent = texte;
        bulle.bouton.onclick = () => { annuler(); bulle.hote.remove(); };
        document.body.appendChild(bulle.hote);
        clearTimeout(minuterie);
        minuterie = setTimeout(() => bulle.hote.remove(), 4500);
      };
      const verifier = () => {
        const id = identifiant();
        if (id !== courante) {
          courante = id;
          segments = [];
          faits = new Set();
          if (id) charger(id);
        }
        if (!segments.length || document.querySelector('.ad-showing, .ad-interrupting')) return;
        const v = document.querySelector('video');
        if (!v || v.readyState < 1) return;
        const t = v.currentTime;
        for (const s of segments) {
          const cle = s.debut + '-' + s.fin;
          if (faits.has(cle)) continue;
          if (t >= s.debut && t < s.fin - 0.35) {
            faits.add(cle);
            const fin = isFinite(v.duration) && v.duration > 0 ? Math.min(s.fin, v.duration) : s.fin;
            v.currentTime = fin;
            annoncer((NOMS[s.categorie] || 'Passage') + ' passé', () => { v.currentTime = s.debut; });
            break;
          }
        }
      };
      setInterval(verifier, 250);
      document.addEventListener('timeupdate', verifier, true);
    })();
    """#

    /// Image dans l'image pour la vidéo de la page.
    static let imageDansImage = #"""
    (() => {
      const v = document.querySelector('video');
      if (!v) return 'aucune';
      try {
        v.removeAttribute('disablepictureinpicture');
        v.disablePictureInPicture = false;
        if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
          return 'ok';
        }
        if (document.pictureInPictureEnabled) { v.requestPictureInPicture(); return 'ok'; }
      } catch (e) { return String(e); }
      return 'impossible';
    })();
    """#
}
