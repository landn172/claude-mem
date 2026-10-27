/**
 * Companion worker for a self-hosted sync deployment:
 *   POST /internal/project      — projection endpoint the hub requires
 *   POST|GET|DELETE /mcp        — remote MCP endpoint (Streamable HTTP)
 *   .../u/<MCP_TOKEN>/mcp       — path-token form for agents without headers
 */

import { handleMcp } from "./mcp";
import { handleProject } from "./projector";

const PATH_TOKEN_MCP = /^\/u\/([^/]+)\/mcp$/;

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/internal/project" && request.method === "POST") {
			return handleProject(request, env);
		}
		if (url.pathname === "/mcp") {
			return handleMcp(request, env, null);
		}
		const pathToken = PATH_TOKEN_MCP.exec(url.pathname);
		if (pathToken) {
			return handleMcp(request, env, decodeURIComponent(pathToken[1]));
		}
		return new Response("not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;
