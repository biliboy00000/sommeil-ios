#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Convertit les listes de filtres d'uBlock (EasyList, EasyPrivacy, Liste FR, uBlock filters…) en règles
du bloqueur de contenu de WebKit (WKContentRuleList), pour le navigateur Toile.

    python3 Toile/filtres/convertir.py <dossier de sortie> [--cache <dossier>]
    python3 Toile/filtres/convertir.py --retirer <dossier>   (après verifier.swift)

Écrit dans le dossier de sortie :
  - cosmetique.json : règles « css-display-none » (masquer les emplacements de pub) ;
  - reseau-1.json, reseau-2.json… : règles « block » (bloquer les requêtes), 45 000 au plus par fichier,
    chacun suivi de toutes les exceptions (WebKit n'applique une exception qu'aux règles de sa liste) ;
  - manifeste.json : version, fichiers, nombre de règles, listes utilisées, règles laissées de côté.
Chaque fichier .json existe aussi en .json.deflate (DEFLATE brut), que l'app lit avec
NSData.decompressed(using: .zlib).

WebKit ne sait pas tout faire : les scriptlets (« ##+js(…) »), les filtres procéduraux (:has-text…),
$redirect, $removeparam, $csp… sont laissés de côté, avec un décompte par raison dans le manifeste.
Les règles sont ensuite compilées par le vrai WebKit (verifier.swift, sur le Mac de GitHub), qui
retire celles qu'il refuse.

Ne dépend que de la bibliothèque standard de Python.
"""
import collections
import datetime
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import zlib

LISTES = [
    {"nom": "EasyList", "url": "https://easylist.to/easylist/easylist.txt"},
    {"nom": "EasyPrivacy", "url": "https://easylist.to/easylist/easyprivacy.txt"},
    {"nom": "Liste FR", "url": "https://easylist-downloads.adblockplus.org/liste_fr.txt"},
    {"nom": "uBlock filters", "url": "https://ublockorigin.github.io/uAssets/filters/filters.txt"},
    {"nom": "uBlock filters – Privacy", "url": "https://ublockorigin.github.io/uAssets/filters/privacy.txt"},
    {"nom": "Peter Lowe", "url": "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext"},
]

# Règles par fichier réseau (WebKit en accepte 150 000 par liste ; on reste loin pour la mémoire de l'iPhone).
PAR_FICHIER = 45000
# Sélecteurs par règle cosmétique : si WebKit refuse un sélecteur, il ne perd que son paquet.
SELECTEURS_PAR_REGLE = 40

# Conditions « !#if » d'uBlock : ce qui est vrai pour Toile (WebKit sur iPhone). Le reste est faux.
ENVIRONNEMENT = {"env_safari": True, "env_mobile": True}

# Extensions courantes pour les domaines « exemple.* ».
TLD_COURANTS = ["com", "net", "org", "fr", "be", "ch", "ca", "de", "es", "it", "nl", "pt", "pl", "eu", "co.uk",
                "info", "io", "co", "me", "tv", "to", "cc", "xyz", "top", "site", "online", "live", "club", "ru",
                "br", "in", "us", "biz", "ws", "la", "li", "is", "se"]

TYPES = {
    "script": {"script"}, "image": {"image"}, "stylesheet": {"style-sheet"}, "css": {"style-sheet"},
    "font": {"font"}, "media": {"media"}, "xmlhttprequest": {"fetch"}, "xhr": {"fetch"},
    "websocket": {"websocket"}, "other": {"other"}, "ping": {"ping"}, "beacon": {"ping"},
    "subdocument": {"SOUS_DOCUMENT"}, "frame": {"SOUS_DOCUMENT"}, "object": set(), "webrtc": set(),
    "object-subrequest": set(),
}
TYPES_DE_BASE = {"image", "style-sheet", "script", "font", "media", "fetch", "websocket", "other", "ping",
                 "SOUS_DOCUMENT"}
# Options qui font laisser la règle de côté (WebKit ne sait pas les appliquer).
IMPOSSIBLES = {"redirect", "redirect-rule", "removeparam", "queryprune", "csp", "permissions", "header", "method",
               "replace", "rewrite", "urlskip", "uritransform", "urltransform", "cname", "ipaddress", "denyallow",
               "to", "empty", "mp4", "sitekey", "genericblock", "inline-script", "inline-font", "popunder",
               "jsinject", "content", "extension", "stealth", "cookie", "network", "app", "hls", "jsonprune",
               "referrerpolicy", "urlblock", "popup", "responseheader", "requestheader", "xmlprune"}
SANS_EFFET = {"_", "__", "reason"}

PROCEDURAUX = (":has-text(", ":-abp-", ":contains(", ":matches-css", ":matches-attr", ":matches-media",
               ":matches-path", ":matches-prop", ":min-text-length", ":others(", ":upward(", ":watch-attr",
               ":xpath(", ":remove(", ":remove-attr", ":remove-class", ":style(", ":nth-ancestor", ":if(",
               ":if-not(", ":properties(", ":shadow", ":spath", ":matches-property")

MARQUE_COSMETIQUE = re.compile(r"#@?(?:\$\?|\?|\$|%)?#|\$@?\$")
OPTION = re.compile(r"^~?[a-z0-9_\-]+(=.*)?$", re.I)
DOMAINE = re.compile(r"^[a-z0-9_\-]+(\.[a-z0-9_\-]+)*$")
EXCEPTION_DOMAINE = re.compile(r"^\|\|([a-z0-9.\-]+)\^?\|?$")


# --- Téléchargement --------------------------------------------------------------------------------

_MEMOIRE = {}


def telecharger(url, cache=None):
    if url in _MEMOIRE:
        return _MEMOIRE[url]
    _MEMOIRE[url] = texte = _telecharger(url, cache)
    return texte


def _telecharger(url, cache=None):
    if cache:
        nom = os.path.join(cache, hashlib.sha1(url.encode()).hexdigest() + ".txt")
        if os.path.exists(nom):
            with open(nom, encoding="utf-8", errors="replace") as f:
                return f.read()
    erreur = None
    for essai in range(4):
        try:
            requete = urllib.request.Request(url, headers={"User-Agent": "Toile-filtres/1.0 (navigateur iPhone personnel)"})
            with urllib.request.urlopen(requete, timeout=60) as r:
                texte = r.read().decode("utf-8", errors="replace")
            break
        except Exception as e:  # réseau capricieux : on réessaie
            erreur = e
            time.sleep(3 * (essai + 1))
    else:
        raise SystemExit("Téléchargement impossible : %s (%s)" % (url, erreur))
    if cache:
        os.makedirs(cache, exist_ok=True)
        with open(nom, "w", encoding="utf-8") as f:
            f.write(texte)
    return texte


def condition(expression):
    """Évalue une condition « !#if » d'uBlock (env_mobile, !ext_ubol, a && b, a || b, parenthèses)."""
    jetons = re.findall(r"&&|\|\||!|\(|\)|[A-Za-z0-9_]+", expression)
    morceaux = []
    for j in jetons:
        if j == "&&":
            morceaux.append(" and ")
        elif j == "||":
            morceaux.append(" or ")
        elif j == "!":
            morceaux.append(" not ")
        elif j in "()":
            morceaux.append(j)
        else:
            morceaux.append(" True " if ENVIRONNEMENT.get(j, False) else " False ")
    try:
        return bool(eval("".join(morceaux) or "False", {"__builtins__": {}}, {}))
    except Exception:
        return False


def lignes_de(url, cache, vues=None):
    """Lignes actives d'une liste, avec ses « !#include » (même site seulement) et ses « !#if »."""
    vues = vues if vues is not None else set()
    if url in vues:
        return []
    vues.add(url)
    texte = telecharger(url, cache)
    resultat = []
    pile = []
    for brute in texte.splitlines():
        ligne = brute.strip()
        if ligne.startswith("!#if"):
            pile.append(condition(ligne[4:]))
            continue
        if ligne.startswith("!#else"):
            if pile:
                pile[-1] = not pile[-1]
            continue
        if ligne.startswith("!#endif"):
            if pile:
                pile.pop()
            continue
        if not all(pile):
            continue
        if ligne.startswith("!#include"):
            cible = urllib.parse.urljoin(url, ligne[len("!#include"):].strip())
            if urllib.parse.urlparse(cible).netloc == urllib.parse.urlparse(url).netloc:
                resultat.extend(lignes_de(cible, cache, vues))
            continue
        resultat.append(ligne)
    return resultat


def entete(texte, cle):
    m = re.search(r"^!\s*%s:\s*(.+)$" % re.escape(cle), texte, re.M)
    return m.group(1).strip() if m else None


# --- Expressions régulières de WebKit ------------------------------------------------------------

def motif_en_regex(motif):
    """Motif d'adresse d'Adblock (||, |, ^, *) en expression de WebKit (même méthode qu'AdGuard)."""
    if motif in ("", "||", "|", "*"):
        return ".*"
    sortie = []
    i, n = 0, len(motif)
    separateur_domaine = False
    while i < n:
        c = motif[i]
        suivant = motif[i + 1] if i + 1 < n else None
        if c in ".+?${}()[]/\\":
            sortie.append("\\" + c)
            if c != ".":
                separateur_domaine = False
        elif c == "|":
            if i == 0:
                if suivant == "|":
                    sortie.append(r"^[^:]+://+([^:/]+\.)?")
                    separateur_domaine = True
                    i += 1
                else:
                    sortie.append("^")
            elif suivant is None:
                sortie.append("$")
            else:
                sortie.append("\\|")
        elif c == "^":
            if separateur_domaine:
                sortie.append("[/:]")
                separateur_domaine = False
            elif suivant is None:
                sortie.append("[/:&?]?")
            else:
                sortie.append("[/:&?]")
        elif c == "*":
            sortie.append(".*")
            separateur_domaine = False
        else:
            if ord(c) > 127:
                raise ValueError("caractère non ASCII")
            if c == ":":
                separateur_domaine = False
            sortie.append(c)
        i += 1
    return "".join(sortie)


def regex_acceptee(motif):
    """Vrai si WebKit sait lire cette expression (règles relevées par AdGuard, SafariRegex.swift)."""
    pile = []
    quantifiable = False
    i, n = 0, len(motif)
    while i < n:
        c = motif[i]
        if ord(c) > 127:
            return False
        dans_classe = bool(pile) and pile[-1] == "["
        if c == "\\":
            if i + 1 >= n or motif[i + 1] not in ".*+?/[]()|{}^$\\":
                return False
            i += 2
            quantifiable = True
            continue
        if c == "(":
            if not dans_classe:
                pile.append(c)
                quantifiable = False
        elif c == "[":
            pile.append(c)
            quantifiable = False
        elif c == ")":
            if not dans_classe:
                if not pile or pile.pop() != "(":
                    return False
            quantifiable = True
        elif c == "]":
            if not pile or pile.pop() != "[":
                return False
            quantifiable = True
        elif c == "^":
            if i != 0 and not dans_classe:
                return False
            quantifiable = False
        elif c == "$":
            if i + 1 < n and not dans_classe:
                return False
            quantifiable = False
        elif c == "|":
            if not dans_classe:
                return False
        elif c in "{}":
            if not dans_classe:
                return False
        elif c in "*+?":
            if not quantifiable and not dans_classe:
                return False
            quantifiable = False
        else:
            quantifiable = True
        i += 1
    return not pile


def filtres_adresse(motif):
    """Expressions « url-filter » pour un motif, ou None si WebKit ne peut pas l'exprimer."""
    if " " in motif:
        return None
    if len(motif) > 2 and motif.startswith("/") and motif.endswith("/"):
        regex = motif[1:-1]
        if re.search(r"\\[dDwWsSbB]|\(\?", regex):
            return None
        return [regex] if regex_acceptee(regex) else None
    try:
        regex = motif_en_regex(motif)
    except ValueError:
        return None
    # « ^ » en fin de motif : séparateur ou fin de l'adresse (deux règles).
    if regex.endswith("[/:&?]?"):
        base = regex[: -len("[/:&?]?")]
        candidats = [base + "[/:&?]", base + "$"]
    else:
        candidats = [regex]
    if not all(regex_acceptee(c) for c in candidats):
        return None
    return candidats


# --- Domaines ----------------------------------------------------------------------------------

def domaine_propre(texte):
    """« Exemple.com » → « exemple.com » (punycode si besoin) ; None si ce n'est pas un domaine simple."""
    d = texte.strip().lower()
    if d.startswith("*."):
        d = d[2:]
    if not d or d.startswith("/"):
        return None
    if any(ord(c) > 127 for c in d):
        try:
            d = d.encode("idna").decode("ascii")
        except Exception:
            return None
    return d if DOMAINE.match(d) else None


def domaines(liste, separateur):
    """(inclus, exclus) ; None si la liste contient une expression régulière (non gérée)."""
    inclus, exclus = set(), set()
    for brut in liste.split(separateur):
        brut = brut.strip()
        if not brut:
            continue
        negatif = brut.startswith("~")
        if negatif:
            brut = brut[1:]
        if brut.startswith("/"):
            return None
        if brut == "*":
            continue
        if brut.endswith(".*"):
            candidats = [brut[:-2] + "." + t for t in TLD_COURANTS]
        else:
            candidats = [brut]
        for c in candidats:
            d = domaine_propre(c)
            if d:
                (exclus if negatif else inclus).add(d)
    return inclus, exclus


def avec_etoile(ensemble):
    return sorted("*" + d for d in ensemble)


# --- Conversion ----------------------------------------------------------------------------------

class Convertisseur:
    def __init__(self):
        self.ignorees = collections.Counter()
        # Cosmétique
        self.generiques = collections.defaultdict(set)    # sélecteur → domaines exclus
        self.specifiques = collections.defaultdict(set)   # sélecteur → domaines
        self.exceptions_css = collections.defaultdict(set)  # sélecteur → domaines où il ne s'applique pas
        self.desactives = set()                            # « #@#sélecteur » : sélecteur retiré partout
        self.sans_specifiques = set()                      # $specifichide
        self.exc_generiques = []                           # $generichide
        self.exc_elements = []                             # $elemhide
        self.exc_documents = []                            # $document
        # Réseau
        self.blocages = []
        self.exceptions = []
        self.importants = []
        self.exceptions_importantes = []

    # Cosmétique

    @staticmethod
    def selecteur(texte):
        s = texte.strip()
        if not s or s[0] in "+^>~" or s.startswith("+js("):
            return None
        bas = s.lower()
        if any(p in bas for p in PROCEDURAUX):
            return None
        if "{" in s or "}" in s or s.count("(") != s.count(")") or s.count("[") != s.count("]"):
            return None
        if s.count('"') % 2:
            return None
        # Non ASCII : échappements CSS (« é » → « \e9 »).
        return "".join(c if ord(c) < 128 else "\\%x " % ord(c) for c in s)

    def cosmetique(self, avant, marque, apres):
        if marque not in ("##", "#@#"):
            self.ignorees["cosmétique non gérée (%s)" % marque] += 1
            return
        s = self.selecteur(apres)
        if s is None:
            self.ignorees["sélecteur procédural ou scriptlet"] += 1
            return
        doms = domaines(avant, ",")
        if doms is None:
            self.ignorees["domaine en expression régulière"] += 1
            return
        inclus, exclus = doms
        if marque == "#@#":
            if not inclus and not exclus:
                self.desactives.add(s)
            else:
                self.exceptions_css[s] |= inclus
            return
        if inclus:
            self.specifiques[s] |= inclus
        else:
            self.generiques[s] |= exclus

    # Réseau

    @staticmethod
    def separer_options(texte):
        i = texte.rfind("$")
        if i < 0:
            return texte, []
        options = texte[i + 1:].split(",")
        if not options or not all(OPTION.match(o) for o in options):
            return texte, []
        return texte[:i], options

    def reseau(self, ligne):
        exception = ligne.startswith("@@")
        corps = ligne[2:] if exception else ligne
        motif, options = self.separer_options(corps)
        positifs, negatifs = set(), set()
        inclus, exclus = set(), set()
        tiers = None
        important = casse = document = elements = generiques = specifiques = False
        for brute in options:
            negatif = brute.startswith("~")
            nom, _, valeur = brute.lstrip("~").partition("=")
            nom = nom.lower()
            if nom in ("domain", "from"):
                doms = domaines(valeur, "|")
                if doms is None:
                    self.ignorees["domaine en expression régulière"] += 1
                    return
                inclus |= doms[0]
                exclus |= doms[1]
            elif nom in ("third-party", "3p", "strict3p"):
                tiers = "first-party" if negatif else "third-party"
            elif nom in ("first-party", "1p", "strict1p"):
                tiers = "third-party" if negatif else "first-party"
            elif nom == "important":
                important = True
            elif nom == "match-case":
                casse = True
            elif nom in TYPES:
                (negatifs if negatif else positifs).update(TYPES[nom])
            elif nom in ("document", "doc"):
                if negatif:
                    self.ignorees["$~document"] += 1
                    return
                document = True
            elif nom == "all":
                positifs |= TYPES_DE_BASE
                document = True
            elif nom in ("elemhide", "ehide"):
                elements = True
            elif nom in ("generichide", "ghide"):
                generiques = True
            elif nom in ("specifichide", "shide"):
                specifiques = True
            elif nom in SANS_EFFET:
                pass
            elif nom in IMPOSSIBLES:
                self.ignorees["$" + nom] += 1
                return
            else:
                self.ignorees["option inconnue"] += 1
                return

        # Exceptions pour tout un site : $document, $elemhide, $generichide, $specifichide.
        if exception and (document or elements or generiques or specifiques):
            m = EXCEPTION_DOMAINE.match(motif.lower())
            cibles = {m.group(1)} if m else (inclus if motif in ("", "*") else set())
            cibles = {d for d in (domaine_propre(c) for c in cibles) if d}
            if not cibles:
                self.ignorees["exception de page avec chemin"] += 1
                return
            regle = {"trigger": {"url-filter": ".*", "if-domain": avec_etoile(cibles)},
                     "action": {"type": "ignore-previous-rules"}}
            if document:
                self.exc_documents.append(regle)
            elif elements:
                self.exc_elements.append(regle)
            elif generiques:
                self.exc_generiques.append(regle)
            if specifiques and not document and not elements:
                self.sans_specifiques |= cibles
            return
        if not exception and (elements or generiques or specifiques):
            self.ignorees["option d'exception sur un blocage"] += 1
            return

        filtres = filtres_adresse(motif)
        if filtres is None:
            self.ignorees["adresse inexprimable pour WebKit"] += 1
            return
        if filtres == [".*"] and not inclus and not exception:
            self.ignorees["blocage de tout, sans domaine"] += 1
            return

        # Types de ressources.
        if positifs or negatifs:
            types = set(positifs) if positifs else TYPES_DE_BASE - negatifs
            if not types and not document:
                self.ignorees["types non gérés (object, webrtc)"] += 1
                return
            if document:
                types.add("document")
        elif document:
            types = {"document"}
        elif exception or motif.startswith("||"):
            # Exception : elle peut tout débloquer. « ||pub.exemple.com^ » : tout bloquer, y compris la page
            # elle-même (Toile propose alors de l'ouvrir quand même).
            types = None
        else:
            # Motif de chemin (« /pub/* ») : jamais la page principale, pour ne pas bloquer un article.
            types = set(TYPES_DE_BASE)

        variantes = []
        if types is None:
            variantes.append((None, None))
        else:
            if "SOUS_DOCUMENT" in types and "document" not in types:
                variantes.append((["document"], ["child-frame"]))
            reste = sorted(types - {"SOUS_DOCUMENT"})
            if reste:
                variantes.append((reste, None))

        for filtre in filtres:
            for types_ressource, contexte in variantes:
                declencheur = {"url-filter": filtre}
                if casse:
                    declencheur["url-filter-is-case-sensitive"] = True
                if inclus:
                    declencheur["if-domain"] = avec_etoile(inclus)
                elif exclus:
                    declencheur["unless-domain"] = avec_etoile(exclus)
                if types_ressource:
                    declencheur["resource-type"] = types_ressource
                if contexte:
                    declencheur["load-context"] = contexte
                if tiers:
                    declencheur["load-type"] = [tiers]
                regle = {"trigger": declencheur,
                         "action": {"type": "ignore-previous-rules" if exception else "block"}}
                if exception:
                    (self.exceptions_importantes if important else self.exceptions).append(regle)
                else:
                    (self.importants if important else self.blocages).append(regle)

    def ligne(self, ligne):
        if not ligne or ligne.startswith("!") or ligne.startswith("["):
            return
        m = MARQUE_COSMETIQUE.search(ligne)
        if m:
            self.cosmetique(ligne[:m.start()], m.group(0), ligne[m.end():])
        else:
            self.reseau(ligne)

    # Assemblage

    def regles_cosmetiques(self):
        larges = []
        groupes = collections.defaultdict(list)
        for s, exclus in self.generiques.items():
            if s in self.desactives:
                continue
            groupes[frozenset(exclus | self.exceptions_css.get(s, set()))].append(s)
        for exclus, selecteurs in sorted(groupes.items(), key=lambda g: (len(g[0]), sorted(g[0]))):
            selecteurs.sort()
            for i in range(0, len(selecteurs), SELECTEURS_PAR_REGLE):
                declencheur = {"url-filter": ".*"}
                if exclus:
                    declencheur["unless-domain"] = avec_etoile(exclus)
                larges.append({"trigger": declencheur,
                               "action": {"type": "css-display-none",
                                          "selector": ", ".join(selecteurs[i:i + SELECTEURS_PAR_REGLE])}})
        specifiques = []
        groupes = collections.defaultdict(list)
        for s, inclus in self.specifiques.items():
            if s in self.desactives:
                continue
            reste = inclus - self.exceptions_css.get(s, set()) - self.sans_specifiques
            if reste:
                groupes[frozenset(reste)].append(s)
        for inclus, selecteurs in sorted(groupes.items(), key=lambda g: sorted(g[0])):
            selecteurs.sort()
            for i in range(0, len(selecteurs), SELECTEURS_PAR_REGLE):
                specifiques.append({"trigger": {"url-filter": ".*", "if-domain": avec_etoile(inclus)},
                                    "action": {"type": "css-display-none",
                                               "selector": ", ".join(selecteurs[i:i + SELECTEURS_PAR_REGLE])}})
        # Même ordre qu'AdGuard : une exception n'annule que les règles placées avant elle.
        return (larges + unique(self.exc_generiques) + specifiques + unique(self.exc_elements)
                + unique(self.exc_documents))

    def fichiers_reseau(self):
        blocages = unique(self.blocages)
        exceptions = unique(self.exceptions)
        importants = unique(self.importants)
        exceptions_importantes = unique(self.exceptions_importantes)
        documents = unique(self.exc_documents)
        fin = exceptions + importants + exceptions_importantes + documents
        place = PAR_FICHIER - len(fin)
        if place < 10000:
            raise SystemExit("Trop d'exceptions (%d) pour des fichiers de %d règles" % (len(fin), PAR_FICHIER))
        paquets = [blocages[i:i + place] for i in range(0, len(blocages), place)] or [[]]
        return [p + fin for p in paquets]


def unique(regles):
    vues, resultat = set(), []
    for r in regles:
        cle = json.dumps(r, sort_keys=True)
        if cle not in vues:
            vues.add(cle)
            resultat.append(r)
    return resultat


def sans_badfilter(ligne):
    corps, options = Convertisseur.separer_options(ligne)
    reste = [o for o in options if o.lower() != "badfilter"]
    return corps + ("$" + ",".join(reste) if reste else "")


def ecrire(dossier, nom, regles):
    texte = json.dumps(regles, ensure_ascii=True, separators=(",", ":"))
    donnees = texte.encode("ascii")
    with open(os.path.join(dossier, nom + ".json"), "wb") as f:
        f.write(donnees)
    compresseur = zlib.compressobj(9, zlib.DEFLATED, -15)
    compresse = compresseur.compress(donnees) + compresseur.flush()
    with open(os.path.join(dossier, nom + ".json.deflate"), "wb") as f:
        f.write(compresse)
    return {"nom": nom, "regles": len(regles), "octets": len(donnees), "octetsCompresses": len(compresse),
            "sha256": hashlib.sha256(donnees).hexdigest()}


def principal(sortie, cache=None):
    os.makedirs(sortie, exist_ok=True)
    conv = Convertisseur()
    infos = []
    toutes = []
    for liste in LISTES:
        texte = telecharger(liste["url"], cache)
        lignes = lignes_de(liste["url"], cache)
        infos.append({"nom": liste["nom"], "url": liste["url"], "version": entete(texte, "Version")
                      or entete(texte, "Last modified") or entete(texte, "Last updated"), "lignes": len(lignes)})
        toutes.extend(lignes)
    # $badfilter : désactive la règle identique sans cette option.
    retirees = set()
    for ligne in toutes:
        if "$" in ligne and "badfilter" in ligne.lower():
            _, options = Convertisseur.separer_options(ligne)
            if any(o.lower() == "badfilter" for o in options):
                retirees.add(sans_badfilter(ligne))
    vues = set()
    for ligne in toutes:
        if ligne in vues:
            continue
        vues.add(ligne)
        if ligne in retirees or (ligne and "badfilter" in ligne.lower() and sans_badfilter(ligne) != ligne):
            conv.ignorees["$badfilter"] += 1
            continue
        conv.ligne(ligne)

    fichiers = [ecrire(sortie, "cosmetique", conv.regles_cosmetiques())]
    for i, paquet in enumerate(conv.fichiers_reseau(), 1):
        fichiers.append(ecrire(sortie, "reseau-%d" % i, paquet))
    maintenant = datetime.datetime.now(datetime.timezone.utc)
    manifeste = {
        "version": maintenant.strftime("%Y%m%d%H%M"),
        "date": maintenant.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fichiers": fichiers,
        "listes": infos,
        "laisseesDeCote": dict(conv.ignorees.most_common()),
    }
    with open(os.path.join(sortie, "manifeste.json"), "w", encoding="utf-8") as f:
        json.dump(manifeste, f, ensure_ascii=False, indent=1)
    for fi in fichiers:
        print("%-12s %7d règles  %6.1f Mo (%4.1f Mo compressé)" % (
            fi["nom"], fi["regles"], fi["octets"] / 1e6, fi["octetsCompresses"] / 1e6))
    print("Laissées de côté :", ", ".join("%s : %d" % kv for kv in conv.ignorees.most_common()))


def retirer(dossier):
    """Retire les règles refusées par WebKit (rejets.json de verifier.swift) et réécrit les fichiers."""
    with open(os.path.join(dossier, "rejets.json"), encoding="utf-8") as f:
        rejets = json.load(f)
    with open(os.path.join(dossier, "manifeste.json"), encoding="utf-8") as f:
        manifeste = json.load(f)
    fichiers = []
    total = 0
    for fi in manifeste["fichiers"]:
        positions = set(rejets.get(fi["nom"], []))
        if fi["nom"] not in rejets:
            raise SystemExit("%s n'a pas été vérifié par WebKit" % fi["nom"])
        if positions:
            with open(os.path.join(dossier, fi["nom"] + ".json"), encoding="ascii") as f:
                regles = json.load(f)
            regles = [r for i, r in enumerate(regles) if i not in positions]
            fi = ecrire(dossier, fi["nom"], regles)
            total += len(positions)
        fichiers.append(fi)
    manifeste["fichiers"] = fichiers
    manifeste["refuseesParWebKit"] = total
    with open(os.path.join(dossier, "manifeste.json"), "w", encoding="utf-8") as f:
        json.dump(manifeste, f, ensure_ascii=False, indent=1)
    os.remove(os.path.join(dossier, "rejets.json"))
    print("Règles refusées par WebKit retirées : %d" % total)


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if arguments[:1] == ["--retirer"] and len(arguments) == 2:
        retirer(arguments[1])
        sys.exit(0)
    cache = None
    if "--cache" in arguments:
        i = arguments.index("--cache")
        cache = arguments[i + 1]
        del arguments[i:i + 2]
    if len(arguments) != 1:
        print(__doc__)
        sys.exit(1)
    principal(arguments[0], cache)
