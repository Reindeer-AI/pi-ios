#!/usr/bin/env node
// Writes App/PiMobile/Acknowledgements.json, the license texts of everything the app ships (Settings → About →
// Acknowledgements): the native components (a-Shell's commands, dash, curl, git, OpenSSL, libssh2, CPython,
// llama.cpp), the Swift packages, and the npm packages in the engine's bundle.
//
//     cd engine && npm run build && cd ..        # engine/dist/bundled-packages.json
//     node scripts/acknowledgements.mjs [SWIFT_CHECKOUTS]
//
// SWIFT_CHECKOUTS is Xcode's SourcePackages/checkouts folder (default: App/build/DerivedData's, from a build with
// -derivedDataPath App/build/DerivedData). Native components' texts are fetched from their projects at the versions
// the Vendor scripts use. Run it again when a dependency changes, and commit the result.
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const checkouts = resolve(process.argv[2] ?? join(root, "App/build/DerivedData/SourcePackages/checkouts"));
const texts = {};
const keep = (text) => {
	const trimmed = text.replace(/\r\n/g, "\n").trim();
	const id = createHash("sha256").update(trimmed).digest("hex").slice(0, 16);
	texts[id] = trimmed;
	return id;
};
const fetchText = async (url) => {
	const response = await fetch(url);
	if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
	return response.text();
};
const vendor = (file, pattern) => pattern.exec(readFileSync(join(root, "Vendor", file), "utf8"))?.[1];

// ---- native components ----

const llamaTag = vendor("build-llama.sh", /^TAG="([^"]+)"/m);
const pythonRelease = vendor("fetch-python.sh", /^RELEASE="([^"]+)"/m);
const pythonVersion = pythonRelease?.split("-")[0];
const native = [
	{ name: "ios_system", version: "3.0.6", license: "BSD-3-Clause", url: "https://raw.githubusercontent.com/holzschu/ios_system/master/LICENSE", note: "a-Shell's command system, with its file, text and shell commands from FreeBSD under their BSD licenses." },
	{ name: "The One True Awk", version: "20200816", license: "Lucent (MIT-style)", url: "https://raw.githubusercontent.com/freebsd/freebsd-src/main/contrib/one-true-awk/LICENSE" },
	{ name: "libarchive (tar)", license: "BSD-2-Clause", url: "https://raw.githubusercontent.com/libarchive/libarchive/master/COPYING" },
	{ name: "dash", license: "BSD-3-Clause", url: "https://raw.githubusercontent.com/holzschu/dash_iOS/master/COPYING" },
	{ name: "curl", license: "curl", url: "https://raw.githubusercontent.com/curl/curl/master/COPYING" },
	{ name: "libgit2 (lg2)", license: "GPL-2.0 with the linking exception", url: "https://raw.githubusercontent.com/libgit2/libgit2/main/COPYING" },
	{ name: "OpenSSL", version: "1.1.1w", license: "OpenSSL and SSLeay", url: "https://raw.githubusercontent.com/openssl/openssl/OpenSSL_1_1_1w/LICENSE", note: "This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/), and cryptographic software written by Eric Young (eay@cryptsoft.com)." },
	{ name: "libssh2", version: "1.11.0", license: "BSD-3-Clause", url: "https://raw.githubusercontent.com/libssh2/libssh2/libssh2-1.11.0/COPYING" },
	{ name: "CA certificates", license: "MPL-2.0", text: "Mozilla's CA certificate list, as curl publishes it (https://curl.se/docs/caextract.html). Its source is at https://hg.mozilla.org/mozilla-central/file/tip/security/nss/lib/ckfw/builtins/certdata.txt, under the Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/)." },
	{ name: "CPython", version: pythonVersion, license: "PSF-2.0, with the licenses of the software it incorporates", url: `https://raw.githubusercontent.com/python/cpython/${pythonVersion}/Doc/license.rst` },
	{ name: "Python-Apple-support", version: pythonRelease, license: "BSD-3-Clause", url: "https://raw.githubusercontent.com/beeware/Python-Apple-support/main/LICENSE", note: "BeeWare's build of CPython for iOS, with OpenSSL 3, libFFI, XZ, BZip2 and mpdecimal (below)." },
	{ name: "OpenSSL 3 (in Python)", license: "Apache-2.0", url: "https://raw.githubusercontent.com/openssl/openssl/openssl-3.0/LICENSE.txt" },
	{ name: "libffi (in Python)", license: "MIT", url: "https://raw.githubusercontent.com/libffi/libffi/master/LICENSE" },
	{ name: "XZ Utils (in Python)", license: "0BSD", url: "https://raw.githubusercontent.com/tukaani-project/xz/master/COPYING" },
	{ name: "bzip2 (in Python)", license: "bzip2-1.0.6", url: "https://gitlab.com/bzip2/bzip2/-/raw/master/COPYING" },
	{ name: "mpdecimal (in Python)", license: "BSD-2-Clause", text: "Copyright (c) 2008-2024 Stefan Krah. All rights reserved.\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\nTHIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE." },
	{ name: "llama.cpp", version: llamaTag, license: "MIT", url: `https://raw.githubusercontent.com/ggml-org/llama.cpp/${llamaTag}/LICENSE` },
];
const components = [];
for (const item of native) {
	const text = item.text ?? (await fetchText(item.url));
	components.push({ name: item.name, ...(item.version ? { version: item.version } : {}), license: item.license, text: keep(item.note ? `${item.note}\n\n${text}` : text) });
}

// ---- Swift packages ----

const resolved = JSON.parse(readFileSync(join(root, "App/PiMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"), "utf8"));
const swift = [];
for (const pin of resolved.pins) {
	const folder = join(checkouts, pin.identity);
	if (!existsSync(folder)) throw new Error(`${pin.identity} is not checked out in ${checkouts}: build the app first`);
	const files = readdirSync(folder).filter((file) => /^(license|notice)(\.(txt|md))?$/i.test(file)).sort();
	if (files.length === 0) throw new Error(`${pin.identity}: no license file`);
	const text = files.map((file) => readFileSync(join(folder, file), "utf8").trim()).join("\n\n");
	swift.push({ name: pin.identity, version: pin.state.version ?? pin.state.revision?.slice(0, 7), license: "Apache-2.0", text: keep(text) });
}

// ---- npm packages in the engine's bundle ----

const engine = join(root, "engine");
const bundled = JSON.parse(readFileSync(join(engine, "dist/bundled-packages.json"), "utf8"));
const piLicense = await fetchText("https://raw.githubusercontent.com/badlogic/pi-mono/main/LICENSE");
const npm = new Map();
for (const folder of bundled) {
	const manifest = JSON.parse(readFileSync(join(engine, folder, "package.json"), "utf8"));
	const key = `${manifest.name}@${manifest.version}`;
	if (npm.has(key)) continue;
	const license = typeof manifest.license === "string" ? manifest.license : (manifest.license?.type ?? "see text");
	const file = readdirSync(join(engine, folder)).find((name) => /^(licen[cs]e|copying)(\.(md|txt|markdown))?$/i.test(name));
	let text;
	if (file) text = readFileSync(join(engine, folder, file), "utf8");
	else if (manifest.name.startsWith("@earendil-works/")) text = piLicense;
	else {
		const author = typeof manifest.author === "string" ? manifest.author : manifest.author?.name;
		text = `${license}${author ? `\n\nCopyright (c) ${author}` : ""}\n\n(The package has no license file; its package.json gives this license.)`;
	}
	npm.set(key, { name: manifest.name, version: manifest.version, license, text: keep(text) });
}

const sections = [
	{ title: "Components", items: components },
	{ title: "Swift packages", items: swift.sort((a, b) => a.name.localeCompare(b.name)) },
	{ title: "JavaScript packages", items: [...npm.values()].sort((a, b) => a.name.localeCompare(b.name)) },
];
const out = join(root, "App/PiMobile/Acknowledgements.json");
writeFileSync(out, `${JSON.stringify({ sections, texts })}\n`);
console.log(`${out}: ${sections.map((section) => `${section.items.length} ${section.title.toLowerCase()}`).join(", ")}, ${Object.keys(texts).length} texts, ${Math.round(readFileSync(out).length / 1024)} KB`);
