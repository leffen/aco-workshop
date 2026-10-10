/**
 * The workshop's tools for pi, which has no MCP support by design.
 *
 * Starts each MCP server in ACO_MCP_SERVERS over stdio, lists its tools and
 * registers every one as a pi tool that forwards the call. Run pi with
 * `--no-builtin-tools --no-extensions -e <this file>`, and these are the only
 * tools the model has: no bash, no read, no write. That is the guardrail, and
 * `generic_agent/run.py --check` asks the model to break it.
 *
 * pi has no turn limit either, so this counts turns and aborts past
 * ACO_MAX_TURNS, the way `claude --max-turns` ends a run.
 *
 * Environment, all set by generic_agent/run.py:
 *   ACO_MCP_SERVERS  JSON: [{"name", "command", "args", "env"}]
 *   ACO_MCP_EXCLUDE  comma-separated tool names never to register
 *   ACO_MAX_TURNS    turns before the run is aborted; 0 for no limit
 */
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

interface ServerSpec {
	name: string;
	command: string;
	args?: string[];
	env?: Record<string, string>;
}

interface McpTool {
	name: string;
	description?: string;
	inputSchema?: Record<string, unknown>;
}

const PROTOCOL = "2025-06-18";
const CALL_TIMEOUT_MS = 240_000;

class McpClient {
	private child: ChildProcessWithoutNullStreams;
	private nextId = 1;
	private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
	private buffer = "";

	constructor(readonly spec: ServerSpec) {
		this.child = spawn(spec.command, spec.args ?? [], {
			env: { ...process.env, ...(spec.env ?? {}) },
			stdio: ["pipe", "pipe", "pipe"],
		});
		// Split on "\n" only: MCP's stdio framing. A generic line reader also
		// splits on Unicode separators inside JSON strings.
		this.child.stdout.setEncoding("utf8");
		this.child.stdout.on("data", (chunk: string) => {
			this.buffer += chunk;
			let nl: number;
			while ((nl = this.buffer.indexOf("\n")) >= 0) {
				const line = this.buffer.slice(0, nl).trim();
				this.buffer = this.buffer.slice(nl + 1);
				if (line) this.receive(line);
			}
		});
		this.child.stderr.resume(); // drain, or a chatty server blocks
		this.child.on("exit", (code) => {
			for (const p of this.pending.values()) p.reject(new Error(`${spec.name} exited (${code})`));
			this.pending.clear();
		});
	}

	private receive(line: string) {
		let msg: any;
		try {
			msg = JSON.parse(line);
		} catch {
			return; // not JSON-RPC: ignore, as the transport allows
		}
		const p = typeof msg.id === "number" ? this.pending.get(msg.id) : undefined;
		if (!p) return;
		this.pending.delete(msg.id);
		if (msg.error) p.reject(new Error(msg.error.message ?? JSON.stringify(msg.error)));
		else p.resolve(msg.result);
	}

	request(method: string, params: unknown = {}, timeoutMs = CALL_TIMEOUT_MS): Promise<any> {
		const id = this.nextId++;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`${this.spec.name}: ${method} timed out after ${timeoutMs / 1000}s`));
			}, timeoutMs);
			this.pending.set(id, {
				resolve: (v) => (clearTimeout(timer), resolve(v)),
				reject: (e) => (clearTimeout(timer), reject(e)),
			});
			this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
		});
	}

	notify(method: string) {
		this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
	}

	async start(): Promise<McpTool[]> {
		await this.request("initialize", {
			protocolVersion: PROTOCOL,
			capabilities: {},
			clientInfo: { name: "aco-pi", version: "1" },
		}, 120_000); // npx may download the server on first use
		this.notify("notifications/initialized");
		return (await this.request("tools/list")).tools ?? [];
	}

	close() {
		this.child.kill();
	}
}

function text(result: any): string {
	return (result?.content ?? [])
		.filter((c: any) => c?.type === "text")
		.map((c: any) => c.text)
		.join("\n");
}

export default async function acoTools(pi: ExtensionAPI) {
	const specs: ServerSpec[] = JSON.parse(process.env.ACO_MCP_SERVERS ?? "[]");
	const exclude = new Set((process.env.ACO_MCP_EXCLUDE ?? "").split(",").filter(Boolean));
	const maxTurns = Number(process.env.ACO_MAX_TURNS ?? "0");
	const clients: McpClient[] = [];

	for (const spec of specs) {
		const client = new McpClient(spec);
		clients.push(client);
		for (const tool of await client.start()) {
			if (exclude.has(tool.name)) continue;
			pi.registerTool({
				name: tool.name,
				label: tool.name,
				description: tool.description ?? tool.name,
				parameters: Type.Unsafe(tool.inputSchema ?? { type: "object", properties: {} }),
				async execute(_toolCallId, params) {
					const result = await client.request("tools/call", { name: tool.name, arguments: params ?? {} });
					// A refusal or a failed write must reach pi as an error, so the
					// event stream marks it is_error, as Claude Code's does.
					if (result?.isError) throw new Error(text(result) || `${tool.name} failed`);
					return { content: [{ type: "text", text: text(result) }], details: {} };
				},
			});
		}
	}

	let turns = 0;
	pi.on("turn_start", async (_event, ctx) => {
		turns += 1;
		if (maxTurns > 0 && turns > maxTurns) {
			console.error(`aco: max turns (${maxTurns}) reached, aborting`);
			ctx.abort();
		}
	});

	pi.on("session_shutdown", async () => {
		for (const c of clients) c.close();
	});
}
