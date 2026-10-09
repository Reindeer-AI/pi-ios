// The agent's view of a page and its hands on it. Runs in the "pi-agent" content world: it shares the page's DOM but
// not its JavaScript, so the page can neither see nor tamper with it. Defined once per document; refs live as long
// as their elements do.
window.__piAgent ??= (() => {
	const MAX_SNAPSHOT_CHARS = 14000;
	const MAX_READ_CHARS = 20000;
	const SKIPPED = new Set(["script", "style", "noscript", "template", "head", "meta", "link"]);
	const INTERACTIVE = new Set([
		"button", "link", "textbox", "searchbox", "checkbox", "radio", "switch", "combobox", "listbox", "option",
		"menuitem", "menuitemcheckbox", "menuitemradio", "tab", "slider", "spinbutton", "clickable",
	]);
	// Their accessible name already says what is inside them.
	const LEAVES = new Set(["button", "link", "option", "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "checkbox", "radio", "switch", "textbox", "searchbox", "combobox", "slider", "spinbutton"]);
	const LANDMARKS = new Set(["navigation", "main", "form", "dialog", "alertdialog", "search", "banner", "contentinfo", "complementary", "region"]);

	const refs = new Map();
	const refOf = new WeakMap();
	let nextRef = 1;

	const clip = (text, max) => {
		const flat = (text ?? "").replace(/\s+/g, " ").trim();
		return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
	};
	const quote = (text) => JSON.stringify(text);

	function ref(element) {
		let id = refOf.get(element);
		if (!id) {
			id = `e${nextRef++}`;
			refOf.set(element, id);
		}
		refs.set(id, element);
		return id;
	}

	function resolve(id) {
		const element = refs.get(id);
		if (!element || !element.isConnected) throw new Error(`There is no element ${id} on the current page. Take a new browser_snapshot.`);
		return element;
	}

	function roleOf(element) {
		const explicit = element.getAttribute("role");
		if (explicit) return explicit.trim().split(/\s+/)[0];
		const tag = element.localName;
		switch (tag) {
			case "a": return element.hasAttribute("href") ? "link" : null;
			case "button": case "summary": return "button";
			case "select": return element.multiple || element.size > 1 ? "listbox" : "combobox";
			case "textarea": return "textbox";
			case "option": return "option";
			case "img": return element.getAttribute("alt") ? "img" : null;
			case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
			case "nav": return "navigation";
			case "main": return "main";
			case "form": return "form";
			case "dialog": return "dialog";
			case "search": return "search";
			case "iframe": return "iframe";
			case "input":
				switch ((element.getAttribute("type") ?? "text").toLowerCase()) {
					case "hidden": return null;
					case "button": case "submit": case "reset": case "image": return "button";
					case "checkbox": return "checkbox";
					case "radio": return "radio";
					case "range": return "slider";
					case "number": return "spinbutton";
					case "search": return "searchbox";
					default: return "textbox";
				}
		}
		if (element.isContentEditable && element.hasAttribute("contenteditable")) return "textbox";
		return null;
	}

	function visible(element) {
		if (element.getAttribute("aria-hidden") === "true") return false;
		if (!element.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true })) return false;
		return true;
	}

	function sized(element) {
		const rect = element.getBoundingClientRect();
		return rect.width > 0 && rect.height > 0;
	}

	/** Pages often make divs clickable with a pointer cursor and a script handler; count the outermost one. */
	function clickable(element) {
		if (element.hasAttribute("onclick")) return true;
		const tabIndex = element.getAttribute("tabindex");
		if (tabIndex !== null && Number(tabIndex) >= 0) return true;
		if (getComputedStyle(element).cursor !== "pointer") return false;
		const parent = element.parentElement;
		return !parent || getComputedStyle(parent).cursor !== "pointer";
	}

	function nameOf(element) {
		const labelledBy = element.getAttribute("aria-labelledby");
		if (labelledBy) {
			const text = labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.innerText ?? "").join(" ").trim();
			if (text) return text;
		}
		const label = element.getAttribute("aria-label");
		if (label?.trim()) return label;
		if (element.labels?.length) {
			const text = [...element.labels].map((each) => each.innerText).join(" ").trim();
			if (text) return text;
		}
		const tag = element.localName;
		if (tag === "img" || (tag === "input" && element.type === "image")) return element.getAttribute("alt") ?? "";
		if (tag === "input" && ["button", "submit", "reset"].includes(element.type)) return element.value || element.type;
		if (tag !== "input" && tag !== "textarea" && tag !== "select") {
			const text = element.innerText ?? element.textContent ?? "";
			if (text.trim()) return text;
			const image = element.querySelector("img[alt]");
			if (image) return image.getAttribute("alt");
		}
		return element.getAttribute("placeholder") ?? element.getAttribute("title") ?? "";
	}

	function shortHref(element) {
		const href = element.getAttribute("href");
		if (!href || href.startsWith("javascript:") || href === "#") return "";
		try {
			const url = new URL(element.href);
			const path = clip(url.pathname + url.search, 60);
			return url.origin === location.origin ? path : clip(url.host + path, 70);
		} catch {
			return "";
		}
	}

	function describe(element, role) {
		let line = `${role} ${quote(clip(nameOf(element), 100))}`;
		const tag = element.localName;
		if (["textbox", "searchbox", "spinbutton", "slider"].includes(role)) {
			// A value from the vault (fillSecret) is never shown to the agent.
			if (element.dataset?.piVault) line += ` [filled from the vault: ${element.dataset.piVault}]`;
			else if (element.type === "password") line += ` [password${element.value ? ", filled" : ""}]`;
			else line += ` value=${quote(clip(tag === "input" || tag === "textarea" ? element.value : element.innerText, 80))}`;
		}
		if (tag === "select") {
			line += ` value=${quote(clip(element.selectedOptions[0]?.text ?? "", 60))}`;
			const options = [...element.options].slice(0, 12).map((option) => clip(option.text, 30));
			line += ` options=${quote(options.join(" | "))}${element.options.length > 12 ? "…" : ""}`;
		}
		const checked = element.checked ?? element.getAttribute("aria-checked") === "true";
		if (["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].includes(role) && checked) line += " [checked]";
		if (element.getAttribute("aria-selected") === "true") line += " [selected]";
		if (element.disabled || element.getAttribute("aria-disabled") === "true") line += " [disabled]";
		const expanded = element.getAttribute("aria-expanded");
		if (expanded) line += expanded === "true" ? " [expanded]" : " [collapsed]";
		if (role === "link") {
			const href = shortHref(element);
			if (href) line += ` → ${href}`;
		}
		return `${line} [ref=${ref(element)}]`;
	}

	/** Collects the snapshot's lines, merging inline text into paragraphs. */
	class Outline {
		lines = [];
		chars = 0;
		text = "";
		full = false;

		add(depth, line) {
			if (this.full) return;
			const indented = `${"  ".repeat(depth)}- ${line}`;
			this.chars += indented.length + 1;
			if (this.chars > MAX_SNAPSHOT_CHARS) {
				this.full = true;
				return;
			}
			this.lines.push(indented);
		}

		flush(depth) {
			const text = clip(this.text, 300);
			this.text = "";
			if (text) this.add(depth, `text: ${text}`);
		}
	}

	function children(node) {
		if (node.shadowRoot) return node.shadowRoot.childNodes;
		if (node.localName === "slot") return node.assignedNodes({ flatten: true });
		return node.childNodes;
	}

	function walk(node, depth, outline) {
		for (const child of children(node)) {
			if (outline.full) return;
			if (child.nodeType === Node.TEXT_NODE) {
				outline.text += child.textContent;
			} else if (child.nodeType === Node.ELEMENT_NODE) {
				visit(child, depth, outline);
			}
		}
	}

	function visit(element, depth, outline) {
		const tag = element.localName;
		if (SKIPPED.has(tag) || !visible(element)) return;
		let role = roleOf(element);
		if (!role && clickable(element) && sized(element)) role = "clickable";

		if (role === "iframe") {
			outline.flush(depth);
			let document_ = null;
			try {
				document_ = element.contentDocument;
			} catch {}
			if (document_?.body) {
				outline.add(depth, `iframe ${quote(clip(element.title || element.name || "", 60))}:`);
				walk(document_.body, depth + 1, outline);
				outline.flush(depth + 1);
			} else {
				outline.add(depth, `iframe ${quote(clip(element.title || element.src, 80))} (another site; its content is not visible to you)`);
			}
			return;
		}
		if (role && INTERACTIVE.has(role)) {
			if (!sized(element) && role !== "option") return;
			outline.flush(depth);
			outline.add(depth, describe(element, role));
			if (!LEAVES.has(role)) {
				walk(element, depth + 1, outline);
				outline.flush(depth + 1);
			}
			return;
		}
		if (role === "heading") {
			outline.flush(depth);
			const level = Number(element.getAttribute("aria-level") ?? tag.slice(1)) || 2;
			outline.add(depth, `heading ${quote(clip(nameOf(element), 150))} [level=${level}]`);
			return;
		}
		if (role === "img") {
			outline.flush(depth);
			outline.add(depth, `img ${quote(clip(nameOf(element), 100))}`);
			return;
		}
		if (role && LANDMARKS.has(role)) {
			outline.flush(depth);
			const label = element.getAttribute("aria-label");
			outline.add(depth, `${role}${label ? ` ${quote(clip(label, 60))}` : ""}:`);
			walk(element, depth + 1, outline);
			outline.flush(depth + 1);
			return;
		}
		const display = getComputedStyle(element).display;
		const inline = display.startsWith("inline") || display === "contents";
		if (!inline) outline.flush(depth);
		walk(element, depth, outline);
		if (!inline) outline.flush(depth);
	}

	function header() {
		const scroller = document.scrollingElement ?? document.documentElement;
		const scrollable = Math.max(0, scroller.scrollHeight - innerHeight);
		const position = scrollable === 0 ? "the whole page fits on screen" : `scrolled ${Math.round((scroller.scrollTop / scrollable) * 100)}% down`;
		return `Page: ${document.title || "(untitled)"}\nURL: ${location.href}\nView: ${position}`;
	}

	function snapshot() {
		const outline = new Outline();
		if (document.body) {
			walk(document.body, 0, outline);
			outline.flush(0);
		}
		let text = `${header()}\n\n${outline.lines.join("\n") || "(the page is empty)"}`;
		if (outline.full) text += "\n… (truncated; use browser_read for the text, or browser_scroll and snapshot again)";
		return text;
	}

	function read(offset = 0) {
		const main = document.querySelector("main, article, [role=main]");
		const source = main && main.innerText.length > 500 ? main : document.body;
		const text = (source?.innerText ?? "").replace(/\n{3,}/g, "\n\n").trim();
		const chunk = text.slice(offset, offset + MAX_READ_CHARS);
		let result = `Page: ${document.title || "(untitled)"}\nURL: ${location.href}\n\n${chunk}`;
		if (offset + MAX_READ_CHARS < text.length) {
			result += `\n… (${text.length - offset - MAX_READ_CHARS} more characters; call browser_read with offset ${offset + MAX_READ_CHARS})`;
		}
		return result;
	}

	const nextFrame = () => new Promise((resolve_) => requestAnimationFrame(() => resolve_()));

	function center(element) {
		const rect = element.getBoundingClientRect();
		return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
	}

	async function click(id) {
		const element = resolve(id);
		element.scrollIntoView({ block: "center", inline: "center" });
		await nextFrame();
		const { x, y } = center(element);
		const top = document.elementFromPoint(x, y);
		const covered = top && top !== element && !element.contains(top) && !top.contains(element);
		const mouse = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window, button: 0 };
		const pointer = { ...mouse, pointerId: 1, pointerType: "touch", isPrimary: true };
		element.dispatchEvent(new PointerEvent("pointerdown", pointer));
		element.dispatchEvent(new MouseEvent("mousedown", mouse));
		element.focus?.({ preventScroll: true });
		element.dispatchEvent(new PointerEvent("pointerup", pointer));
		element.dispatchEvent(new MouseEvent("mouseup", mouse));
		element.click();
		return covered ? `${quote(clip(nameOf(top) || top.localName, 60))} covers that element on screen; the click went to the element itself.` : "";
	}

	const textInput = (element) =>
		element.localName === "textarea" ||
		(element.localName === "input" && !["checkbox", "radio", "button", "submit", "reset", "image", "file", "range", "color", "hidden"].includes(element.type));

	function setValue(element, value) {
		const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), "value")?.set;
		if (setter) setter.call(element, value);
		else element.value = value;
		element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
	}

	function pressEnterOn(element) {
		const key = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
		const proceed = element.dispatchEvent(new KeyboardEvent("keydown", key));
		element.dispatchEvent(new KeyboardEvent("keypress", key));
		element.dispatchEvent(new KeyboardEvent("keyup", key));
		// Implicit submission, as a browser does when Enter is pressed in a form's text field.
		if (proceed && element.localName === "input" && element.form) element.form.requestSubmit();
	}

	async function type(id, text, submit) {
		const element = resolve(id);
		element.scrollIntoView({ block: "center" });
		await nextFrame();
		element.focus();
		if (textInput(element)) {
			// Select what is there and insert over it, so the page sees ordinary editing input events.
			let inserted = false;
			try {
				element.select();
				inserted = document.execCommand("insertText", false, text);
			} catch {}
			if (!inserted || element.value !== text) setValue(element, text);
			element.dispatchEvent(new Event("change", { bubbles: true }));
		} else if (element.isContentEditable) {
			const range = document.createRange();
			range.selectNodeContents(element);
			const selection = getSelection();
			selection.removeAllRanges();
			selection.addRange(range);
			if (!document.execCommand("insertText", false, text)) element.textContent = text;
		} else {
			throw new Error(`${id} is not a text field.`);
		}
		if (submit) pressEnterOn(element);
		return "";
	}

	function select(id, choice) {
		const element = resolve(id);
		if (element.localName !== "select") throw new Error(`${id} is not a <select>; click it, then click the option.`);
		const wanted = choice.trim().toLowerCase();
		const option = [...element.options].find((each) => each.value.toLowerCase() === wanted || each.text.trim().toLowerCase() === wanted);
		if (!option) throw new Error(`${id} has no option ${quote(choice)}.`);
		element.value = option.value;
		element.dispatchEvent(new Event("input", { bubbles: true }));
		element.dispatchEvent(new Event("change", { bubbles: true }));
		return "";
	}

	function focusable() {
		return [...document.querySelectorAll("a[href], button, input, select, textarea, [tabindex], [contenteditable]")].filter(
			(element) => !element.disabled && element.tabIndex >= 0 && visible(element) && sized(element),
		);
	}

	function press(key) {
		const target = document.activeElement ?? document.body;
		switch (key) {
			case "Enter":
				pressEnterOn(target);
				return "";
			case "Tab": {
				const elements = focusable();
				const next = elements[(elements.indexOf(target) + 1) % Math.max(1, elements.length)];
				next?.focus();
				return "";
			}
			case "PageDown":
			case "PageUp":
				scrollBy({ top: (key === "PageDown" ? 1 : -1) * innerHeight * 0.85 });
				return "";
		}
		const codes = { Escape: 27, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Space: 32 };
		const event = { key: key === "Space" ? " " : key, code: key, keyCode: codes[key], which: codes[key], bubbles: true, cancelable: true, composed: true };
		const proceed = target.dispatchEvent(new KeyboardEvent("keydown", event));
		if (proceed && key === "Backspace" && (textInput(target) || target.isContentEditable)) document.execCommand("delete");
		target.dispatchEvent(new KeyboardEvent("keyup", event));
		return "";
	}

	function scroll(direction, id) {
		if (id) {
			resolve(id).scrollIntoView({ block: "center" });
			return "";
		}
		const amount = (direction === "up" ? -1 : 1) * innerHeight * 0.85;
		const page = document.scrollingElement ?? document.documentElement;
		if (page.scrollHeight > innerHeight + 4) {
			scrollBy({ top: amount });
			return "";
		}
		// The page itself does not scroll: scroll its largest scrollable area instead.
		const areas = [...document.querySelectorAll("body *")].filter((element) => {
			const style = getComputedStyle(element);
			return /(auto|scroll)/.test(style.overflowY) && element.scrollHeight > element.clientHeight + 4;
		});
		areas.sort((a, b) => b.clientHeight * b.clientWidth - a.clientHeight * a.clientWidth);
		if (areas[0]) areas[0].scrollBy({ top: amount });
		return areas[0] ? "" : "Nothing on this page scrolls.";
	}

	async function wait(text, id, seconds) {
		const limit = Math.min(30, Math.max(1, seconds ?? 10));
		const deadline = Date.now() + limit * 1000;
		const wanted = text?.toLowerCase();
		while (Date.now() < deadline) {
			if (wanted && document.body?.innerText.toLowerCase().includes(wanted)) return `Found ${quote(text)}.`;
			if (id && refs.get(id)?.isConnected && visible(refs.get(id))) return `${id} is on the page.`;
			await new Promise((resolve_) => setTimeout(resolve_, 250));
		}
		return `Gave up after ${limit} s: ${wanted ? quote(text) : id} did not appear.`;
	}

	/** A value from the vault (pi's native fill): typed as usual, then masked on screen and in snapshots. */
	async function fillSecret(id, value, hint) {
		await type(id, value, false);
		const element = resolve(id);
		element.dataset.piVault = hint;
		element.style.setProperty("-webkit-text-security", "disc");
		return "";
	}

	return { snapshot, read, click, type, select, press, scroll, wait, fillSecret };
})();
