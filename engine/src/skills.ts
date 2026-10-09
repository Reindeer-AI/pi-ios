/**
 * pi skills (the Agent Skills format): a folder with a SKILL.md whose frontmatter names the skill and says when it
 * applies. The prompt lists each skill's name, description, and location, as pi lists them; the agent reads a skill's
 * SKILL.md when a task matches, and `/skill:name args` puts the instructions in the prompt directly.
 *
 * Found, the first of a name winning, in: the app's skills folder (pi's ~/.pi/agent/skills, for every session), the
 * session's .pi/skills and .agents/skills, and the skills of the session's extension packages (`pi.skills`, else a
 * skills/ folder).
 */
import { defineExtension, section } from "@earendil-works/pi-durable";
import { parse } from "yaml";
import { request } from "./bridge.ts";

export type Skill = {
	name: string;
	description: string;
	/** The SKILL.md (or a skills folder's top-level .md). */
	filePath: string;
	/** What the skill's relative paths are relative to. */
	baseDir: string;
	/** user, project, or the package's name. */
	source: string;
	disableModelInvocation: boolean;
};

export type SkillRoot = { dir: string; source: string };

/** The roots a session's skills come from, in order; set by the engine. */
let rootsOf: (sessionId: number, cwd: string | undefined) => Promise<SkillRoot[]> = async () => [];

export function setSkillRoots(roots: typeof rootsOf): void {
	rootsOf = roots;
}

/** A session's skills; the folders are read again after a few seconds, so a skill the agent just wrote shows up. */
export async function sessionSkills(sessionId: number, cwd: string | undefined): Promise<Skill[]> {
	const key = `${sessionId}:${cwd ?? ""}`;
	const cached = cache.get(key);
	if (cached && Date.now() - cached.at < 5000) return cached.skills;
	const skills: Skill[] = [];
	const names = new Set<string>();
	for (const root of await rootsOf(sessionId, cwd)) {
		for (const skill of await findSkills(root.dir, root.source, true)) {
			if (names.has(skill.name)) continue;
			names.add(skill.name);
			skills.push(skill);
		}
	}
	cache.set(key, { at: Date.now(), skills });
	return skills;
}

const cache = new Map<string, { at: number; skills: Skill[] }>();

/** After extensions change, so a package's skills show up (or go) in the next request. */
export function forgetSkills(): void {
	cache.clear();
}

/** The skills in one folder (the app's skills folder, for Settings). */
export function skillsIn(dir: string, source: string): Promise<Skill[]> {
	return findSkills(dir, source, true);
}

/** As pi finds them: a folder with a SKILL.md is one skill (nothing under it is searched); otherwise its subfolders
 * are searched, and at the top a standalone .md with a description is a skill too. Dot folders and node_modules are
 * skipped. */
async function findSkills(dir: string, source: string, top: boolean): Promise<Skill[]> {
	let entries: { name: string; kind: string }[];
	try {
		entries = await request<{ name: string; kind: string }[]>("fs", "readdir", { path: dir });
	} catch {
		// Also a root given as the SKILL.md itself.
		const skill = top && dir.endsWith(".md") ? await readSkill(dir, source) : undefined;
		return skill ? [skill] : [];
	}
	if (entries.some((entry) => entry.name === "SKILL.md" && entry.kind !== "directory")) {
		const skill = await readSkill(`${dir}/SKILL.md`, source);
		return skill ? [skill] : [];
	}
	const skills: Skill[] = [];
	for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
		if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
		const path = `${dir}/${entry.name}`;
		if (entry.kind === "directory") skills.push(...(await findSkills(path, source, false)));
		else if (top && entry.name.endsWith(".md")) {
			const skill = await readSkill(path, source);
			if (skill) skills.push(skill);
		}
	}
	return skills;
}

async function readSkill(filePath: string, source: string): Promise<Skill | undefined> {
	let frontmatter: Record<string, unknown>;
	try {
		frontmatter = parseFrontmatter(await request<string>("fs", "readText", { path: filePath })).frontmatter;
	} catch (error) {
		console.warn(`skill ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
		return undefined;
	}
	const description = typeof frontmatter.description === "string" ? frontmatter.description.trim() : "";
	if (!description) {
		if (filePath.endsWith("/SKILL.md")) console.warn(`skill ${filePath}: no description, so not loaded`);
		return undefined;
	}
	const baseDir = filePath.slice(0, filePath.lastIndexOf("/"));
	const name = typeof frontmatter.name === "string" && frontmatter.name ? frontmatter.name : baseDir.slice(baseDir.lastIndexOf("/") + 1);
	return { name, description, filePath, baseDir, source, disableModelInvocation: frontmatter["disable-model-invocation"] === true };
}

function parseFrontmatter(text: string): { frontmatter: Record<string, unknown>; body: string } {
	const match = /^﻿?---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
	if (!match) return { frontmatter: {}, body: text };
	const parsed: unknown = parse(match[1]!);
	return { frontmatter: parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {}, body: match[2]! };
}

/** pi's listing (formatSkillsForPrompt), for the skills the model may pick itself. */
export function skillsPrompt(skills: readonly Skill[]): string | undefined {
	const visible = skills.filter((skill) => !skill.disableModelInvocation);
	if (visible.length === 0) return undefined;
	return [
		"The following skills provide specialized instructions for specific tasks.",
		"Use the read tool to load a skill's file when the task matches its description, before doing the task another way, and follow it.",
		"When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands, in quotes (it may contain spaces). Run its scripts with sh or python3 and that path.",
		"",
		"<available_skills>",
		...visible.flatMap((skill) => [
			"  <skill>",
			`    <name>${escapeXml(skill.name)}</name>`,
			`    <description>${escapeXml(skill.description)}</description>`,
			`    <location>${escapeXml(skill.filePath)}</location>`,
			"  </skill>",
		]),
		"</available_skills>",
	].join("\n");
}

/** `/skill:name args` as pi expands it: the skill's instructions in a <skill> block, then the arguments as the
 * request. Anything else, or an unknown skill, is returned as it is. */
export async function expandSkillCommand(text: string, skills: readonly Skill[]): Promise<string> {
	const match = /^\/skill:(\S+)\s*([\s\S]*)$/.exec(text.trim());
	const skill = match && skills.find((candidate) => candidate.name === match[1]);
	if (!match || !skill) return text;
	const body = parseFrontmatter(await request<string>("fs", "readText", { path: skill.filePath })).body.trim();
	const block = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}: use that folder's full path, in quotes, in commands (for example "${skill.baseDir}/scripts/…").\n\n${body}\n</skill>`;
	const args = match[2]!.trim();
	return args ? `${block}\n\n${args}` : block;
}

function escapeXml(text: string): string {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

/** The skills listing, a section only when the session has skills. */
export const SkillsExtension = defineExtension({
	name: "skills",
	sections: [section("skills", async (input) => skillsPrompt(await sessionSkills(Number(input.conversationId), input.env?.cwd)), { tag: false })],
});
