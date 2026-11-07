#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Télécommande — programme à lancer sur l'ordinateur (Windows).

Le gadget « Télécommande » de l'app Gadget s'y connecte par le Wi-Fi de la maison :
  • /ws     commandes (souris, clavier, lecture, volume, alimentation, son)
  • /audio  le son de l'ordinateur envoyé au téléphone (quand « Son : Téléphone » est choisi)

Sécurité : une clé d'accès aléatoire (dans config.json) est exigée à chaque connexion ; elle est
donnée au téléphone par le QR code affiché au démarrage. Le programme tourne dans cette fenêtre,
visible ; le fermer arrête tout. Il n'écoute que sur le réseau local : ne l'expose pas sur Internet.

Variables utiles :
  TELECOMMANDE_PORT=8765         port d'écoute
  TELECOMMANDE_SIMULATION=1      n'agit pas sur l'ordinateur (pour tester) ; le son est un bip de test
"""
import asyncio
import json
import math
import os
import platform
import secrets
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

from aiohttp import web

ICI = Path(__file__).resolve().parent
PORT = int(os.environ.get("TELECOMMANDE_PORT", "8765"))
SIMULATION = os.environ.get("TELECOMMANDE_SIMULATION") == "1"
WINDOWS = platform.system() == "Windows"
VERSION = 1

TAUX = 48000          # échantillons par seconde
BLOC = 480            # 10 ms par paquet audio
CANAUX = 2


def journal(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ configuration

def charger_config():
    chemin = ICI / "config.json"
    try:
        cfg = json.loads(chemin.read_text(encoding="utf-8"))
    except Exception:
        cfg = {}
    if not cfg.get("cle"):
        cfg["cle"] = secrets.token_urlsafe(12)
        chemin.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return cfg


CONFIG = charger_config()
CLE = CONFIG["cle"]


# ------------------------------------------------------------------ souris et clavier

if not SIMULATION:
    from pynput.keyboard import Controller as Clavier, Key
    from pynput.mouse import Button, Controller as Souris
    souris, clavier = Souris(), Clavier()
    BOUTONS = {"gauche": Button.left, "droit": Button.right, "milieu": Button.middle}
    TOUCHES = {
        "entree": Key.enter, "retour": Key.backspace, "echap": Key.esc, "tab": Key.tab,
        "espace": Key.space, "suppr": Key.delete, "gauche": Key.left, "droite": Key.right,
        "haut": Key.up, "bas": Key.down, "debut": Key.home, "fin": Key.end,
        "pageprec": Key.page_up, "pagesuiv": Key.page_down, "f5": Key.f5, "f11": Key.f11,
        "ctrl": Key.ctrl, "alt": Key.alt, "maj": Key.shift, "win": Key.cmd,
        "lecture": Key.media_play_pause, "suivant": Key.media_next, "precedent": Key.media_previous,
        "muet": Key.media_volume_mute,
    }


def touche(nom):
    if nom in TOUCHES:
        return TOUCHES[nom]
    if len(nom) == 1:
        return nom
    raise ValueError("touche inconnue : %s" % nom)


def appuyer(nom, n=1):
    k = touche(nom)
    for _ in range(max(1, min(int(n), 200))):
        clavier.press(k)
        clavier.release(k)


def combinaison(noms):
    ks = [touche(n) for n in noms][:4]
    for k in ks:
        clavier.press(k)
    for k in reversed(ks):
        clavier.release(k)


# ------------------------------------------------------------------ volume (Windows)

class Volume:
    """Volume général et coupure du son de la sortie par défaut, via pycaw."""

    def __init__(self):
        self.ep = None
        if SIMULATION or not WINDOWS:
            self._v, self._m = 0.5, False
            return
        import comtypes
        comtypes.CoInitialize()
        from pycaw.pycaw import AudioUtilities
        dev = AudioUtilities.GetSpeakers()
        ep = getattr(dev, "EndpointVolume", None)   # pycaw récent
        if ep is None:                                # pycaw plus ancien
            from ctypes import POINTER, cast
            from comtypes import CLSCTX_ALL
            from pycaw.pycaw import IAudioEndpointVolume
            ep = cast(dev.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None), POINTER(IAudioEndpointVolume))
        self.ep = ep

    def lire(self):
        if self.ep is None:
            return self._v, self._m
        return float(self.ep.GetMasterVolumeLevelScalar()), bool(self.ep.GetMute())

    def regler(self, v):
        v = max(0.0, min(1.0, float(v)))
        if self.ep is None:
            self._v = v
        else:
            self.ep.SetMasterVolumeLevelScalar(v, None)

    def couper(self, m):
        if self.ep is None:
            self._m = bool(m)
        else:
            self.ep.SetMute(1 if m else 0, None)


# ------------------------------------------------------------------ son de l'ordinateur → téléphone

class Capture:
    """Capture « ce que l'ordinateur joue » (bouclage WASAPI).

    Un seul fil, créé une fois et gardé jusqu'à la fin du programme : la bibliothèque `soundcard`
    initialise le système audio de Windows (COM) dans le fil qui l'importe, et refuse de le faire
    dans un autre fil (erreurs 0x800401F0 / 0x100000001). Basculer le son ne fait donc que mettre
    ce fil en marche ou en pause. Chaque bloc de 10 ms (int16 stéréo) est remis à `rappel`."""

    def __init__(self, rappel, echec=None):
        self.rappel = rappel
        self.echec = echec          # appelé (depuis le fil) si la capture s'arrête sur une erreur
        self.voulu = threading.Event()
        self.erreur = None
        self.fil = None

    def demarrer(self):
        self.erreur = None
        self.voulu.set()
        if self.fil is None or not self.fil.is_alive():
            self.fil = threading.Thread(target=self._fil, daemon=True, name="capture-son")
            self.fil.start()

    def arreter(self):
        self.voulu.clear()

    def _fil(self):
        sc = None
        while True:
            self.voulu.wait()
            try:
                if SIMULATION:
                    self._bip()
                else:
                    if sc is None:
                        import warnings
                        import soundcard as sc
                        # « data discontinuity » : simple trou de capture, sans gravité
                        warnings.filterwarnings("ignore", category=getattr(sc, "SoundcardRuntimeWarning", RuntimeWarning))
                    self._wasapi(sc)
            except Exception as e:  # signalé au téléphone, et le son revient sur le PC
                self.erreur = str(e)
                journal("⚠️  capture du son impossible :", e)
                self.voulu.clear()
                if self.echec:
                    self.echec()

    def _bip(self):
        import numpy as np
        t0, n = time.perf_counter(), 0
        while self.voulu.is_set():
            t = (np.arange(BLOC) + n * BLOC) / TAUX
            s = (0.2 * np.sin(2 * math.pi * 440 * t) * (np.sin(2 * math.pi * 1 * t) > 0)).astype(np.float32)
            self.rappel(np.repeat((s * 32767).astype(np.int16)[:, None], 2, axis=1).tobytes())
            n += 1
            attente = t0 + n * BLOC / TAUX - time.perf_counter()
            if attente > 0:
                time.sleep(attente)

    def _wasapi(self, sc):
        import numpy as np
        haut_parleur = sc.default_speaker()
        micro = sc.get_microphone(str(haut_parleur.name), include_loopback=True)
        journal("🎧 capture de « %s »" % haut_parleur.name)
        with micro.recorder(samplerate=TAUX, channels=CANAUX, blocksize=BLOC) as rec:
            while self.voulu.is_set():
                bloc = rec.record(numframes=BLOC)
                if bloc.ndim == 1:
                    bloc = np.repeat(bloc[:, None], 2, axis=1)
                bloc = np.clip(bloc[:, :2], -1, 1)
                self.rappel((bloc * 32767).astype("<i2").tobytes())


# ------------------------------------------------------------------ état partagé

class Etat:
    def __init__(self):
        self.commandes = set()      # WebSocket /ws ouverts
        self.auditeurs = {}         # WebSocket /audio → file d'attente
        self.sortie = "pc"          # où va le son : "pc" ou "telephone"
        self.muet_avant = None      # état « muet » du PC avant de passer le son au téléphone
        self.volume = Volume()
        self.boucle = None
        self.capture = Capture(self._bloc_audio, self._capture_en_echec)

    # appelé depuis le fil de capture
    def _bloc_audio(self, donnees):
        if self.boucle is None:
            return
        self.boucle.call_soon_threadsafe(self._distribuer, donnees)

    def _capture_en_echec(self):
        if self.boucle is None:
            return

        def retour_pc():
            if self.sortie == "telephone":
                self.capture.arreter()
                self.volume.couper(bool(self.muet_avant))
                self.sortie = "pc"
                journal("🔊 son → ordinateur (capture en échec)")
            asyncio.ensure_future(self.diffuser_infos())

        self.boucle.call_soon_threadsafe(retour_pc)

    def _distribuer(self, donnees):
        for file in self.auditeurs.values():
            if file.full():           # téléphone en retard : on jette le plus ancien
                try:
                    file.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            file.put_nowait(donnees)

    def infos(self):
        v, m = self.volume.lire()
        return {"t": "infos", "nom": socket.gethostname(), "systeme": platform.system(), "version": VERSION,
                "volume": round(v, 3), "muet": m, "sortie": self.sortie,
                "audio": {"taux": TAUX, "canaux": CANAUX, "format": "int16le"},
                "erreur_audio": self.capture.erreur, "simulation": SIMULATION}

    async def diffuser_infos(self):
        msg = json.dumps(self.infos())
        for ws in list(self.commandes):
            try:
                await ws.send_str(msg)
            except Exception:
                pass

    def son_vers(self, cible):
        if cible == self.sortie:
            return
        if cible == "telephone":
            self.capture.erreur = None
            self.muet_avant = self.volume.lire()[1]
            self.capture.demarrer()
            self.volume.couper(True)     # le bouclage capture quand même le son, avant la coupure
            journal("🔊 son → téléphone (haut-parleurs du PC coupés)")
        else:
            self.capture.arreter()
            self.volume.couper(bool(self.muet_avant))
            journal("🔊 son → ordinateur")
        self.sortie = cible


ETAT = Etat()


# ------------------------------------------------------------------ actions

def lancer(cmd):
    if SIMULATION:
        journal("   (simulation)", " ".join(cmd))
        return
    subprocess.Popen(cmd, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


ALIMENTATION_WINDOWS = {
    "verrouiller": ["rundll32.exe", "user32.dll,LockWorkStation"],
    "veille": ["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"],
    "redemarrer": ["shutdown", "/r", "/t", "5"],
    "eteindre": ["shutdown", "/s", "/t", "15"],
    "annuler": ["shutdown", "/a"],
    "ecran": ["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
              "(Add-Type -MemberDefinition '[DllImport(''user32.dll'')] public static extern int "
              "SendMessage(int h, int m, int w, int l);' -Name EcranNoir -Namespace Tc -PassThru)"
              "::SendMessage(-1, 0x0112, 0xF170, 2)"],
}


async def executer(msg):
    t = msg.get("t")
    if t == "bonjour":
        return ETAT.infos()

    if t == "son":
        ETAT.son_vers("telephone" if msg.get("vers") == "telephone" else "pc")
        await ETAT.diffuser_infos()
        return None

    if t == "volume":
        ETAT.volume.regler(msg.get("v", 0.5))
        await ETAT.diffuser_infos()
        return None

    if t == "alimentation":
        a = msg.get("a")
        if a not in ALIMENTATION_WINDOWS:
            raise ValueError("action inconnue")
        if a in ("veille", "eteindre", "redemarrer") and ETAT.sortie == "telephone":
            ETAT.son_vers("pc")
        journal("⏻", a)
        lancer(ALIMENTATION_WINDOWS[a] if WINDOWS else ["echo", a])
        return None

    if t == "ouvrir":
        url = str(msg.get("url", ""))
        if not url.startswith(("http://", "https://")):
            url = "https://www.google.com/search?q=" + url.replace(" ", "+")
        journal("🌐", url)
        if not SIMULATION:
            webbrowser.open(url)
        return None

    if t not in ("bouger", "clic", "bouton", "defiler", "texte", "touche", "combinaison"):
        raise ValueError("commande inconnue : %s" % t)
    if SIMULATION:
        return None

    if t == "bouger":
        souris.move(float(msg.get("dx", 0)), float(msg.get("dy", 0)))
    elif t == "clic":
        souris.click(BOUTONS.get(msg.get("b", "gauche"), Button.left), max(1, min(int(msg.get("n", 1)), 3)))
    elif t == "bouton":
        b = BOUTONS.get(msg.get("b", "gauche"), Button.left)
        souris.press(b) if msg.get("appui") else souris.release(b)
    elif t == "defiler":
        souris.scroll(float(msg.get("dx", 0)), float(msg.get("dy", 0)))
    elif t == "texte":
        clavier.type(str(msg.get("texte", ""))[:2000])
    elif t == "touche":
        appuyer(str(msg.get("k")), msg.get("n", 1))
    elif t == "combinaison":
        combinaison([str(k) for k in msg.get("touches", [])])
    else:
        raise ValueError("commande inconnue : %s" % t)
    return None


# ------------------------------------------------------------------ serveur web

def autorise(request):
    return secrets.compare_digest(request.query.get("k", ""), CLE)


async def ws_commandes(request):
    if not autorise(request):
        raise web.HTTPForbidden(text="clé d'accès incorrecte")
    ws = web.WebSocketResponse(heartbeat=10)
    await ws.prepare(request)
    ETAT.commandes.add(ws)
    journal("📱 téléphone connecté (%s)" % request.remote)
    try:
        async for m in ws:
            if m.type != web.WSMsgType.TEXT:
                continue
            try:
                rep = await executer(json.loads(m.data))
                if rep:
                    await ws.send_str(json.dumps(rep))
            except Exception as e:
                await ws.send_str(json.dumps({"t": "erreur", "message": str(e)}))
    finally:
        ETAT.commandes.discard(ws)
        journal("📴 téléphone déconnecté")
        # plus aucun téléphone : le son revient sur l'ordinateur
        if not ETAT.commandes and ETAT.sortie == "telephone":
            ETAT.son_vers("pc")
    return ws


async def ws_audio(request):
    if not autorise(request):
        raise web.HTTPForbidden(text="clé d'accès incorrecte")
    ws = web.WebSocketResponse(heartbeat=10, compress=False)
    await ws.prepare(request)
    file = asyncio.Queue(maxsize=50)   # 500 ms au plus en attente
    ETAT.auditeurs[ws] = file
    try:
        lecture = asyncio.ensure_future(ws.receive())
        while not ws.closed:
            envoi = asyncio.ensure_future(file.get())
            fini, _ = await asyncio.wait({envoi, lecture}, return_when=asyncio.FIRST_COMPLETED)
            if lecture in fini:
                envoi.cancel()
                break
            await ws.send_bytes(envoi.result())
    finally:
        ETAT.auditeurs.pop(ws, None)
    return ws


async def accueil(request):
    return web.Response(text="Télécommande : ouvre le gadget « Télécommande » de l'app Gadget et scanne le QR code.\n")


def ip_locale():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def banniere(lien):
    ligne = "─" * 62
    print(ligne)
    print("  📱  TÉLÉCOMMANDE prête sur %s" % socket.gethostname())
    print(ligne)
    print("  Dans l'app Gadget › Télécommande › « Scanner le QR code » :\n")
    try:
        import qrcode
        qr = qrcode.QRCode(border=1)
        qr.add_data(lien)
        qr.make()
        qr.print_ascii(invert=True)
    except ImportError:
        pass
    print("  Ou saisis à la main :  adresse %s   clé %s" % (lien.split("//")[1].split("/")[0], CLE))
    print("  Le téléphone doit être sur le même Wi-Fi. Ferme cette fenêtre pour tout arrêter.")
    if SIMULATION:
        print("  ⚠️  MODE SIMULATION : aucune action réelle, le son est un bip de test.")
    print(ligne, flush=True)


async def au_demarrage(app):
    ETAT.boucle = asyncio.get_running_loop()


async def a_l_arret(app):
    if ETAT.sortie == "telephone":
        ETAT.son_vers("pc")


def principal():
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    app = web.Application()
    app.router.add_get("/", accueil)
    app.router.add_get("/ws", ws_commandes)
    app.router.add_get("/audio", ws_audio)
    app.on_startup.append(au_demarrage)
    app.on_shutdown.append(a_l_arret)
    lien = "gadget-telecommande://%s:%d/?k=%s&nom=%s" % (ip_locale(), PORT, CLE, socket.gethostname())
    banniere(lien)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    principal()
