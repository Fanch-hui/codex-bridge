import { createHash } from "node:crypto";
import {
  Client, StdioClientTransport, StreamableHTTPClientTransport, Type,
} from "./mcp-client-sdk.mjs";

const maximumServers = 64;
const maximumTools = 128;
const maximumSchemaBytes = 48 * 1024;
const maximumOutputBytes = 256 * 1024;
const transportLimitBytes = 2 * 1024 * 1024;
const requestTimeoutMs = 120_000;

export async function registerMCPTools(pi, policy, context) {
  if (context.mcpServers.length > maximumServers) throw new Error("Too many Pi MCP servers.");
  if (context.mcpServers.length && (context.mode !== "workspace-write" || !context.networkAllowed)) {
    throw new Error("Pi MCP tools require explicit network access in Write mode.");
  }
  const servers = [];
  let registeredCount = 0;
  for (let offset = 0; offset < context.mcpServers.length; offset += 8) {
    const batch = context.mcpServers.slice(offset, offset + 8);
    const results = await Promise.all(batch.map(server => connectServer(server, context.projectRoot)));
    for (const result of results) {
      if (!result.client) {
        servers.push({ id: result.id, client: undefined, toolCount: 0, failed: true });
        continue;
      }
      const accepted = [];
      try {
        for (const tool of result.tools) {
          if (registeredCount >= maximumTools) break;
          const name = mcpToolName(result.id, tool.name);
          if (policy.registerMCPTool(name, result.id, result.name, tool.name)) {
            const schema = sanitizeSchema(tool.inputSchema);
            pi.registerTool({
              name,
              label: bounded(tool.title ?? tool.name, 128),
              description: toolDescription(result.name, tool),
              parameters: Type.Unsafe(schema),
              execute: async (_id, args, signal) => invokeTool(
                result.client, tool.name, args, signal, context.taskID,
              ),
            });
            accepted.push(tool.name);
            registeredCount += 1;
          }
        }
        servers.push({ id: result.id, name: result.name, client: result.client,
          toolCount: accepted.length, failed: false });
      } catch (error) {
        await closeQuietly(result.client);
        for (const name of accepted) policy.unregisterMCPTool(mcpToolName(result.id, name));
        registeredCount -= accepted.length;
        servers.push({ id: result.id, name: result.name, client: undefined,
          toolCount: 0, failed: true });
      }
    }
  }
  const state = {
    connectedServerIDs: servers.filter(server => !server.failed).map(server => server.id),
    failedServerIDs: servers.filter(server => server.failed).map(server => server.id),
    toolCount: registeredCount,
  };
  return {
    state,
    activeTools: policy.activeToolNames(),
    async close() { await Promise.all(servers.map(server => closeQuietly(server.client))); },
  };
}

async function connectServer(server, cwd) {
  let client;
  try {
    const transport = server.transport === "stdio"
      ? new StdioClientTransport({
        command: server.command,
        args: server.args,
        env: server.environment,
        cwd,
        stderr: "ignore",
        maxBufferSize: transportLimitBytes,
      })
      : new StreamableHTTPClientTransport(new URL(server.url), {
        requestInit: { headers: server.headers, redirect: "error" },
        fetch: limitedFetch,
      });
    client = new Client({ name: "codex-bridge-pi", version: "1.0.0" }, { capabilities: {} });
    await client.connect(transport, { signal: AbortSignal.timeout(8_000) });
    const tools = await listTools(client);
    return { id: server.id, name: server.name, client, tools };
  } catch {
    await closeQuietly(client);
    return { id: server.id, name: server.name, client: undefined, tools: [] };
  }
}

async function listTools(client) {
  const tools = [];
  let cursor;
  do {
    const page = await client.listTools(cursor ? { cursor } : undefined, {
      signal: AbortSignal.timeout(8_000),
    });
    if (!Array.isArray(page.tools) || page.tools.length > maximumTools) {
      throw new Error("Invalid MCP tool catalog.");
    }
    tools.push(...page.tools);
    if (tools.length > maximumTools) throw new Error("MCP tool catalog exceeds its limit.");
    cursor = page.nextCursor;
  } while (cursor && tools.length < maximumTools);
  return tools;
}

function sanitizeSchema(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || value.type !== "object") throw new Error("MCP tools require an object input schema.");
  const encoded = JSON.stringify(value);
  if (Buffer.byteLength(encoded) > maximumSchemaBytes) throw new Error("MCP tool schema is too large.");
  const visit = (item, depth, nodes) => {
    if (depth > 16 || ++nodes.count > 1_024) throw new Error("MCP tool schema is too complex.");
    if (Array.isArray(item)) {
      for (const child of item) visit(child, depth + 1, nodes);
    } else if (item && typeof item === "object") {
      for (const [key, child] of Object.entries(item)) {
        if (key === "$ref" && typeof child === "string" && !child.startsWith("#/")) {
          throw new Error("External MCP schema references are unsupported.");
        }
        visit(child, depth + 1, nodes);
      }
    } else if (typeof item === "string" && (item.includes("\0") || item.length > 8_192)) {
      throw new Error("MCP tool schema string is invalid.");
    }
  };
  visit(value, 0, { count: 0 });
  return value;
}

async function invokeTool(client, toolName, args, signal, taskID) {
  const timer = AbortSignal.timeout(requestTimeoutMs);
  const combinedSignal = signal ? AbortSignal.any([signal, timer]) : timer;
  try {
    const result = await client.callTool({ name: toolName, arguments: args }, undefined, {
      signal: combinedSignal,
    });
    if (result.isError) throw new Error("MCP server reported a tool error.");
    const content = normalizeContent(result.content);
    const details = { bridgeMCP: { revision: 1, taskID, toolName } };
    return { content, details };
  } catch (error) {
    if (combinedSignal.aborted) throw new Error("The MCP tool call was cancelled or timed out.");
    throw new Error("The configured MCP server did not complete this tool call.");
  }
}

function normalizeContent(value) {
  if (!Array.isArray(value) || value.length > 64) throw new Error("Invalid MCP tool output.");
  const content = [];
  let remaining = maximumOutputBytes;
  for (const block of value) {
    if (block?.type === "text" && typeof block.text === "string") {
      const text = boundedBytes(block.text, remaining);
      remaining -= Buffer.byteLength(text);
      if (text) content.push({ type: "text", text });
    } else if (block?.type === "image" && typeof block.data === "string"
        && typeof block.mimeType === "string" && block.data.length <= remaining * 1.34) {
      const bytes = Buffer.from(block.data, "base64");
      if (bytes.length <= remaining) {
        remaining -= bytes.length;
        content.push({ type: "image", data: block.data, mimeType: block.mimeType });
      }
    }
    if (remaining <= 0) break;
  }
  return content.length ? content : [{ type: "text", text: "The MCP tool returned no supported content." }];
}

async function limitedFetch(input, init) {
  const response = await fetch(input, { ...init, redirect: "error" });
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > transportLimitBytes) {
    await response.body?.cancel();
    throw new Error("MCP response exceeds the transport limit.");
  }
  if (!response.body) return response;
  const reader = response.body.getReader();
  let total = 0;
  const body = new ReadableStream({
    async pull(controller) {
      const part = await reader.read();
      if (part.done) { controller.close(); return; }
      total += part.value.byteLength;
      if (total > transportLimitBytes) {
        await reader.cancel();
        controller.error(new Error("MCP response exceeds the transport limit."));
        return;
      }
      controller.enqueue(part.value);
    },
    async cancel(reason) { await reader.cancel(reason); },
  });
  return new Response(body, { status: response.status, statusText: response.statusText,
    headers: response.headers });
}

function mcpToolName(serverID, toolName) {
  const server = createHash("sha256").update(serverID).digest("hex").slice(0, 12);
  const tool = createHash("sha256").update(toolName).digest("hex").slice(0, 10);
  const slug = toolName.toLowerCase().replace(/[^a-z0-9_-]+/g, "_").slice(0, 28) || "tool";
  return `bridge_mcp_${server}_${slug}_${tool}`;
}

function toolDescription(serverName, tool) {
  const description = typeof tool.description === "string" ? bounded(tool.description, 4_096) : "";
  const title = typeof tool.title === "string" ? bounded(tool.title, 128) : tool.name;
  return `Configured MCP server: ${serverName}. Untrusted server tool: ${title}. ${description}`.slice(0, 4_096);
}

function bounded(value, maximumBytes) {
  return typeof value === "string" && Buffer.byteLength(value) <= maximumBytes
    ? value : String(value ?? "").slice(0, maximumBytes);
}

function boundedBytes(value, maximumBytes) {
  if (Buffer.byteLength(value) <= maximumBytes) return value;
  return Buffer.from(value).subarray(0, Math.max(0, maximumBytes)).toString("utf8");
}

async function closeQuietly(client) {
  try { await client?.close(); } catch { /* transport is already closed */ }
}
