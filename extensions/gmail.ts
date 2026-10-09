/**
 * gmail: an inbox triage app, over Gmail in pi's browser.
 *
 * /gmail opens the Gmail app and has the agent review the top of the inbox of a Google account signed in to the browser
 * profile: it sorts the messages into "Requires attention", "Calendar invites" and "Low signal" and reports them with
 * gmail_triage. The app picks the account, lists each category, and has quick actions (refresh, archive one or all,
 * reply), which become requests to the agent; the user can also just ask ("archive low signal", "draft a reply to Dana
 * saying ..."). The agent archives and drafts, and never deletes or sends unless the user says so.
 *
 * It is a pi app (pi.registerApp): closing it minimizes it to the session's dock, where its badge counts what requires
 * attention; a triage the agent reports puts it there when it isn't running.
 *
 * The last triage is kept in .pi-gmail.json next to the session folders, so a new session's app starts from it.
 */
import { Type } from "@earendil-works/pi-ai";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

type Message = { id: string; from: string; subject: string; snippet?: string; date?: string; reason?: string; when?: string };
type Category = "attention" | "invites" | "low";
type Triage = {
	accounts: string[];
	account?: string;
	reviewed: number;
	updatedAt?: string;
	status?: string;
	attention: Message[];
	invites: Message[];
	low: Message[];
	drafted: string[];
	/** Archived since the last review. */
	archived: number;
};

const LABELS: Record<Category, string> = { attention: "requires attention", invites: "calendar invite", low: "low-signal" };
const EMPTY: Triage = { accounts: [], reviewed: 0, attention: [], invites: [], low: [], drafted: [], archived: 0 };

const file = () => join(dirname(homedir()), ".pi-gmail.json");

function load(): Triage {
	try {
		if (existsSync(file())) return { ...EMPTY, ...JSON.parse(readFileSync(file(), "utf8")) };
	} catch {}
	return { ...EMPTY };
}

function save(triage: Triage) {
	writeFileSync(file(), JSON.stringify(triage, null, 2));
}

const message = Type.Object({
	id: Type.String({ description: "A short id of your own, unique in this triage: m1, m2, ..." }),
	from: Type.String({ description: "Sender name (or address)" }),
	subject: Type.String(),
	snippet: Type.Optional(Type.String({ description: "One short line of what it says" })),
	date: Type.Optional(Type.String({ description: "As the inbox shows it: 9:41 AM, Oct 7, ..." })),
	reason: Type.Optional(Type.String({ description: "Requires attention: why, in a few words (asks for a decision, deadline Friday, ...)" })),
	when: Type.Optional(Type.String({ description: "Calendar invites: the event's time" })),
});

export default function (pi: any) {
	// pi before apps (pi.registerApp): say so, rather than fail to load.
	if (typeof pi.registerApp !== "function") {
		pi.registerCommand("gmail", {
			description: "The Gmail app (needs a newer pi)",
			handler: async (_args: string, ctx: any) => ctx.ui.notify("The Gmail app needs a newer pi: update pi, then try again.", "warning"),
		});
		return;
	}
	let triage = load();

	const ask = (text: string) => pi.sendUserMessage(text, { deliverAs: "followUp" });
	const find = (id: string) =>
		(["attention", "invites", "low"] as Category[]).map((c) => triage[c].find((m) => m.id === id)).find(Boolean);

	pi.registerApp({
		name: "gmail",
		title: "Gmail",
		icon: "envelope",
		description: "The user's Gmail triage: requires attention, calendar invites, low signal, with quick actions",
		render: () => page(triage),
		onMessage: (data: { type: string; [key: string]: any }, app: any) => {
			const account = triage.account ? ` (${triage.account})` : "";
			switch (data.type) {
				case "account":
					triage = { ...triage, account: data.account };
					save(triage);
					app.post(triage);
					ask(`Triage the Gmail inbox of ${data.account}.`);
					break;
				case "refresh":
					ask(`Refresh my Gmail triage${account}.`);
					break;
				case "archiveAll": {
					const list = triage[data.category as Category] ?? [];
					if (list.length) ask(`Archive all ${list.length} ${LABELS[data.category as Category]} messages${account}.`);
					break;
				}
				case "archive": {
					const m = find(data.id);
					if (m) ask(`Archive "${m.subject}" from ${m.from} (${m.id}).`);
					break;
				}
				case "accept":
				case "decline": {
					const m = triage.invites.find((invite) => invite.id === data.id);
					if (m) {
						const action = data.type === "accept" ? "Accept" : "Decline";
						ask(`${action} the calendar invitation "${m.subject}" from ${m.from} (${m.id})${account}${m.when ? ` for ${m.when}` : ""}. Respond to this invitation in Gmail; do not archive or delete it.`);
					}
					break;
				}
				case "reply": {
					const m = find(data.id);
					if (m) {
						// The message box is under the app: put it away.
						app.minimize();
						app.ui.setEditorText(`Draft a reply to ${m.from} ("${m.subject}", ${m.id}) saying `);
					}
					break;
				}
			}
		},
	});

	/** Gives the app the triage, opening it (on screen, or in the dock) when it isn't running; badges what needs attention. */
	async function show(visible: boolean) {
		const app = pi.apps.get("gmail") ?? (await pi.apps.open("gmail", { visible }));
		if (visible) await app.show();
		app.post(triage);
		app.setBadge(triage.attention.length || undefined);
	}

	pi.registerCommand("gmail", {
		description: "Triage your Gmail inbox: requires attention, calendar invites, low signal",
		handler: async (args: string) => {
			await show(true);
			const account = args?.trim() || triage.account;
			ask(account ? `Triage the Gmail inbox of ${account}.` : "Triage my Gmail inbox.");
		},
	});

	pi.registerTool({
		name: "gmail_triage",
		label: "Gmail triage",
		description:
			"Shows and updates the Gmail triage app (in the session's dock when the user isn't looking at it). Pass what changed: accounts (the Google accounts signed in to the browser) and account (the inbox being triaged); status while you work (\"Reviewing the inbox…\"); after reviewing, reviewed (how many messages you reviewed in total) and the three categories, each replacing what was there; after acting, archived (ids now out of the inbox) and drafted (ids with a reply draft).",
		parameters: Type.Object({
			accounts: Type.Optional(Type.Array(Type.String())),
			account: Type.Optional(Type.String()),
			status: Type.Optional(Type.String({ description: "A short progress line; empty to clear it" })),
			reviewed: Type.Optional(Type.Number()),
			attention: Type.Optional(Type.Array(message, { description: "Requires attention" })),
			invites: Type.Optional(Type.Array(message, { description: "Calendar invites" })),
			low: Type.Optional(Type.Array(message, { description: "Low signal" })),
			archived: Type.Optional(Type.Array(Type.String())),
			drafted: Type.Optional(Type.Array(Type.String())),
		}),
		async execute(_id: string, params: any) {
			const next: Triage = { ...triage };
			if (params.accounts) next.accounts = params.accounts;
			if (params.account) {
				if (params.account !== triage.account) next.drafted = [];
				next.account = params.account;
			}
			if (params.status !== undefined) next.status = params.status || undefined;
			for (const c of ["attention", "invites", "low"] as Category[]) if (params[c]) next[c] = params[c];
			if (params.reviewed !== undefined) {
				next.reviewed = params.reviewed;
				next.updatedAt = new Date().toISOString();
				next.status = params.status || undefined;
				next.drafted = [];
				next.archived = 0;
			}
			if (params.archived?.length) {
				const gone = new Set(params.archived);
				for (const c of ["attention", "invites", "low"] as Category[]) {
					const kept = next[c].filter((m) => !gone.has(m.id));
					next.archived += next[c].length - kept.length;
					next[c] = kept;
				}
			}
			if (params.drafted?.length) next.drafted = [...new Set([...next.drafted, ...params.drafted])];
			triage = next;
			save(triage);
			await show(false);
			const counts = `${triage.attention.length} requiring attention, ${triage.invites.length} invites, ${triage.low.length} low signal, of ${triage.reviewed} reviewed`;
			return { content: [{ type: "text", text: `The Gmail app shows ${triage.account ?? "no account"}: ${counts}.` }], details: null };
		},
	});

	pi.on("before_agent_start", (event: { systemPrompt: string }) => ({ systemPrompt: `${event.systemPrompt}\n\n${GUIDANCE}` }));
}

const GUIDANCE = `## Gmail triage (gmail extension)
When the user asks to triage, filter or review their Gmail (or a request comes from the Gmail app), work in the browser, in the profile where they are signed in to Google:
1. Accounts: open https://accounts.google.com/SignOutOptions, which lists the Google accounts signed in to the browser; their order is their Gmail number (https://mail.google.com/mail/u/0/ for the first, /u/1/ the next). If none is signed in, ask the user to sign in (tap the browser card, Take control), then go on. Call gmail_triage with accounts, account (the one asked for, else the first), and status "Reviewing the inbox…".
2. Open that account's inbox and review the top of it: the first 30 to 50 conversations, from the list (open one only when the list doesn't tell you enough). Every one you review goes in exactly one category:
   - attention (requires attention): needs the user: a person writing to them, a question or decision waiting on them, a deadline, something important (security alerts, bills due, contracts). Give a short reason.
   - invites (calendar invites): invitations, updates and cancellations; give the event's time in when.
   - low (low signal): newsletters, promotions, social and product notifications, receipts, automated mail that needs nothing.
   Give each an id (m1, m2, ...), the sender, the subject, a one-line snippet and the date as listed. Call gmail_triage with reviewed (the total) and the three categories, then answer in a line or two with the counts (the app shows the lists).
3. Acting, on the messages of the triage (find them in the inbox by sender and subject):
   - Archive with Gmail's Archive (selecting several in the list when there are many); never delete, never mark as spam unless asked. Then call gmail_triage with archived.
   - "Draft a reply ... saying ...": open the conversation, Reply, write it in the user's voice, and leave it as a draft (Gmail saves it); send only when the user explicitly says send. Then call gmail_triage with drafted.
   - Accept or decline invites only when asked (including requests from the app's Accept/Decline buttons). Find the matching invitation in the specified account by sender, subject and event time, then use Gmail's Yes/No RSVP controls. Verify the response before reporting success. Do not archive it unless separately asked. If the event is cancelled or RSVP controls are unavailable, explain that rather than claiming a response.
   Say in a line what you did.`;

/** The app's page: account picker, totals, category tabs with their messages, and quick actions. */
function page(initial: Triage): string {
	return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--card:#fff;--text:#111;--muted:#6b6b73;--line:#e5e5ea;--chip:#eef0f4;--accent:#0a84ff;--red:#d93025;--amber:#b06000;--green:#188038}
@media (prefers-color-scheme:dark){:root{--card:#1c1c1e;--text:#f2f2f7;--muted:#9a9aa2;--line:#2c2c2e;--chip:#2c2c2e}}
*{box-sizing:border-box}body{margin:0;font:14px -apple-system,system-ui,sans-serif;color:var(--text);background:transparent}
.box{background:var(--card);border-radius:14px;padding:10px 12px;margin:4px 0}
.top{display:flex;align-items:center;gap:8px}
.logo{width:22px;height:22px;border-radius:6px;background:linear-gradient(135deg,#ea4335,#fbbc04 40%,#34a853 70%,#4285f4);flex:none}
select{flex:1;min-width:0;font:600 14px -apple-system,system-ui;color:inherit;background:transparent;border:0;-webkit-appearance:none;text-overflow:ellipsis}
.icon{border:0;background:var(--chip);color:var(--text);border-radius:14px;height:28px;padding:0 10px;font:13px -apple-system,system-ui}
.meta{color:var(--muted);font-size:12px;margin:4px 0 8px}
.tabs{display:flex;gap:6px}
.tab{flex:1;border:0;border-radius:10px;padding:6px 4px;background:var(--chip);color:var(--text);font:12px -apple-system,system-ui;text-align:center}
.tab b{display:block;font-size:17px}
.tab.on{background:var(--text);color:var(--card)}
.tab.attention b{color:var(--red)}.tab.invites b{color:var(--amber)}.tab.low b{color:var(--muted)}
.tab.on b{color:inherit}
.list{margin-top:8px}
.msg{display:flex;gap:8px;align-items:flex-start;padding:7px 0;border-top:1px solid var(--line)}
.msg .text{flex:1;min-width:0}
.msg .from{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.msg .subject,.msg .snippet{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.msg .snippet{color:var(--muted);font-size:12px}
.msg .why{color:var(--red);font-size:12px}.msg .when{color:var(--amber);font-size:12px}
.msg .drafted{color:var(--green);font-size:12px}
.acts{display:flex;gap:4px;flex:none}
.msg.invite{flex-wrap:wrap}
.msg.invite .text{flex-basis:100%}
.msg.invite .acts{flex-wrap:wrap;justify-content:flex-end;width:100%}
.acts .accept{color:var(--green);font-weight:600}
.acts .decline{color:var(--red);font-weight:600}
.acts button{border:0;background:var(--chip);color:var(--text);border-radius:12px;height:26px;padding:0 8px;font:12px -apple-system,system-ui}
.bulk{display:flex;justify-content:flex-end;margin-top:8px}
.bulk button{border:0;border-radius:14px;height:30px;padding:0 14px;background:var(--accent);color:#fff;font:600 13px -apple-system,system-ui}
.empty{color:var(--muted);font-size:13px;padding:8px 0 2px}
.status{color:var(--accent);font-size:12px}
</style></head><body><div class="box" id="root"></div>
<script>
const NAMES = { attention: "Attention", invites: "Invites", low: "Low signal" };
let state = ${JSON.stringify(initial)};
let tab = "attention";
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function ago(iso) {
  if (!iso) return "";
  const m = Math.round((Date.now() - new Date(iso)) / 60000);
  return m < 1 ? "just now" : m < 60 ? m + " min ago" : m < 1440 ? Math.round(m / 60) + " h ago" : new Date(iso).toLocaleDateString();
}
function render() {
  const accounts = state.accounts.length ? state.accounts : (state.account ? [state.account] : []);
  const list = state[tab];
  document.getElementById("root").innerHTML =
    '<div class="top"><div class="logo"></div>' +
    (accounts.length
      ? '<select id="account" aria-label="Inbox">' + accounts.map(a => '<option' + (a === state.account ? " selected" : "") + '>' + esc(a) + '</option>').join("") + '</select>'
      : '<span style="flex:1;font-weight:600">Gmail</span>') +
    '<button class="icon" id="refresh" aria-label="Refresh">↻ Refresh</button></div>' +
    '<div class="meta">' + (state.status ? '<span class="status">' + esc(state.status) + '</span>'
      : state.reviewed ? 'Reviewed ' + state.reviewed + ' messages at the top of the inbox · ' + ago(state.updatedAt) + (state.archived ? ' · ' + state.archived + ' archived' : '')
      : 'Not reviewed yet') + '</div>' +
    '<div class="tabs">' + Object.keys(NAMES).map(k => '<button class="tab ' + k + (k === tab ? " on" : "") + '" data-tab="' + k + '"><b>' + state[k].length + '</b>' + NAMES[k] + '</button>').join("") + '</div>' +
    '<div class="list">' + (list.length ? list.map(m =>
      '<div class="msg' + (tab === "invites" ? ' invite' : '') + '"><div class="text"><div class="from">' + esc(m.from) + (m.date ? ' <span class="snippet">· ' + esc(m.date) + '</span>' : '') + '</div>' +
      '<div class="subject">' + esc(m.subject) + '</div>' +
      (m.reason ? '<div class="why">' + esc(m.reason) + '</div>' : m.when ? '<div class="when">' + esc(m.when) + '</div>' : m.snippet ? '<div class="snippet">' + esc(m.snippet) + '</div>' : '') +
      (state.drafted.includes(m.id) ? '<div class="drafted">Reply drafted</div>' : '') +
      '</div><div class="acts">' +
      (tab === "invites" ? '<button class="accept" data-accept="' + esc(m.id) + '" aria-label="Accept invitation: ' + esc(m.subject) + '">Accept</button><button class="decline" data-decline="' + esc(m.id) + '" aria-label="Decline invitation: ' + esc(m.subject) + '">Decline</button>' : '') +
      '<button data-reply="' + esc(m.id) + '" aria-label="Reply to ' + esc(m.from) + '">Reply</button><button data-archive="' + esc(m.id) + '" aria-label="Archive ' + esc(m.subject) + '">Archive</button></div></div>').join("")
      : '<div class="empty">' + (state.reviewed ? "Nothing here." : "Ask pi to triage your inbox.") + '</div>') + '</div>' +
    (list.length > 1 ? '<div class="bulk"><button id="archiveAll">Archive all ' + list.length + '</button></div>' : '');
}
document.addEventListener("click", e => {
  const b = e.target.closest("button"); if (!b) return;
  if (b.dataset.tab) { tab = b.dataset.tab; render(); return; }
  if (b.id === "refresh") pi.post({ type: "refresh" });
  else if (b.id === "archiveAll") pi.post({ type: "archiveAll", category: tab });
  else if (b.dataset.archive) pi.post({ type: "archive", id: b.dataset.archive });
  else if (b.dataset.reply) pi.post({ type: "reply", id: b.dataset.reply });
  else if (b.dataset.accept) pi.post({ type: "accept", id: b.dataset.accept });
  else if (b.dataset.decline) pi.post({ type: "decline", id: b.dataset.decline });
});
document.addEventListener("change", e => { if (e.target.id === "account") pi.post({ type: "account", account: e.target.value }); });
pi.onMessage(next => { state = next; render(); });
render();
</script></body></html>`;
}
