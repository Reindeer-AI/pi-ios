/**
 * flights: travel preferences in a panel, and flight search and booking through pi's browser.
 *
 * /flights opens the Flights app: home and destination airports (a search box that takes a city, an airport or its
 * code), dates, cabin class, passengers and currency. It is a pi app (pi.registerApp): closing it minimizes it to the
 * session's dock, and edits not saved yet are kept with it (pi.state), so it opens again as it was, even after a
 * relaunch. The agent reads them with flight_preferences, searches
 * Google Flights in the browser, recommends options, and books on the airline's site up to checkout, where it stops for
 * the user (Take control) to pay. The sheet also keeps the traveller's details, which the agent fills in on the
 * airline's form, and loyalty programs, of which the agent picks the one that earns on the airline it books.
 *
 * Saved preferences are kept in .pi-flights.json next to the session folders, so every session shares them.
 */
import { Type } from "@earendil-works/pi-ai";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

type Preferences = {
	from?: string;
	to?: string;
	depart?: string;
	return?: string;
	cabin: "economy" | "premium" | "business" | "first";
	adults: number;
	children: number;
	infants: number;
	currency: string;
	directOnly: boolean;
	passenger: { firstName: string; lastName: string; gender: "" | "male" | "female"; birthDate?: string; passport?: string };
	loyalty: { program: string; number: string }[];
};

const DEFAULTS: Preferences = {
	cabin: "economy",
	adults: 1,
	children: 0,
	infants: 0,
	currency: "EUR",
	directOnly: false,
	passenger: { firstName: "", lastName: "", gender: "" },
	loyalty: [],
};

// Sessions keep their own home folder (sessions/<id>); the folder above it is shared.
const file = () => join(dirname(homedir()), ".pi-flights.json");

function load(): Preferences | undefined {
	try {
		if (existsSync(file())) {
			const saved = JSON.parse(readFileSync(file(), "utf8"));
			return { ...DEFAULTS, ...saved, passenger: { ...DEFAULTS.passenger, ...saved.passenger }, loyalty: saved.loyalty ?? [] };
		}
	} catch {}
	return undefined;
}

function save(preferences: Preferences) {
	writeFileSync(file(), JSON.stringify(preferences, null, 2));
}

function describe(p: Preferences): string {
	const people = [`${p.adults} adult${p.adults === 1 ? "" : "s"}`];
	if (p.children) people.push(`${p.children} child${p.children === 1 ? "" : "ren"}`);
	if (p.infants) people.push(`${p.infants} infant${p.infants === 1 ? "" : "s"}`);
	return [
		`From: ${p.from ?? "not set"}`,
		`To: ${p.to ?? "not set (ask, or take it from the request)"}`,
		`Depart: ${p.depart ?? "flexible"}`,
		`Return: ${p.return ?? "flexible"}`,
		`Cabin: ${p.cabin}`,
		`Passengers: ${people.join(", ")}`,
		`Currency: ${p.currency}`,
		`Direct flights only: ${p.directOnly ? "yes" : "no"}`,
		`Passenger: ${[p.passenger.firstName, p.passenger.lastName].filter(Boolean).join(" ") || "not set"}${p.passenger.gender ? `, ${p.passenger.gender}` : ""}${p.passenger.birthDate ? `, born ${p.passenger.birthDate}` : ""}${p.passenger.passport ? `, passport ${p.passenger.passport}` : ""}`,
		`Loyalty programs: ${p.loyalty.length ? p.loyalty.map((l) => `${l.program} ${l.number}`).join("; ") : "none"}`,
	].join("\n");
}

export default function (pi: any) {
	// pi before apps (pi.registerApp): say so, rather than fail to load.
	if (typeof pi.registerApp !== "function") {
		pi.registerCommand("flights", {
			description: "The Flights app (needs a newer pi)",
			handler: async (_args: string, ctx: any) => ctx.ui.notify("The Flights app needs a newer pi: update pi, then try again.", "warning"),
		});
		return;
	}
	// Who waits for the user to save (flight_preferences with edit): the preferences, or undefined when they put the
	// app away without saving.
	let waiting: ((preferences: Preferences | undefined) => void)[] = [];
	const settle = (preferences?: Preferences) => {
		const each = waiting;
		waiting = [];
		for (const resolve of each) resolve(preferences);
	};

	pi.registerApp({
		name: "flights",
		title: "Flights",
		icon: "airplane",
		description: "The user's flight preferences: airports, dates, cabin, passengers, currency, traveller details and loyalty programs",
		// Edits not saved yet (the app's state), else the saved preferences.
		render: (app: any) => page((app.state as Preferences | null) ?? load() ?? DEFAULTS),
		onMessage: (data: any, app: any) => {
			if (data?.type !== "save") return;
			const saved = { ...DEFAULTS, ...data.preferences } as Preferences;
			save(saved);
			app.setState(null);
			app.post({ type: "saved" });
			app.ui.notify(`Flight preferences saved: ${saved.from ?? "?"} · ${saved.cabin} · ${saved.adults + saved.children + saved.infants} passenger(s) · ${saved.currency}`, "info");
			settle(saved);
		},
		onMinimize: () => settle(undefined),
		onClose: () => settle(undefined),
	});

	/** Opens the app for the user, and waits until they save (or put it away). */
	async function edit(): Promise<Preferences | undefined> {
		const saved = new Promise<Preferences | undefined>((resolve) => waiting.push(resolve));
		await pi.apps.open("flights");
		return saved;
	}

	pi.registerCommand("flights", {
		description: "Set your flight preferences: airports, dates, class, passengers, currency",
		handler: async () => {
			await pi.apps.open("flights");
		},
	});

	pi.registerTool({
		name: "flight_preferences",
		label: "Flight preferences",
		description:
			"The user's saved flight preferences: home airport, destination, dates, cabin class, passengers, currency, direct only, the traveller's details, and loyalty programs. Call it before searching for flights. With edit: true (or when none are saved) it opens the Flights app for the user and returns what they save. To just show the user the Flights app, use app_open instead.",
		parameters: Type.Object({ edit: Type.Optional(Type.Boolean({ description: "Open the Flights app for the user" })) }),
		async execute(_id: string, params: { edit?: boolean }) {
			let preferences = load();
			if (params.edit || !preferences) preferences = (await edit()) ?? preferences;
			const text = preferences ? describe(preferences) : "No preferences: the user put the Flights app away without saving. Ask them what they need.";
			return { content: [{ type: "text", text }], details: preferences ?? null };
		},
	});

	pi.on("before_agent_start", (event: { systemPrompt: string }) => ({
		systemPrompt: `${event.systemPrompt}\n\n${guidance()}`,
	}));
}

function guidance(): string {
	const today = new Date();
	const date = today.toISOString().slice(0, 10);
	const weekday = today.toLocaleDateString("en-US", { weekday: "long" });
	return `## Flights (flights extension)
Today is ${weekday}, ${date}. When the user wants to fly or travel somewhere:
1. Call flight_preferences first. Take the route and dates from the request and the preferences: the destination's main airport; "next week" means departing early next week and returning a few days later, unless the user says otherwise. Say in one line what you are searching for.
2. Search in the browser, on Google Flights, in the preferred currency and cabin, for example https://www.google.com/travel/flights?q=Flights%20from%20TLV%20to%20VIE%20on%202026-10-12%20returning%202026-10-15%20business%20class%201%20adult&curr=EUR&hl=en. Read the results (browser_read or browser_snapshot); scroll for more if needed.
3. Recommend two or three options, best overall first: airline, flight numbers if shown, times, stops, duration, and price. Keep it short.
4. When the user asks to book, book in the browser on the airline's own website (Google Flights' booking options link to it): the same flights, dates, cabin and passengers; pick the fare that matches the preferences; accept only necessary cookies; continue to the passenger details.
5. Fill in the traveller from the preferences, and only what they hold: title from gender (male: Mr, female: Ms), first and last name, date of birth and passport if saved. Loyalty: of the saved programs, use the one that earns on this airline (its own program, else one in its alliance or a partner: Star Alliance, oneworld, SkyTeam), and say which you chose and why; with none saved, leave the field empty.
6. Stop when the form asks for anything the preferences don't hold (email, phone, date of birth, passport...), and in any case before payment. Never enter payment details and never submit an order. Summarize what is in the cart, what you filled in, and the total, and tell the user to tap the browser card and Take control to finish. If a sign-in or CAPTCHA blocks you, ask the user to take control for it, then continue.`;
}

/** The app's page: Save sends the preferences (pi.post); edits not saved yet are kept with the app (pi.state). */
function page(current: Preferences): string {
	return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#f2f2f7;--card:#fff;--text:#111;--muted:#6b6b73;--line:#e3e3e8;--accent:#0a84ff;--chip:#eef0f4}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f2f2f7;--muted:#9a9aa2;--line:#2c2c2e;--chip:#2c2c2e}}
*{box-sizing:border-box}body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--text);padding:14px 16px 28px}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:18px 4px 6px}
.card{background:var(--card);border-radius:14px;padding:4px 14px}
.row{display:flex;align-items:center;gap:10px;min-height:48px;border-bottom:1px solid var(--line)}.row:last-child{border-bottom:0}
.row label{width:72px;color:var(--muted);font-size:15px;flex:none}
input[type=text],input[type=date]{flex:1;font:inherit;color:inherit;background:transparent;border:0;outline:0;min-width:0;padding:10px 0}
input[type=date]{-webkit-appearance:none;text-align:left}
.airport{position:relative;flex:1;display:flex;align-items:center}
.code{font-weight:700;color:var(--accent);margin-left:6px;font-size:15px}
.suggest{position:absolute;left:-86px;right:-14px;top:46px;background:var(--card);border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.18);z-index:5;overflow:hidden;display:none}
.suggest button{display:flex;width:100%;text-align:left;gap:10px;align-items:center;padding:11px 14px;border:0;border-bottom:1px solid var(--line);background:transparent;color:inherit;font:inherit}
.suggest button:last-child{border-bottom:0}.suggest b{width:40px;color:var(--accent)}.suggest small{display:block;color:var(--muted);font-size:13px}
.seg{display:flex;flex-wrap:wrap;gap:8px;padding:10px 0}
.seg button{border:0;border-radius:18px;padding:8px 14px;font:15px -apple-system,system-ui;background:var(--chip);color:var(--text)}
.seg button.on{background:var(--accent);color:#fff}
.step{display:flex;align-items:center;gap:12px;margin-left:auto}.step button{width:34px;height:34px;border-radius:17px;border:0;background:var(--chip);color:var(--text);font-size:20px}
.step span{min-width:18px;text-align:center;font-weight:600}
.toggle{margin-left:auto;width:51px;height:31px;border-radius:16px;background:var(--line);border:0;position:relative}
.toggle::after{content:"";position:absolute;top:2px;left:2px;width:27px;height:27px;border-radius:14px;background:#fff;transition:left .15s}
.toggle.on{background:#34c759}.toggle.on::after{left:22px}
.save{display:block;width:100%;margin-top:22px;padding:15px;border:0;border-radius:14px;background:var(--accent);color:#fff;font:600 17px -apple-system,system-ui}
.note{color:var(--muted);font-size:13px;margin:6px 4px 0}
.prog{display:flex;align-items:center;gap:8px;min-height:48px;border-bottom:1px solid var(--line)}
.prog select{flex:1.2;font:15px -apple-system,system-ui;color:inherit;background:transparent;border:0;min-width:0}
.prog input{flex:1;font:inherit;color:inherit;background:transparent;border:0;outline:0;min-width:0}
.prog .del{border:0;background:transparent;color:#ff3b30;font-size:20px}
.add{display:block;border:0;background:transparent;color:var(--accent);font:16px -apple-system,system-ui;padding:13px 0;width:100%;text-align:left}
.swap{border:0;background:var(--chip);color:var(--accent);border-radius:16px;width:32px;height:32px;font-size:16px;flex:none}
</style></head><body>
<h2>Route</h2>
<div class="card">
 <div class="row"><label>From</label><div class="airport"><input type="text" id="from" placeholder="City or airport" autocomplete="off" aria-label="From airport"><span class="code" id="fromCode"></span><div class="suggest" id="fromList"></div></div><button class="swap" id="swap" aria-label="Swap airports">⇅</button></div>
 <div class="row"><label>To</label><div class="airport"><input type="text" id="to" placeholder="Anywhere" autocomplete="off" aria-label="To airport"><span class="code" id="toCode"></span><div class="suggest" id="toList"></div></div></div>
</div>
<h2>Dates</h2>
<div class="card">
 <div class="row"><label>Depart</label><input type="date" id="depart" aria-label="Depart date"></div>
 <div class="row"><label>Return</label><input type="date" id="ret" aria-label="Return date"></div>
</div>
<h2>Class</h2>
<div class="card"><div class="seg" id="cabin">
 <button data-v="economy">Economy</button><button data-v="premium">Premium</button><button data-v="business">Business</button><button data-v="first">First</button>
</div></div>
<h2>Passengers</h2>
<div class="card">
 <div class="row"><label>Adults</label><div class="step" data-k="adults"><button aria-label="Fewer adults">−</button><span></span><button aria-label="More adults">+</button></div></div>
 <div class="row"><label>Children</label><div class="step" data-k="children"><button aria-label="Fewer children">−</button><span></span><button aria-label="More children">+</button></div></div>
 <div class="row"><label>Infants</label><div class="step" data-k="infants"><button aria-label="Fewer infants">−</button><span></span><button aria-label="More infants">+</button></div></div>
 <div class="row"><label style="width:auto">Direct flights only</label><button class="toggle" id="direct" role="switch" aria-checked="false" aria-label="Direct flights only"></button></div>
</div>
<h2>Currency</h2>
<div class="card"><div class="seg" id="currency">
 <button data-v="EUR">€ EUR</button><button data-v="USD">$ USD</button><button data-v="ILS">₪ ILS</button><button data-v="GBP">£ GBP</button><button data-v="CHF">CHF</button>
</div></div>
<h2>Passenger</h2>
<div class="card">
 <div class="row"><label>First</label><input type="text" id="first" placeholder="First name" autocomplete="off" autocapitalize="words" aria-label="First name"></div>
 <div class="row"><label>Last</label><input type="text" id="last" placeholder="Last name" autocomplete="off" autocapitalize="words" aria-label="Last name"></div>
 <div class="row"><label>Gender</label><div class="seg" id="gender" style="padding:6px 0"><button data-v="male">Male</button><button data-v="female">Female</button></div></div>
 <div class="row"><label>Born</label><input type="date" id="born" aria-label="Date of birth"></div>
 <div class="row"><label>Passport</label><input type="text" id="passport" placeholder="Optional" autocomplete="off" autocapitalize="characters" aria-label="Passport number"></div>
</div>
<h2>Loyalty programs</h2>
<div class="card" id="loyalty"></div>
<p class="note">The agent picks the program that earns on the airline it books.</p>
<button class="save" id="save">Save preferences</button>
<script>
const AIRPORTS = ${JSON.stringify(AIRPORTS)};
const state = ${JSON.stringify(current)};
const fold = s => s.normalize("NFD").replace(/[\\u0300-\\u036f]/g, "").toLowerCase();
const rows = AIRPORTS.map(([code, city, name, country, aliases]) => ({ code, city, name, country, keys: fold([code, city, name, country, aliases || ""].join(" ")) }));
function search(q) {
  q = fold(q.trim()); if (!q) return [];
  const words = q.split(/\\s+/);
  return rows.map(r => {
    if (!words.every(w => r.keys.includes(w))) return null;
    let score = 0;
    if (fold(r.code) === q) score += 100;
    if (fold(r.city).startsWith(q)) score += 50;
    if (fold(r.name).startsWith(q)) score += 30;
    if (r.keys.split(/\\s+/).some(k => k.startsWith(words[0]))) score += 10;
    return { r, score };
  }).filter(Boolean).sort((a, b) => b.score - a.score).slice(0, 6).map(x => x.r);
}
function label(code) { const r = rows.find(r => r.code === code); return r ? r.city + " · " + r.name : code || ""; }
function airport(key) {
  const input = document.getElementById(key), list = document.getElementById(key + "List"), code = document.getElementById(key + "Code");
  const show = () => { input.value = state[key] ? label(state[key]) : ""; code.textContent = state[key] || ""; };
  input.addEventListener("focus", () => { input.select(); });
  input.addEventListener("input", () => {
    const found = search(input.value);
    list.innerHTML = found.map(r => '<button data-c="' + r.code + '"><b>' + r.code + '</b><span>' + r.city + ', ' + r.country + '<small>' + r.name + '</small></span></button>').join("");
    list.style.display = found.length ? "block" : "none";
    code.textContent = "";
  });
  list.addEventListener("click", e => {
    const b = e.target.closest("button"); if (!b) return;
    state[key] = b.dataset.c; list.style.display = "none"; input.blur(); show();
  });
  input.addEventListener("blur", () => setTimeout(() => { list.style.display = "none"; show(); }, 200));
  show();
  return show;
}
const showFrom = airport("from"), showTo = airport("to");
document.getElementById("swap").onclick = () => { [state.from, state.to] = [state.to, state.from]; showFrom(); showTo(); };
const depart = document.getElementById("depart"), ret = document.getElementById("ret");
depart.value = state.depart || ""; ret.value = state["return"] || "";
depart.min = new Date().toISOString().slice(0, 10);
depart.onchange = () => { state.depart = depart.value || undefined; ret.min = depart.value; };
ret.onchange = () => { state["return"] = ret.value || undefined; };
function seg(id, key) {
  const el = document.getElementById(id);
  const paint = () => el.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.v === state[key]));
  el.onclick = e => { const b = e.target.closest("button"); if (b) { state[key] = b.dataset.v; paint(); } };
  paint();
}
seg("cabin", "cabin"); seg("currency", "currency");
document.querySelectorAll(".step").forEach(el => {
  const k = el.dataset.k, [minus, plus] = el.querySelectorAll("button"), out = el.querySelector("span");
  const min = k === "adults" ? 1 : 0, paint = () => { out.textContent = state[k]; minus.disabled = state[k] <= min; };
  minus.onclick = () => { if (state[k] > min) state[k]--; paint(); };
  plus.onclick = () => { if (state[k] < 9) state[k]++; paint(); };
  paint();
});
const direct = document.getElementById("direct");
const paintDirect = () => { direct.classList.toggle("on", !!state.directOnly); direct.setAttribute("aria-checked", String(!!state.directOnly)); };
direct.onclick = () => { state.directOnly = !state.directOnly; paintDirect(); }; paintDirect();
const PROGRAMS = ${JSON.stringify(PROGRAMS)};
const p = state.passenger;
for (const [id, key] of [["first", "firstName"], ["last", "lastName"], ["passport", "passport"]]) {
  const el = document.getElementById(id); el.value = p[key] || ""; el.oninput = () => { p[key] = el.value.trim(); };
}
const born = document.getElementById("born"); born.value = p.birthDate || ""; born.onchange = () => { p.birthDate = born.value || undefined; };
(() => {
  const el = document.getElementById("gender");
  const paint = () => el.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.v === p.gender));
  el.onclick = e => { const b = e.target.closest("button"); if (b) { p.gender = p.gender === b.dataset.v ? "" : b.dataset.v; paint(); } };
  paint();
})();
const loyalty = document.getElementById("loyalty");
function paintLoyalty() {
  loyalty.innerHTML = "";
  state.loyalty.forEach((entry, i) => {
    const row = document.createElement("div"); row.className = "prog";
    const select = document.createElement("select"); select.setAttribute("aria-label", "Program");
    select.innerHTML = PROGRAMS.map(([name, airline]) => '<option value="' + name + '">' + name + ' · ' + airline + '</option>').join("");
    select.value = entry.program; select.onchange = () => { entry.program = select.value; };
    const number = document.createElement("input"); number.placeholder = "Member number"; number.value = entry.number;
    number.setAttribute("aria-label", "Member number"); number.oninput = () => { entry.number = number.value.trim(); };
    const del = document.createElement("button"); del.className = "del"; del.textContent = "⊖"; del.setAttribute("aria-label", "Remove program");
    del.onclick = () => { state.loyalty.splice(i, 1); paintLoyalty(); };
    row.append(select, number, del); loyalty.append(row);
  });
  const add = document.createElement("button"); add.className = "add"; add.textContent = "＋ Add program";
  add.onclick = () => { state.loyalty.push({ program: PROGRAMS[0][0], number: "" }); paintLoyalty(); };
  loyalty.append(add);
}
paintLoyalty();
// Edits not saved yet stay with the app, so it opens again as it was (even after a relaunch).
let drafting;
const keepDraft = () => { clearTimeout(drafting); drafting = setTimeout(() => pi.state.set(state), 300); };
for (const type of ["input", "change", "click"]) document.addEventListener(type, keepDraft, true);
const saveButton = document.getElementById("save");
saveButton.onclick = () => {
  clearTimeout(drafting);
  state.loyalty = state.loyalty.filter(l => l.number);
  pi.post({ type: "save", preferences: state });
};
pi.onMessage(message => {
  if (message.type !== "saved") return;
  saveButton.textContent = "Saved ✓";
  setTimeout(() => { saveButton.textContent = "Save preferences"; pi.minimize(); }, 700);
});
</script></body></html>`;
}

/** [program, airline (alliance)]: frequent-flyer programs to choose from. */
const PROGRAMS: [string, string][] = [
	["Miles & More", "Lufthansa, Austrian, SWISS, Brussels (Star Alliance)"],
	["Matmid", "El Al"],
	["Flying Blue", "Air France, KLM (SkyTeam)"],
	["Executive Club (Avios)", "British Airways (oneworld)"],
	["Iberia Plus (Avios)", "Iberia (oneworld)"],
	["AAdvantage", "American (oneworld)"],
	["MileagePlus", "United (Star Alliance)"],
	["SkyMiles", "Delta (SkyTeam)"],
	["Aeroplan", "Air Canada (Star Alliance)"],
	["Miles&Smiles", "Turkish Airlines (Star Alliance)"],
	["Privilege Club (Avios)", "Qatar Airways (oneworld)"],
	["Skywards", "Emirates"],
	["Etihad Guest", "Etihad"],
	["KrisFlyer", "Singapore Airlines (Star Alliance)"],
	["Aegean Miles+Bonus", "Aegean (Star Alliance)"],
	["Miles+Smiles LOT", "LOT Polish (Star Alliance)"],
	["Wizz Discount Club", "Wizz Air"],
];

/** [code, city, airport, country, other names]: major airports, and city codes for cities with several. */
const AIRPORTS: [string, string, string, string, string?][] = [
	["TLV", "Tel Aviv", "Ben Gurion", "Israel", "Lod Jaffa Yafo"],
	["ETM", "Eilat", "Ramon", "Israel"],
	["HFA", "Haifa", "Haifa", "Israel"],
	["VIE", "Vienna", "Vienna International (Schwechat)", "Austria", "Wien Schwechat"],
	["SZG", "Salzburg", "W. A. Mozart", "Austria"],
	["INN", "Innsbruck", "Kranebitten", "Austria"],
	["GRZ", "Graz", "Graz", "Austria"],
	["LON", "London", "All airports", "United Kingdom", "UK England"],
	["LHR", "London", "Heathrow", "United Kingdom", "UK England"],
	["LGW", "London", "Gatwick", "United Kingdom", "UK England"],
	["STN", "London", "Stansted", "United Kingdom", "UK England"],
	["LTN", "London", "Luton", "United Kingdom", "UK England"],
	["LCY", "London", "City", "United Kingdom", "UK England"],
	["MAN", "Manchester", "Manchester", "United Kingdom", "UK England"],
	["EDI", "Edinburgh", "Edinburgh", "United Kingdom", "UK Scotland"],
	["DUB", "Dublin", "Dublin", "Ireland"],
	["PAR", "Paris", "All airports", "France"],
	["CDG", "Paris", "Charles de Gaulle", "France", "Roissy"],
	["ORY", "Paris", "Orly", "France"],
	["NCE", "Nice", "Côte d'Azur", "France"],
	["LYS", "Lyon", "Saint-Exupéry", "France"],
	["MRS", "Marseille", "Provence", "France"],
	["AMS", "Amsterdam", "Schiphol", "Netherlands", "Holland"],
	["BRU", "Brussels", "Brussels", "Belgium", "Bruxelles Brussel"],
	["FRA", "Frankfurt", "Frankfurt am Main", "Germany", "Deutschland"],
	["MUC", "Munich", "Franz Josef Strauss", "Germany", "München Muenchen Deutschland"],
	["BER", "Berlin", "Brandenburg", "Germany", "Deutschland"],
	["HAM", "Hamburg", "Hamburg", "Germany", "Deutschland"],
	["DUS", "Düsseldorf", "Düsseldorf", "Germany", "Duesseldorf Deutschland"],
	["CGN", "Cologne", "Cologne Bonn", "Germany", "Köln Koeln Deutschland"],
	["STR", "Stuttgart", "Stuttgart", "Germany", "Deutschland"],
	["ZRH", "Zurich", "Zurich", "Switzerland", "Zürich Kloten Schweiz"],
	["GVA", "Geneva", "Geneva", "Switzerland", "Genève Genf"],
	["BSL", "Basel", "EuroAirport Basel Mulhouse", "Switzerland"],
	["MIL", "Milan", "All airports", "Italy", "Milano"],
	["MXP", "Milan", "Malpensa", "Italy", "Milano"],
	["LIN", "Milan", "Linate", "Italy", "Milano"],
	["ROM", "Rome", "All airports", "Italy", "Roma"],
	["FCO", "Rome", "Fiumicino (Leonardo da Vinci)", "Italy", "Roma"],
	["VCE", "Venice", "Marco Polo", "Italy", "Venezia"],
	["NAP", "Naples", "Capodichino", "Italy", "Napoli"],
	["BCN", "Barcelona", "El Prat", "Spain", "España"],
	["MAD", "Madrid", "Barajas", "Spain", "España"],
	["AGP", "Málaga", "Costa del Sol", "Spain", "Malaga"],
	["PMI", "Palma de Mallorca", "Palma", "Spain", "Majorca"],
	["LIS", "Lisbon", "Humberto Delgado", "Portugal", "Lisboa"],
	["OPO", "Porto", "Francisco Sá Carneiro", "Portugal"],
	["CPH", "Copenhagen", "Kastrup", "Denmark", "København"],
	["ARN", "Stockholm", "Arlanda", "Sweden"],
	["OSL", "Oslo", "Gardermoen", "Norway"],
	["HEL", "Helsinki", "Vantaa", "Finland"],
	["PRG", "Prague", "Václav Havel", "Czechia", "Praha Czech Republic"],
	["BUD", "Budapest", "Ferenc Liszt", "Hungary"],
	["WAW", "Warsaw", "Chopin", "Poland", "Warszawa"],
	["KRK", "Kraków", "John Paul II", "Poland", "Krakow Cracow"],
	["OTP", "Bucharest", "Henri Coandă", "Romania"],
	["SOF", "Sofia", "Sofia", "Bulgaria"],
	["BEG", "Belgrade", "Nikola Tesla", "Serbia"],
	["ZAG", "Zagreb", "Franjo Tuđman", "Croatia"],
	["LJU", "Ljubljana", "Jože Pučnik", "Slovenia"],
	["ATH", "Athens", "Eleftherios Venizelos", "Greece", "Athina"],
	["SKG", "Thessaloniki", "Macedonia", "Greece"],
	["HER", "Heraklion", "Nikos Kazantzakis", "Greece", "Crete"],
	["RHO", "Rhodes", "Diagoras", "Greece"],
	["LCA", "Larnaca", "Larnaca", "Cyprus"],
	["PFO", "Paphos", "Paphos", "Cyprus"],
	["IST", "Istanbul", "Istanbul", "Türkiye", "Turkey"],
	["SAW", "Istanbul", "Sabiha Gökçen", "Türkiye", "Turkey"],
	["AYT", "Antalya", "Antalya", "Türkiye", "Turkey"],
	["AMM", "Amman", "Queen Alia", "Jordan"],
	["CAI", "Cairo", "Cairo", "Egypt"],
	["DXB", "Dubai", "Dubai International", "United Arab Emirates", "UAE"],
	["AUH", "Abu Dhabi", "Zayed International", "United Arab Emirates", "UAE"],
	["DOH", "Doha", "Hamad", "Qatar"],
	["BAH", "Manama", "Bahrain", "Bahrain"],
	["RUH", "Riyadh", "King Khalid", "Saudi Arabia"],
	["JED", "Jeddah", "King Abdulaziz", "Saudi Arabia"],
	["RAK", "Marrakesh", "Menara", "Morocco", "Marrakech"],
	["CMN", "Casablanca", "Mohammed V", "Morocco"],
	["NYC", "New York", "All airports", "United States", "USA NY"],
	["JFK", "New York", "John F. Kennedy", "United States", "USA NY"],
	["EWR", "Newark", "Newark Liberty (New York)", "United States", "USA NJ New York"],
	["LGA", "New York", "LaGuardia", "United States", "USA NY"],
	["BOS", "Boston", "Logan", "United States", "USA"],
	["WAS", "Washington", "All airports", "United States", "USA DC"],
	["IAD", "Washington", "Dulles", "United States", "USA DC"],
	["DCA", "Washington", "Reagan National", "United States", "USA DC"],
	["MIA", "Miami", "Miami", "United States", "USA Florida"],
	["MCO", "Orlando", "Orlando", "United States", "USA Florida"],
	["ATL", "Atlanta", "Hartsfield-Jackson", "United States", "USA"],
	["ORD", "Chicago", "O'Hare", "United States", "USA"],
	["DFW", "Dallas", "Dallas/Fort Worth", "United States", "USA Texas"],
	["IAH", "Houston", "George Bush", "United States", "USA Texas"],
	["DEN", "Denver", "Denver", "United States", "USA"],
	["SEA", "Seattle", "Seattle-Tacoma", "United States", "USA"],
	["SFO", "San Francisco", "San Francisco", "United States", "USA California Bay Area"],
	["SJC", "San Jose", "Mineta San José", "United States", "USA California Bay Area"],
	["LAX", "Los Angeles", "Los Angeles", "United States", "USA California"],
	["LAS", "Las Vegas", "Harry Reid", "United States", "USA"],
	["YYZ", "Toronto", "Pearson", "Canada"],
	["YVR", "Vancouver", "Vancouver", "Canada"],
	["YUL", "Montreal", "Trudeau", "Canada", "Montréal"],
	["MEX", "Mexico City", "Benito Juárez", "Mexico", "Ciudad de México"],
	["CUN", "Cancún", "Cancún", "Mexico", "Cancun"],
	["GRU", "São Paulo", "Guarulhos", "Brazil", "Sao Paulo"],
	["GIG", "Rio de Janeiro", "Galeão", "Brazil"],
	["EZE", "Buenos Aires", "Ezeiza", "Argentina"],
	["BOG", "Bogotá", "El Dorado", "Colombia", "Bogota"],
	["LIM", "Lima", "Jorge Chávez", "Peru"],
	["JNB", "Johannesburg", "O. R. Tambo", "South Africa"],
	["CPT", "Cape Town", "Cape Town", "South Africa"],
	["NBO", "Nairobi", "Jomo Kenyatta", "Kenya"],
	["ADD", "Addis Ababa", "Bole", "Ethiopia"],
	["BOM", "Mumbai", "Chhatrapati Shivaji", "India", "Bombay"],
	["DEL", "Delhi", "Indira Gandhi", "India", "New Delhi"],
	["BLR", "Bengaluru", "Kempegowda", "India", "Bangalore"],
	["BKK", "Bangkok", "Suvarnabhumi", "Thailand"],
	["HKT", "Phuket", "Phuket", "Thailand"],
	["SIN", "Singapore", "Changi", "Singapore"],
	["KUL", "Kuala Lumpur", "Kuala Lumpur", "Malaysia"],
	["HKG", "Hong Kong", "Hong Kong", "Hong Kong"],
	["TPE", "Taipei", "Taoyuan", "Taiwan"],
	["PEK", "Beijing", "Capital", "China"],
	["PVG", "Shanghai", "Pudong", "China"],
	["ICN", "Seoul", "Incheon", "South Korea", "Korea"],
	["TYO", "Tokyo", "All airports", "Japan"],
	["HND", "Tokyo", "Haneda", "Japan"],
	["NRT", "Tokyo", "Narita", "Japan"],
	["KIX", "Osaka", "Kansai", "Japan"],
	["SYD", "Sydney", "Kingsford Smith", "Australia"],
	["MEL", "Melbourne", "Tullamarine", "Australia"],
	["AKL", "Auckland", "Auckland", "New Zealand"],
];
