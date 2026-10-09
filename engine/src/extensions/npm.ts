/**
 * Installs npm packages for extensions, as `npm install` would lay them out: the package in `<root>/node_modules`,
 * its dependencies (and, as npm 7+ does, its peer dependencies) hoisted beside it, and a dependency nested under its
 * dependent when another version is already there. Versions resolve with semver against the registry; tarballs are
 * unpacked here. Install scripts never run, and pi's own packages (peers of every pi extension) are the engine's,
 * so they are skipped.
 */
import semver from "semver";
import { request } from "../bridge.ts";

const REGISTRY = "https://registry.npmjs.org";
const HOST_PACKAGES = /^(@earendil-works|@mariozechner)\/pi-|^typebox$|^@sinclair\/typebox$/;
const MAX_PACKAGES = 400;

type Manifest = {
	name: string;
	version: string;
	dependencies?: Record<string, string>;
	optionalDependencies?: Record<string, string>;
	peerDependencies?: Record<string, string>;
	dist: { tarball: string };
};
type Packument = { "dist-tags": Record<string, string>; versions: Record<string, Manifest> };

/** Installs `name@range` (a range, version, or dist-tag) and its dependencies under `root`; returns its directory. */
export async function installPackage(root: string, name: string, range = "latest"): Promise<{ directory: string; version: string }> {
	const installer = new Installer(root);
	const version = await installer.install(name, range, root);
	await installer.dependencies();
	return { directory: `${root}/node_modules/${name}`, version };
}

/** Installs the dependencies a package directory's package.json lists, into its own node_modules. */
export async function installDependencies(directory: string, manifest: { dependencies?: Record<string, string> }): Promise<void> {
	const installer = new Installer(directory);
	for (const [name, range] of Object.entries(manifest.dependencies ?? {})) {
		if (!HOST_PACKAGES.test(name)) await installer.install(name, range, directory);
	}
	await installer.dependencies();
}

class Installer {
	private readonly packuments = new Map<string, Packument>();
	/** What is installed at each node_modules directory: package name → version. */
	private readonly placed = new Map<string, Map<string, string>>();
	private readonly pending: { name: string; range: string; dependent: string }[] = [];
	private count = 0;

	constructor(private readonly root: string) {}

	/** Installs one package at `<parent>/node_modules` and queues its dependencies. */
	async install(name: string, range: string, parent: string): Promise<string> {
		const manifest = await this.resolve(name, range);
		const directory = `${parent}/node_modules/${name}`;
		this.place(parent, name, manifest.version);
		if (++this.count > MAX_PACKAGES) throw new Error(`too many packages (more than ${MAX_PACKAGES})`);
		await unpack(manifest.dist.tarball, directory);
		for (const [dependency, dependencyRange] of Object.entries({ ...manifest.peerDependencies, ...manifest.optionalDependencies, ...manifest.dependencies })) {
			if (!HOST_PACKAGES.test(dependency)) this.pending.push({ name: dependency, range: dependencyRange, dependent: directory });
		}
		return manifest.version;
	}

	/** Installs queued dependencies: hoisted to the root when free or satisfied there, otherwise nested. */
	async dependencies(): Promise<void> {
		while (this.pending.length > 0) {
			const { name, range, dependent } = this.pending.shift()!;
			// Already satisfied by the dependent's own node_modules or one above it, as Node would find it.
			if (this.satisfiedFrom(dependent, name, range)) continue;
			const atRoot = this.placed.get(this.root)?.get(name);
			const parent = atRoot === undefined ? this.root : dependent;
			try {
				await this.install(name, range, parent);
			} catch (error) {
				throw new Error(`${name}@${range} (for ${dependent.split("/node_modules/").pop()}): ${error instanceof Error ? error.message : String(error)}`);
			}
		}
	}

	private satisfiedFrom(dependent: string, name: string, range: string): boolean {
		for (let directory = dependent; ; ) {
			const version = this.placed.get(directory)?.get(name);
			if (version !== undefined) return satisfies(version, range);
			if (directory === this.root || !directory.includes("/node_modules/")) break;
			directory = directory.slice(0, directory.lastIndexOf("/node_modules/"));
		}
		const atRoot = this.placed.get(this.root)?.get(name);
		return atRoot !== undefined && satisfies(atRoot, range);
	}

	private place(parent: string, name: string, version: string): void {
		if (!this.placed.has(parent)) this.placed.set(parent, new Map());
		this.placed.get(parent)!.set(name, version);
	}

	private async resolve(name: string, range: string): Promise<Manifest> {
		let packument = this.packuments.get(name);
		if (!packument) {
			const response = await fetch(`${REGISTRY}/${name.replace("/", "%2F")}`, {
				headers: { accept: "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8" },
			});
			if (!response.ok) throw new Error(response.status === 404 ? `no package ${name} on npm` : `npm registry: HTTP ${response.status}`);
			packument = (await response.json()) as Packument;
			this.packuments.set(name, packument);
		}
		const tag = packument["dist-tags"][range];
		const version = tag ?? semver.maxSatisfying(Object.keys(packument.versions), range === "" ? "*" : range, { includePrerelease: false });
		const manifest = version ? packument.versions[version] : undefined;
		if (!manifest) throw new Error(`no version of ${name} matches ${range}`);
		return manifest;
	}
}

function satisfies(version: string, range: string): boolean {
	try {
		return semver.satisfies(version, range === "latest" || range === "" ? "*" : range);
	} catch {
		return false;
	}
}

/** Downloads a package tarball and writes its files (under "package/") into `directory`. */
async function unpack(url: string, directory: string): Promise<void> {
	const response = await fetch(url);
	if (!response.ok) throw new Error(`tarball: HTTP ${response.status}`);
	const archive = new Uint8Array(await new Response(response.body!.pipeThrough(new DecompressionStream("gzip"))).arrayBuffer());
	const directories = new Set<string>();
	for (const file of untar(archive)) {
		const relative = file.path.split("/").slice(1).join("/");
		if (!relative || relative.includes("..")) continue;
		const target = `${directory}/${relative}`;
		const parent = target.slice(0, target.lastIndexOf("/"));
		if (!directories.has(parent)) {
			await request("fs", "mkdir", { path: parent, recursive: true });
			directories.add(parent);
		}
		await request("fs", "write", { path: target, data: base64(file.data) });
	}
}

/** Regular files of a tar archive (ustar, with pax and GNU long names). */
function* untar(archive: Uint8Array): Generator<{ path: string; data: Uint8Array }> {
	const text = (offset: number, length: number) => new TextDecoder().decode(archive.subarray(offset, offset + length)).replace(/\0.*$/s, "");
	let offset = 0;
	let longName: string | undefined;
	while (offset + 512 <= archive.length) {
		const name = text(offset, 100);
		if (!name) break;
		const size = Number.parseInt(text(offset + 124, 12).trim() || "0", 8);
		const type = String.fromCharCode(archive[offset + 156]!);
		const prefix = text(offset + 345, 155);
		const dataStart = offset + 512;
		const data = archive.subarray(dataStart, dataStart + size);
		offset = dataStart + Math.ceil(size / 512) * 512;
		if (type === "x") {
			longName = /(?:^|\n)\d+ path=([^\n]*)\n/.exec(new TextDecoder().decode(data))?.[1] ?? longName;
			continue;
		}
		if (type === "L") {
			longName = new TextDecoder().decode(data).replace(/\0.*$/s, "");
			continue;
		}
		const path = longName ?? (prefix ? `${prefix}/${name}` : name);
		longName = undefined;
		if (type === "0" || type === "\0" || type === "7") yield { path, data };
	}
}

function base64(bytes: Uint8Array): string {
	let binary = "";
	for (let index = 0; index < bytes.length; index += 0x8000) binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
	return btoa(binary);
}
