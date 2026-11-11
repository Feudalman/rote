import { createConnection } from "node:net";
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// pi → toast 桥：每次会话 settle 后往 socket 写一行 JSON
// `pi` 段与 server 读同一个配置，走同一条搜索链

const CONFIG_CANDIDATES = [
	join(homedir(), "Library/Application Support/Toast/config.json"),
	join(homedir(), ".config/pi-toast/config.json"),
	"/Library/Application Support/Toast/config.json",
];

const CONFIG_PATH = process.env.PI_TOAST_CONFIG
	? process.env.PI_TOAST_CONFIG
	: CONFIG_CANDIDATES.find((p) => existsSync(p)) ?? CONFIG_CANDIDATES[0];

type PiConfig = {
	enabled: boolean;
	socket: string;
	minRunSeconds: number;
	skipAborted: boolean;
	modes: string[];
	duration: number;
	title: string;
	body: string;
	warnOnFailure: boolean;
	summaryMode: "lastMessage" | "model" | "off";
	summaryMaxChars: number;
	summaryModel: string;
	summaryTimeoutMs: number;
};

const DEFAULTS: PiConfig = {
	enabled: true,
	socket: "~/.pi-toast/toast.sock",
	minRunSeconds: 3,
	skipAborted: true,
	modes: ["tui"],
	duration: 10,
	title: "Pi · {project}",
	body: "{summary}",
	warnOnFailure: false,
	summaryMode: "lastMessage",
	summaryMaxChars: 45,
	summaryModel: "",
	summaryTimeoutMs: 10000,
};

function expand(p: string): string {
	return p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

function loadConfig(): PiConfig {
	let raw: Record<string, unknown> = {};
	try {
		raw = JSON.parse(readFileSync(expand(CONFIG_PATH), "utf8"));
	} catch {
		return DEFAULTS;
	}
	const pi = (raw.pi ?? {}) as Partial<PiConfig>;
	return {
		...DEFAULTS,
		...(pi as PiConfig),
		socket: expand(pi.socket ?? DEFAULTS.socket),
		modes: Array.isArray(pi.modes) ? pi.modes : DEFAULTS.modes,
	};
}

// 未知占位符直接丢掉：模板写错时不能把字面的 {summary} 印到屏幕上
function render(template: string, vars: Record<string, string>): string {
	const unknown: string[] = [];
	const out = template.replace(/\{(\w+)\}/g, (match, key: string) => {
		if (key in vars) return vars[key];
		unknown.push(key);
		return "";
	});
	if (unknown.length && process.env.PI_TOAST_DEBUG) {
		console.error(`[toast] unknown placeholders: ${unknown.join(", ")}`);
	}
	return out.replace(/[ \t]{2,}/g, " ").trim();
}

// MARK: - 摘要

type Entry = {
	type?: string;
	message?: { role?: string; content?: unknown };
};

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const block of content) {
		if (!block || typeof block !== "object") continue;
		const b = block as { type?: string; text?: string };
		if (b.type === "text" && typeof b.text === "string") parts.push(b.text);
	}
	return parts.join("\n");
}

function toolNames(content: unknown): string[] {
	if (!Array.isArray(content)) return [];
	const names: string[] = [];
	for (const block of content) {
		if (!block || typeof block !== "object") continue;
		const b = block as { type?: string; name?: string };
		if (b.type === "toolCall" && typeof b.name === "string") names.push(b.name);
	}
	return names;
}

// 压成一行、去 markdown、去前导符号：这些字最终只占 340pt 的卡片
function tidy(text: string, maxChars: number): string {
	let out = text
		.replace(/```[\s\S]*?```/g, " ")
		.replace(/`([^`]*)`/g, "$1")
		.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/^\s*(?:[-*+>]|\d+\.)\s+/gm, "")
		.replace(/^#{1,6}\s*/gm, "")
		.replace(/[*_~]{1,3}/g, "")
		.replace(/\s+/g, " ")
		.trim();
	if (!out) return "";
	if (out.length > maxChars) {
		const cut = out.slice(0, maxChars);
		const stop = Math.max(cut.lastIndexOf("。"), cut.lastIndexOf("；"), cut.lastIndexOf(". "));
		out = `${(stop > maxChars * 0.5 ? cut.slice(0, stop + 1) : cut).trimEnd()}…`;
	}
	return out;
}

function lastAssistantText(entries: Entry[]): string {
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
		const text = textOf(entry.message.content).trim();
		if (text) return text;
	}
	return "";
}

// 给模型的摘要素材：用户问了什么、agent 答了什么、碰过哪些工具
// 要有上限，长会话不能把 prompt 撑爆
function buildDigest(entries: Entry[], budget = 6000): string {
	const lines: string[] = [];
	for (const entry of entries) {
		if (entry.type !== "message") continue;
		const role = entry.message?.role;
		if (role !== "user" && role !== "assistant") continue;
		const text = textOf(entry.message.content).trim();
		const tools = role === "assistant" ? toolNames(entry.message.content) : [];
		if (text) lines.push(`${role}: ${text}`);
		if (tools.length) lines.push(`  tools: ${[...new Set(tools)].join(", ")}`);
	}
	const joined = lines.join("\n");
	return joined.length > budget ? joined.slice(-budget) : joined;
}

async function summarizeWithModel(ctx: ExtensionContext, config: PiConfig, digest: string): Promise<string> {
	const registry = ctx.modelRegistry as unknown as {
		find(provider: string, id: string): unknown;
		hasConfiguredAuth(model: unknown): boolean;
		complete(model: unknown, args: unknown, options: unknown): Promise<{ content: unknown }>;
	};

	let model: unknown = ctx.model;
	if (config.summaryModel.includes("/")) {
		const slash = config.summaryModel.indexOf("/");
		model = registry.find(config.summaryModel.slice(0, slash), config.summaryModel.slice(slash + 1));
	}
	if (!model || !registry.hasConfiguredAuth(model)) return "";

	const prompt = [
		"下面是一段编码会话记录。用一句中文总结这次会话完成了什么，",
		"不超过 40 个字，直接给结论，不要 markdown、不要引号、不要“本次会话”这类开头。",
		"",
		digest,
	].join("\n");

	const call = registry.complete(
		model,
		{ messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }] },
		{ cacheRetention: "none" },
	);

	const timeout = new Promise<null>((resolve) => setTimeout(() => resolve(null), config.summaryTimeoutMs));
	const response = await Promise.race([call, timeout]);
	if (!response) return "";
	return textOf((response as { content: unknown }).content).trim();
}

async function buildSummary(ctx: ExtensionContext, config: PiConfig): Promise<string> {
	if (config.summaryMode === "off") return "";
	const entries = ctx.sessionManager.getBranch() as unknown as Entry[];
	if (!entries.length) return "";

	if (config.summaryMode === "model") {
		const digest = buildDigest(entries);
		if (!digest.trim()) return "";
		try {
			const generated = await summarizeWithModel(ctx, config, digest);
			const tidyGenerated = tidy(generated, config.summaryMaxChars);
			if (tidyGenerated) return tidyGenerated;
		} catch {
			// 回退到不花钱的方案
		}
	}
	return tidy(lastAssistantText(entries), config.summaryMaxChars);
}

// MARK: - 传输

function send(socketPath: string, payload: unknown): Promise<void> {
	return new Promise((resolve, reject) => {
		const sock = createConnection({ path: socketPath });
		const fail = (err: Error) => {
			sock.destroy();
			reject(err);
		};
		sock.once("error", fail);
		sock.once("connect", () => {
			sock.end(`${JSON.stringify(payload)}\n`, () => {
				sock.off("error", fail);
				resolve();
			});
		});
	});
}

export default function (pi: ExtensionAPI) {
	let startedAt: number | null = null;
	let toolCalls = 0;
	let warned = false;

	pi.on("agent_start", async () => {
		if (startedAt === null) startedAt = Date.now();
		toolCalls = 0;
	});

	pi.on("tool_call", async () => {
		toolCalls += 1;
	});

	pi.on("agent_settled", async (event, ctx: ExtensionContext) => {
		const elapsed = startedAt === null ? 0 : (Date.now() - startedAt) / 1000;
		startedAt = null;
		const calls = toolCalls;
		toolCalls = 0;

		const config = loadConfig();
		const debug = (msg: string) => {
			if (process.env.PI_TOAST_DEBUG) console.error(`[toast] ${msg}`);
		};
		debug(`settle elapsed=${elapsed.toFixed(1)}s aborted=${event.aborted} mode=${ctx.mode}`);

		if (!config.enabled) return debug("disabled");
		if (config.skipAborted && event.aborted) return;
		if (elapsed < config.minRunSeconds) return;
		if (!config.modes.includes(ctx.mode)) return;

		const cwd = ctx.cwd;
		const sessionFile = ctx.sessionManager.getSessionFile() ?? "";
		const sessionId = ctx.sessionManager.getSessionId() ?? "";
		const name = ctx.sessionManager.getSessionName();

		let summary = "";
		try {
			summary = await buildSummary(ctx, config);
		} catch {
			summary = "";
		}

		const vars: Record<string, string> = {
			project: basename(cwd) || "pi",
			cwd,
			session: name || (sessionId ? sessionId.slice(0, 8) : "session"),
			sessionFile,
			duration: String(Math.round(elapsed)),
			tools: String(calls),
			model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : "",
			summary: summary || `${name || "session"} · ${Math.round(elapsed)}s`,
		};

		const payload = {
			source: "pi",
			title: render(config.title, vars) || `Pi · ${vars.project}`,
			body: render(config.body, vars) || `${vars.session} · ${vars.duration}s`,
			duration: config.duration,
		};

		debug(`send -> ${config.socket} ${JSON.stringify(payload)}`);
		try {
			await send(config.socket, payload);
			debug("sent");
		} catch (err) {
			debug(`send failed: ${(err as Error).message}`);
			if (config.warnOnFailure && !warned) {
				warned = true;
				ctx.ui.notify(`toast 发送失败: ${(err as Error).message}`, "warning");
			}
		}
	});
}
