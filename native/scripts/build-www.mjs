// Baut www/index.html aus padel-rangliste.html und trägt die Zugangsdaten aus app.config.json ein.
// Aufruf: npm run build   (ohne Zusatzpakete)
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cfgPath = join(root, "app.config.json");
if (!existsSync(cfgPath)) { console.error("Fehlt: app.config.json (Vorlage: app.config.example.json kopieren und ausfüllen)"); process.exit(1); }
const c = JSON.parse(readFileSync(cfgPath, "utf8"));
const src = join(root, "padel-rangliste.html");
let h = readFileSync(src, "utf8");
const bad = [];
if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(c.supabaseUrl || "")) bad.push("supabaseUrl");
if (!c.supabaseAnonKey || c.supabaseAnonKey.includes("...")) bad.push("supabaseAnonKey");
if (/service_role/.test(Buffer.from((c.supabaseAnonKey || "").split(".")[1] || "", "base64").toString())) { console.error("STOPP: Das ist der geheime service_role-Schlüssel. In die App gehört nur der anon-Schlüssel."); process.exit(1); }
// Start ohne Premium und ohne Werbung: RevenueCat- und AdMob-Angaben sind optional.
if (c.revenueCatIosKey && !/^appl_/.test(c.revenueCatIosKey)) bad.push("revenueCatIosKey");
if (c.admobBannerIos && !/^ca-app-pub-\d+\/\d+$/.test(c.admobBannerIos)) bad.push("admobBannerIos");
if (bad.length) { console.error("Bitte in app.config.json ausfüllen: " + bad.join(", ")); process.exit(1); }
const sub = (from, to) => { if (!h.includes(from)) { console.error("Nicht gefunden: " + from); process.exit(1); } h = h.replace(from, to); };
const q = (v) => JSON.stringify(v).replace(/"/g, "'");
sub("const SB={url:'',anon:''", `const SB={url:${q(c.supabaseUrl)},anon:${q(c.supabaseAnonKey)}`);
sub("const APPLE={clientId:''", `const APPLE={clientId:${q(c.appleClientId)}`);
if (c.revenueCatIosKey) sub("const BILLING={key:''", `const BILLING={key:${q(c.revenueCatIosKey)}`);
if (c.admobBannerIos) sub("bannerUnit:{ios:'ca-app-pub-3940256099942544/2934735716'},testing:true", `bannerUnit:{ios:${q(c.admobBannerIos)}},testing:${c.admobTesting ? "true" : "false"}`);
mkdirSync(join(root, "www"), { recursive: true });
writeFileSync(join(root, "www", "index.html"), h);
console.log("www/index.html gebaut");
