"""Täglicher Funktions-Check für padel-run.de (läuft per GitHub Actions).
Prüft nur lesend – legt keine Konten, Spiele oder Mails an."""
import re, sys, json, urllib.request, urllib.error, ssl
from urllib.parse import urljoin, urlparse
from playwright.sync_api import sync_playwright

BASE = "https://padel-run.de"
SEITEN = ["/", "/app/", "/laden/", "/gewinnspiel.html", "/teilnahmebedingungen.html",
          "/datenschutz.html", "/impressum.html", "/nutzungsbedingungen.html", "/support.html",
          "/sitemap.xml", "/robots.txt", "/app/manifest.webmanifest", "/app/version.json"]
# Seiten, die Bots oft blocken: nur Warnung statt Fehler
NUR_WARNUNG = ("instagram.com", "tiktok.com", "apps.apple.com", "playtomic", "facebook.com", "wa.me", "whatsapp.com", "linkedin.com")
FEHLER, WARN, OK = [], [], []

def hole(url, methode="GET"):
    req = urllib.request.Request(url, method=methode, headers={"User-Agent": "Mozilla/5.0 (PadelRun-Check)"})
    try:
        with urllib.request.urlopen(req, timeout=20, context=ssl.create_default_context()) as r:
            return r.status, r.read() if methode == "GET" else b""
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception as e:
        return 0, str(e).encode()

def pruefe_link(url, quelle):
    st, _ = hole(url, "GET")
    host = urlparse(url).netloc
    if 200 <= st < 400:
        OK.append(url)
    elif any(h in host for h in NUR_WARNUNG):
        WARN.append(f"{url} (Status {st}, verlinkt auf {quelle}) – Seite blockt evtl. nur Bots")
    else:
        FEHLER.append(f"Link kaputt: {url} (Status {st}, verlinkt auf {quelle})")

# 1) Alle Seiten erreichbar + alle Links darauf prüfen
links = {}
for p in SEITEN:
    st, body = hole(BASE + p)
    if st != 200:
        FEHLER.append(f"Seite nicht erreichbar: {BASE+p} (Status {st})"); continue
    OK.append(BASE + p)
    if p.endswith((".html", "/")):
        for href in re.findall(r'href="([^"#]+)"', body.decode("utf8", "ignore")):
            if href.startswith(("mailto:", "tel:", "javascript:", "data:")): continue
            u = urljoin(BASE + p, href)
            if u.startswith("http"): links.setdefault(u, BASE + p)
for u, q in links.items():
    pruefe_link(u, q)

# 2) Supabase (Server) erreichbar
st, body = hole(BASE + "/app/")
m = re.search(r"url:'(https://[a-z0-9]+\.supabase\.co)',anon:'([^']+)'", body.decode("utf8", "ignore"))
if not m:
    FEHLER.append("Server-Adresse in der App nicht gefunden")
else:
    req = urllib.request.Request(m.group(1) + "/auth/v1/settings", headers={"apikey": m.group(2)})
    try:
        with urllib.request.urlopen(req, timeout=20) as r: OK.append("Server (Supabase) antwortet")
    except Exception as e:
        FEHLER.append(f"Server (Supabase) antwortet nicht: {e}")

# 3) App im Browser: lädt ohne Fehler, Anmeldung + Knöpfe da, Rechtstexte öffnen
with sync_playwright() as p:
    b = p.chromium.launch()
    for name, vp in [("iPhone", {"width": 390, "height": 844}), ("Desktop", {"width": 1280, "height": 900})]:
        pg = b.new_page(viewport=vp); js = []
        pg.on("pageerror", lambda e: js.append(str(e)))
        try:
            pg.goto(BASE + "/app/?web=1", wait_until="networkidle", timeout=45000)
            pg.wait_for_selector("#login:not(.hide)", timeout=20000)
            for sel, was in [("#ae", "E-Mail-Feld"), ("#ap", "Passwort-Feld"), ('#login button:text-is("Anmelden")', "Knopf „Anmelden“")]:
                if pg.locator(sel).count() == 0: FEHLER.append(f"App ({name}): {was} fehlt")
            t = pg.inner_text("#login")
            for wort in ["Passwort vergessen", "Registrieren"]:
                if wort not in t: FEHLER.append(f"App ({name}): „{wort}“ fehlt auf der Anmeldeseite")
            # Falsches Passwort → verständliche Fehlermeldung (keine echte Anmeldung)
            pg.fill("#ae", "check-gibt-es-nicht@padel-run.de"); pg.fill("#ap", "falsch123456")
            pg.click('#login button:text-is("Anmelden")'); pg.wait_for_timeout(4000)
            if pg.locator("#login:not(.hide)").count() == 0: FEHLER.append(f"App ({name}): Anmeldung mit falschen Daten nicht abgelehnt")
            OK.append(f"App ({name}) lädt, Anmeldeseite vollständig")
        except Exception as e:
            FEHLER.append(f"App ({name}) lädt nicht richtig: {str(e)[:200]}")
        if js: FEHLER.append(f"App ({name}): JavaScript-Fehler: {js[:3]}")
        pg.close()
    # Startseite + QR-Weiterleitung
    pg = b.new_page(viewport={"width": 390, "height": 844}); js = []
    pg.on("pageerror", lambda e: js.append(str(e)))
    try:
        pg.goto(BASE + "/", wait_until="networkidle", timeout=45000)
        if js: FEHLER.append(f"Startseite: JavaScript-Fehler: {js[:3]}")
        pg.goto(BASE + "/laden/", wait_until="networkidle", timeout=45000); pg.wait_for_timeout(1500)
        OK.append(f"QR-Seite /laden führt zu: {pg.url}")
    except Exception as e:
        FEHLER.append(f"Startseite/QR-Seite lädt nicht: {str(e)[:200]}")
    b.close()

# Bericht
zeilen = ["# PadelRun – Täglicher Check", "",
          f"**{len(FEHLER)} Fehler · {len(WARN)} Warnungen · {len(OK)} OK**", ""]
if FEHLER: zeilen += ["## ❌ Fehler"] + [f"- {x}" for x in FEHLER] + [""]
if WARN: zeilen += ["## ⚠️ Warnungen"] + [f"- {x}" for x in WARN] + [""]
zeilen += ["<details><summary>✅ OK</summary>", ""] + [f"- {x}" for x in OK] + ["", "</details>"]
open("check_bericht.md", "w").write("\n".join(zeilen))
print("\n".join(zeilen))
sys.exit(1 if FEHLER else 0)
