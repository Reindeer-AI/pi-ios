/**
 * personal-details: the user's documents and details, for filling forms: passports, cards, ID cards, driver's
 * licenses, social security numbers, addresses (home, work, …), cars, and other information (named entries of any fields:
 * a gym membership, health insurance), whose fields the user may lock into the vault.
 *
 * It is a pi app (pi.registerApp, "Personal details"): a list by kind, and a form for each entry. What isn't sensitive
 * (names, dates, addresses, a car's make and plate) is kept in pi.synced (on all the user's devices; .pi-personal.json
 * next to the session folders on a pi without it), so
 * every session shares it. The sensitive numbers (card number and security code; passport, ID, license and social
 * security numbers) go to pi's vault (pi.vault): the user types them into pi's own secure sheet, which this extension
 * never sees, and they come out only after the user's consent and Face ID. Each entry's name ("My passport", "Chase
 * Sapphire Preferred", "Home") is public, so the user can say "fill in my passport" or "pay with my Chase card".
 *
 * The agent reads everything with personal_details (the public details, and for each sensitive number its vault item
 * and field), types the public details into a page, and fills the numbers with browser_fill_from_vault, which it never
 * sees. personal_details_open opens the app, optionally on a new entry of a kind.
 */
import { Type } from "@earendil-works/pi-ai";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

type Kind = "passport" | "card" | "id" | "license" | "ssn" | "address" | "car" | "info";
type Field = { key: string; label: string; placeholder?: string; input?: "date" | "sex" | "addressKind" };
type Entry = {
	id: string;
	kind: Kind;
	/** Public: the user names it ("My passport", "Chase Sapphire Preferred", "Home"). */
	label: string;
	details: Record<string, string>;
	/** The vault item with its sensitive numbers, and its hint ("Visa •• 4242"). */
	vaultId?: string;
	hint?: string;
	/** Other information: the names of its fields kept in the vault (the rest are in `details`, in order). */
	secureKeys?: string[];
};

const KINDS: {
	kind: Kind;
	title: string;
	plural: string;
	label: string;
	fields: Field[];
	secure?: { title: string; fields: { key: string; label: string; placeholder?: string }[] };
	/** Fields the user names (other information). */
	custom?: boolean;
}[] = [
	{
		kind: "passport",
		title: "Passport",
		plural: "Passports",
		label: "My passport",
		fields: [
			{ key: "fullName", label: "Full name", placeholder: "As in the passport" },
			{ key: "nationality", label: "Nationality" },
			{ key: "birthDate", label: "Date of birth", input: "date" },
			{ key: "sex", label: "Sex", input: "sex" },
			{ key: "issuingCountry", label: "Issued by" },
			{ key: "issueDate", label: "Issued", input: "date" },
			{ key: "expiryDate", label: "Expires", input: "date" },
		],
		secure: { title: "Passport number", fields: [{ key: "number", label: "Passport number" }] },
	},
	{
		kind: "card",
		title: "Card",
		plural: "Cards",
		label: "My card",
		fields: [
			{ key: "nameOnCard", label: "Name on card" },
			{ key: "expiry", label: "Expires", placeholder: "MM/YY" },
			{ key: "billingAddress", label: "Billing address", placeholder: "Home, Work, or the address" },
		],
		secure: {
			title: "Card number and security code",
			fields: [
				{ key: "number", label: "Card number", placeholder: "4242 4242 4242 4242" },
				{ key: "cvv", label: "Security code", placeholder: "123" },
			],
		},
	},
	{
		kind: "id",
		title: "ID card",
		plural: "ID cards",
		label: "ID card",
		fields: [
			{ key: "fullName", label: "Full name" },
			{ key: "country", label: "Country" },
			{ key: "birthDate", label: "Date of birth", input: "date" },
			{ key: "expiryDate", label: "Expires", input: "date" },
		],
		secure: { title: "ID number", fields: [{ key: "number", label: "ID number" }] },
	},
	{
		kind: "license",
		title: "Driver's license",
		plural: "Driver's licenses",
		label: "Driver's license",
		fields: [
			{ key: "fullName", label: "Full name" },
			{ key: "country", label: "Country" },
			{ key: "region", label: "State or region" },
			{ key: "class", label: "Class", placeholder: "B, C, …" },
			{ key: "issueDate", label: "Issued", input: "date" },
			{ key: "expiryDate", label: "Expires", input: "date" },
		],
		secure: { title: "License number", fields: [{ key: "number", label: "License number" }] },
	},
	{
		kind: "ssn",
		title: "Social security number",
		plural: "Social security",
		label: "SSN",
		fields: [{ key: "fullName", label: "Full name" }],
		secure: { title: "Social security number", fields: [{ key: "number", label: "SSN", placeholder: "123-45-6789" }] },
	},
	{
		kind: "address",
		title: "Address",
		plural: "Addresses",
		label: "Home",
		fields: [
			{ key: "name", label: "Name" },
			{ key: "line1", label: "Street" },
			{ key: "line2", label: "Apartment, suite" },
			{ key: "city", label: "City" },
			{ key: "region", label: "State or region" },
			{ key: "postalCode", label: "Postal code" },
			{ key: "country", label: "Country" },
			{ key: "phone", label: "Phone" },
			{ key: "email", label: "Email" },
		],
	},
	{
		kind: "car",
		title: "Car",
		plural: "Cars",
		label: "My car",
		fields: [
			{ key: "make", label: "Make", placeholder: "Toyota" },
			{ key: "model", label: "Model", placeholder: "Corolla" },
			{ key: "year", label: "Year" },
			{ key: "color", label: "Color" },
			{ key: "plate", label: "License plate" },
			{ key: "vin", label: "VIN", placeholder: "Optional" },
		],
	},
	{ kind: "info", title: "Other information", plural: "Other information", label: "Info", fields: [], custom: true },
];
const kindOf = (kind: Kind) => KINDS.find((each) => each.kind === kind)!;
const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);

/** An entry's fields in the vault, with keys that fit a vault field (member_number for "Member number"). */
function secureFields(entry: Entry): { key: string; label: string }[] {
	if (!kindOf(entry.kind).custom) return kindOf(entry.kind).secure?.fields ?? [];
	const taken = new Set<string>();
	return (entry.secureKeys ?? []).map((label) => {
		const base = label.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "") || "value";
		let key = base;
		for (let n = 2; taken.has(key); n++) key = `${base}_${n}`;
		taken.add(key);
		return { key, label };
	});
}

// Sessions keep their own home folder (sessions/<id>); the folder above it is shared. On a pi with pi.synced, entries
// follow the user to their other devices instead (each under its own key, so devices merge them); the file moves there
// once, and stays as a copy.
const file = () => join(dirname(homedir()), ".pi-personal.json");

function readFile(): Entry[] {
	try {
		if (existsSync(file())) return JSON.parse(readFileSync(file(), "utf8")).entries ?? [];
	} catch {}
	return [];
}

let synced: { get(key: string): unknown; set(key: string, value: unknown): void; delete(key: string): void; keys(): string[] } | undefined;

function load(): Entry[] {
	if (!synced) return readFile();
	const keys = synced.keys().filter((key) => key.startsWith("entry:"));
	if (keys.length === 0 && !synced.get("migrated")) {
		// The first time: the entries kept here before.
		for (const entry of readFile()) synced.set(`entry:${entry.id}`, entry);
		synced.set("migrated", true);
		return load();
	}
	return keys.map((key) => synced!.get(key) as Entry).filter(Boolean).sort((a, b) => (a.id < b.id ? -1 : 1));
}

function save(entries: Entry[]) {
	if (synced) {
		const kept = new Set(entries.map((entry) => `entry:${entry.id}`));
		for (const key of synced.keys()) if (key.startsWith("entry:") && !kept.has(key)) synced.delete(key);
		for (const entry of entries) synced.set(`entry:${entry.id}`, entry);
	}
	writeFileSync(file(), JSON.stringify({ entries }, null, 2));
}

/** One line of what an entry is, without anything sensitive. */
function summary(entry: Entry): string {
	const d = entry.details;
	switch (entry.kind) {
		case "card":
			return [entry.hint, d.expiry && `expires ${d.expiry}`].filter(Boolean).join(" · ");
		case "address":
			return [d.line1, d.city, d.country].filter(Boolean).join(", ");
		case "car":
			return [[d.year, d.make, d.model].filter(Boolean).join(" "), d.plate].filter(Boolean).join(" · ");
		case "info": {
			const locked = entry.secureKeys?.length ?? 0;
			return [...Object.entries(d).slice(0, 2).map(([key, value]) => `${key}: ${value}`), locked ? `${locked} in the vault` : ""].filter(Boolean).join(" · ");
		}
		default:
			return [entry.hint, d.expiryDate && `expires ${d.expiryDate}`].filter(Boolean).join(" · ");
	}
}

export default function (pi: any) {
	// pi before apps and the vault: say so, rather than fail to load.
	if (typeof pi.registerApp !== "function" || !pi.vault) {
		pi.registerCommand("personal", {
			description: "Personal details (needs a newer pi)",
			handler: async (_args: string, ctx: any) => ctx.ui.notify("Personal details needs a newer pi: update pi, then try again.", "warning"),
		});
		return;
	}

	synced = pi.synced;
	let entries = load();
	const find = (id: string) => entries.find((entry) => entry.id === id);
	const publish = (app: any) => app.post({ type: "entries", entries });

	/** Names and hints from the vault (an item the user deleted in Settings drops its link). */
	async function syncVault() {
		const items: { id: string; hint: string }[] = await pi.vault.list().catch(() => []);
		const byId = new Map(items.map((item) => [item.id, item]));
		let changed = false;
		for (const entry of entries) {
			if (!entry.vaultId) continue;
			const item = byId.get(entry.vaultId);
			if (!item) {
				delete entry.vaultId;
				delete entry.hint;
				changed = true;
			} else if (item.hint !== entry.hint) {
				entry.hint = item.hint;
				changed = true;
			}
		}
		if (changed) save(entries);
	}

	/** pi's secure sheet for an entry's sensitive numbers (new, or replacing them). */
	async function secure(entry: Entry) {
		const fields = secureFields(entry);
		if (fields.length === 0) return;
		const ask = (id?: string) => pi.vault.add({ kind: entry.kind, label: entry.label, fields, ...(id ? { id } : {}) });
		const item = await ask(entry.vaultId).catch(() => ask());
		if (item) {
			entry.vaultId = item.id;
			entry.hint = item.hint;
		}
	}

	pi.registerApp({
		name: "personal",
		title: "Personal details",
		icon: "person.crop.rectangle.stack",
		description: "The user's passports, cards, ID cards, driver's licenses, social security numbers, addresses and cars; sensitive numbers in the vault",
		render: async () => {
			await syncVault();
			return page(entries);
		},
		onMessage: async (data: any, app: any) => {
			switch (data?.type) {
				case "save": {
					const incoming = data.entry as Entry;
					const existing = find(incoming.id);
					// Other information: a changed set of locked fields is entered again.
					const relocked = JSON.stringify(existing?.secureKeys ?? []) !== JSON.stringify(incoming.secureKeys ?? []);
					const entry: Entry = existing
						? Object.assign(existing, { label: incoming.label, details: incoming.details, secureKeys: incoming.secureKeys })
						: { id: incoming.id || newId(), kind: incoming.kind, label: incoming.label, details: incoming.details, secureKeys: incoming.secureKeys };
					if (!existing) entries.push(entry);
					if (kindOf(entry.kind).custom && !entry.secureKeys?.length) {
						if (entry.vaultId) await pi.vault.delete(entry.vaultId).catch(() => {});
						delete entry.vaultId;
						delete entry.hint;
					} else if (entry.vaultId && !(kindOf(entry.kind).custom && relocked)) {
						await pi.vault.set({ id: entry.vaultId, label: entry.label }).catch(() => {});
					} else await secure(entry);
					save(entries);
					publish(app);
					break;
				}
				case "secure": {
					const entry = find(data.id);
					if (!entry) break;
					await secure(entry);
					save(entries);
					publish(app);
					break;
				}
				case "delete": {
					const entry = find(data.id);
					if (!entry) break;
					if (entry.vaultId) await pi.vault.delete(entry.vaultId).catch(() => {});
					entries = entries.filter((each) => each.id !== data.id);
					save(entries);
					publish(app);
					break;
				}
			}
		},
	});

	pi.registerCommand("personal", {
		description: "Your passports, cards, IDs, licenses, addresses and cars, for filling forms",
		handler: async () => {
			await pi.apps.open("personal");
		},
	});

	pi.registerTool({
		name: "personal_details",
		label: "Personal details",
		description:
			"The user's saved personal details, by name: passports, cards, ID cards, driver's licenses, social security numbers, addresses (home, work, …), cars, and other information (named entries of any fields, such as a gym membership). Gives each entry's public details, and for each value in the vault (card number, security code, document numbers, locked fields) the vault item and field to fill it with browser_fill_from_vault; those values are never shown.",
		parameters: Type.Object({
			kind: Type.Optional(Type.String({ description: "Only this kind: passport, card, id, license, ssn, address, car, info" })),
		}),
		async execute(_id: string, params: { kind?: string }) {
			await syncVault();
			const chosen = entries.filter((entry) => !params.kind || entry.kind === params.kind);
			if (chosen.length === 0) {
				return { content: [{ type: "text", text: "Nothing saved yet. The user can add details in the Personal details app (personal_details_open)." }], details: null };
			}
			const lines = chosen.map((entry) => {
				const kind = kindOf(entry.kind);
				const details = kind.custom
					? Object.entries(entry.details).map(([key, value]) => `${key}: ${value}`)
					: kind.fields.filter((field) => entry.details[field.key]).map((field) => `${field.label}: ${entry.details[field.key]}`);
				const locked = secureFields(entry);
				const secure = locked.length
					? entry.vaultId
						? locked.map((field) => `${field.label}: in the vault (item ${entry.vaultId}, field ${field.key})`)
						: [`${kind.secure?.title ?? locked.map((field) => field.label).join(", ")}: not entered yet`]
					: [];
				return `- ${kind.title} "${entry.label}"${entry.hint ? ` (${entry.hint})` : ""}\n  ${[...details, ...secure].join("\n  ")}`;
			});
			return { content: [{ type: "text", text: lines.join("\n") }], details: null };
		},
	});

	pi.registerTool({
		name: "personal_details_open",
		label: "Open Personal details",
		description: "Open the Personal details app for the user, optionally on a new entry of a kind (\"add my passport\"): passport, card, id, license, ssn, address, car, info.",
		parameters: Type.Object({ add: Type.Optional(Type.String({ description: "Start a new entry of this kind" })) }),
		async execute(_id: string, params: { add?: string }) {
			const app = await pi.apps.open("personal");
			if (params.add && KINDS.some((kind) => kind.kind === params.add)) app.post({ type: "add", kind: params.add });
			return { content: [{ type: "text", text: params.add ? `The Personal details app is open on a new ${kindOf(params.add as Kind).title}.` : "The Personal details app is open." }], details: null };
		},
	});

	pi.on("before_agent_start", (event: { systemPrompt: string }) => ({
		systemPrompt: `${event.systemPrompt}\n\n## Personal details (personal-details extension)\nThe user's passports, cards, ID cards, driver's licenses, social security numbers, addresses and cars are in the Personal details app, by name ("my passport", "my Chase card", "work address"). To fill a form, call personal_details, type the public details with browser_type, and fill each sensitive number with browser_fill_from_vault (its vault item and field), which the user approves with Face ID. Never ask the user to type such numbers in the chat. To save a new one, open the app with personal_details_open (add: the kind).`,
	}));
}

/** The app's page: entries by kind, and a form for one (sensitive numbers go to pi's secure sheet). */
function page(entries: Entry[]): string {
	return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#f2f2f7;--card:#fff;--text:#111;--muted:#6b6b73;--line:#e3e3e8;--accent:#0a84ff;--red:#ff3b30}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f2f2f7;--muted:#9a9aa2;--line:#2c2c2e}}
*{box-sizing:border-box}body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--text);padding:12px 16px 32px}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:20px 4px 6px}
.card{background:var(--card);border-radius:14px;overflow:hidden}
.row{display:flex;align-items:center;gap:12px;min-height:52px;padding:8px 14px;border-bottom:1px solid var(--line);width:100%;background:none;border-left:0;border-right:0;border-top:0;font:inherit;color:inherit;text-align:left}
.row:last-child{border-bottom:0}.row .t{flex:1;min-width:0}.row .t b{display:block;font-weight:500}.row .t small{display:block;color:var(--muted);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.chev{color:var(--muted)}.icon{width:28px;text-align:center;font-size:20px}
.add{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}.add button{font:inherit;font-size:15px;border:0;border-radius:18px;padding:8px 14px;background:var(--card);color:var(--accent)}
.empty{color:var(--muted);text-align:center;padding:28px 12px}
label.f{display:flex;align-items:center;gap:10px;min-height:48px;padding:0 14px;border-bottom:1px solid var(--line)}label.f:last-child{border-bottom:0}
label.f span{width:118px;color:var(--muted);font-size:15px;flex:none}label.f input,label.f select{flex:1;min-width:0;font:inherit;color:inherit;background:transparent;border:0;outline:0;padding:12px 0}
.secure{display:flex;align-items:center;gap:12px;padding:12px 14px}.secure .t{flex:1}.secure small{display:block;color:var(--muted);font-size:13px}
.btn{font:inherit;border:0;border-radius:12px;padding:12px;background:var(--accent);color:#fff;width:100%;margin-top:18px;font-weight:600}
.link{font:inherit;border:0;background:none;color:var(--accent);padding:6px 0}.danger{color:var(--red)}
.top{display:flex;justify-content:space-between;align-items:center}
.kv{display:flex;align-items:center;gap:8px;padding:6px 10px 6px 14px;border-bottom:1px solid var(--line)}.kv:last-child{border-bottom:0}
.kv input{flex:1;min-width:0;font:inherit;color:inherit;background:transparent;border:0;outline:0;padding:10px 0}.kv input.k{flex:.8;color:var(--muted)}
.kv input:disabled{color:var(--muted)}.kv button{font:inherit;border:0;background:none;padding:6px;font-size:18px}.addrow{font:inherit;border:0;background:none;color:var(--accent);padding:12px 14px;text-align:left;width:100%}
</style></head><body><div id="root"></div>
<script>
const KINDS = ${JSON.stringify(KINDS)};
const ICONS = { passport: "🛂", card: "💳", id: "🪪", license: "🚗", ssn: "🔢", address: "🏠", car: "🚙", info: "🗂️" };
let entries = ${JSON.stringify(entries)};
let editing = null;
let deleting = false;
const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
const kindOf = (kind) => KINDS.find((k) => k.kind === kind);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
function summary(e) {
  const d = e.details || {};
  if (e.kind === "card") return [e.hint, d.expiry && "expires " + d.expiry].filter(Boolean).join(" · ");
  if (e.kind === "address") return [d.line1, d.city, d.country].filter(Boolean).join(", ");
  if (e.kind === "car") return [[d.year, d.make, d.model].filter(Boolean).join(" "), d.plate].filter(Boolean).join(" · ");
  if (e.kind === "info") { const n = (e.secureKeys || []).length; return [...Object.entries(d).slice(0, 2).map(([k, v]) => k + ": " + v), n ? n + " in the vault" : ""].filter(Boolean).join(" · "); }
  return [e.hint, d.expiryDate && "expires " + d.expiryDate].filter(Boolean).join(" · ");
}
function list() {
  let html = "";
  for (const k of KINDS) {
    const mine = entries.filter((e) => e.kind === k.kind);
    if (!mine.length) continue;
    html += "<h2>" + esc(k.plural) + "</h2><div class=card>" + mine.map((e) =>
      '<button class=row data-edit="' + e.id + '"><span class=icon>' + ICONS[e.kind] + '</span><span class=t><b>' + esc(e.label) + "</b><small>" +
      esc(summary(e) || (k.secure && !e.vaultId ? k.secure.title + " not entered" : "")) + '</small></span><span class=chev>›</span></button>').join("") + "</div>";
  }
  if (!entries.length) html += '<div class=empty>Save your passport, cards, IDs, addresses and cars here, so pi can fill forms for you. Card and document numbers go to the vault, behind Face ID.</div>';
  html += "<h2>Add</h2><div class=add>" + KINDS.map((k) => '<button data-add="' + k.kind + '">' + ICONS[k.kind] + " " + esc(k.title) + "</button>").join("") + "</div>";
  return html;
}
function form() {
  const k = kindOf(editing.kind);
  const input = (f) => {
    const v = esc(editing.details[f.key] || "");
    if (f.input === "sex") return '<select data-field="' + f.key + '"><option value=""></option>' + ["F", "M", "X"].map((o) => "<option" + (editing.details[f.key] === o ? " selected" : "") + ">" + o + "</option>").join("") + "</select>";
    return '<input data-field="' + f.key + '" value="' + v + '" placeholder="' + esc(f.placeholder || "") + '"' + (f.input === "date" ? ' type="date"' : "") + ' autocomplete="off">';
  };
  let html = '<div class=top><button class=link data-back>‹ Back</button>' + (editing.isNew ? "" : '<button class="link danger" data-delete>' + (deleting ? "Tap again to delete" : "Delete") + "</button>") + "</div>";
  html += "<h2>" + esc(k.title) + "</h2><div class=card>";
  html += '<label class=f><span>Name</span><input data-label value="' + esc(editing.label) + '" placeholder="' + esc(k.label) + '" list="labels"></label>';
  html += k.fields.map((f) => "<label class=f><span>" + esc(f.label) + "</span>" + input(f) + "</label>").join("") + "</div>";
  if (k.custom) {
    // Fields the user names; a locked one's value goes to pi's secure sheet, not this page.
    html += "<h2>Fields</h2><div class=card>" + editing.rows.map((r, i) =>
      '<div class=kv><input class=k data-key="' + i + '" value="' + esc(r.name) + '" placeholder="Field name" aria-label="Field name">' +
      '<input data-value="' + i + '" value="' + esc(r.secure ? "" : r.value) + '" placeholder="' + (r.secure ? (editing.vaultId && r.saved ? "In the vault" : "Entered securely") : "Value") + '"' + (r.secure ? " disabled" : "") + ' aria-label="Value">' +
      '<button data-lock="' + i + '" aria-label="' + (r.secure ? "Locked in the vault" : "Lock in the vault") + '">' + (r.secure ? "🔒" : "🔓") + "</button>" +
      '<button data-remove="' + i + '" aria-label="Remove field">⊖</button></div>').join("") +
      '<button class=addrow data-addrow>＋ Add field</button></div>';
    html += '<p style="color:var(--muted);font-size:13px;margin:8px 4px">🔒 Locked fields go to the vault, behind Face ID: you enter them in pi’s secure sheet after saving.</p>';
    if (editing.vaultId && !editing.isNew) html += '<div class=card><div class=secure><span class=icon>🔒</span><span class=t>Locked fields<small>Behind Face ID</small></span><button class=link data-secure>Replace</button></div></div>';
  }
  if (k.kind === "address") html += '<datalist id=labels><option>Home</option><option>Work</option><option>Parents</option></datalist>';
  if (k.secure) {
    html += "<h2>In the vault</h2><div class=card><div class=secure><span class=icon>🔒</span><span class=t>" + esc(k.secure.title) +
      "<small>" + (editing.vaultId ? esc(editing.hint || "Entered") + " · behind Face ID" : (editing.isNew ? "You'll enter it securely after saving" : "Not entered yet")) + "</small></span>" +
      (editing.isNew ? "" : '<button class=link data-secure>' + (editing.vaultId ? "Replace" : "Enter") + "</button>") + "</div></div>";
  }
  html += '<button class=btn data-save>Save</button>';
  return html;
}
function render() { document.getElementById("root").innerHTML = editing ? form() : list(); }
function collect() {
  editing.label = document.querySelector("[data-label]").value.trim() || kindOf(editing.kind).label;
  document.querySelectorAll("[data-field]").forEach((el) => { const v = el.value.trim(); if (v) editing.details[el.dataset.field] = v; else delete editing.details[el.dataset.field]; });
  if (kindOf(editing.kind).custom) {
    document.querySelectorAll("[data-key]").forEach((el) => { editing.rows[+el.dataset.key].name = el.value.trim(); });
    document.querySelectorAll("[data-value]").forEach((el) => { if (!el.disabled) editing.rows[+el.dataset.value].value = el.value.trim(); });
  }
}
/** Other information: its fields as rows (public ones, then the locked ones), and back. */
function rowsOf(e) { return [...Object.entries(e.details || {}).map(([name, value]) => ({ name, value, secure: false })), ...(e.secureKeys || []).map((name) => ({ name, value: "", secure: true, saved: true }))]; }
function fromRows() {
  const details = {}, secureKeys = [];
  for (const r of editing.rows) { if (!r.name) continue; if (r.secure) secureKeys.push(r.name); else if (r.value) details[r.name] = r.value; }
  editing.details = details; editing.secureKeys = secureKeys;
}
function start(kind) { editing = { id: newId(), kind, label: kindOf(kind).label, details: {}, isNew: true, rows: kindOf(kind).custom ? [{ name: "", value: "", secure: false }] : [] }; deleting = false; render(); scrollTo(0, 0); }
document.addEventListener("click", (event) => {
  const b = event.target.closest("button"); if (!b) return;
  if (b.dataset.add) start(b.dataset.add);
  else if (b.dataset.edit) { const e = entries.find((x) => x.id === b.dataset.edit); editing = JSON.parse(JSON.stringify(e)); editing.rows = rowsOf(e); deleting = false; render(); scrollTo(0, 0); }
  else if ("back" in b.dataset) { editing = null; render(); }
  else if ("addrow" in b.dataset) { collect(); editing.rows.push({ name: "", value: "", secure: false }); render(); }
  else if ("lock" in b.dataset) { collect(); const r = editing.rows[+b.dataset.lock]; r.secure = !r.secure; r.saved = false; if (r.secure) r.value = ""; render(); }
  else if ("remove" in b.dataset) { collect(); editing.rows.splice(+b.dataset.remove, 1); render(); }
  else if ("save" in b.dataset) {
    collect();
    if (kindOf(editing.kind).custom) fromRows();
    const { isNew, rows, ...entry } = editing; pi.post({ type: "save", entry }); editing = null; render();
  }
  else if ("secure" in b.dataset) { collect(); pi.post({ type: "secure", id: editing.id }); }
  else if ("delete" in b.dataset) {
    if (!deleting) { collect(); deleting = true; render(); return; }
    pi.post({ type: "delete", id: editing.id }); editing = null; deleting = false; render();
  }
});
pi.onMessage((message) => {
  if (message.type === "entries") {
    entries = message.entries;
    if (editing && !editing.isNew) { const e = entries.find((x) => x.id === editing.id); if (e) { editing.vaultId = e.vaultId; editing.hint = e.hint; } }
    render();
  } else if (message.type === "add") start(message.kind);
});
render();
</script></body></html>`;
}
