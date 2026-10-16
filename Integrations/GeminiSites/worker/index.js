import { RelayQueue, relayGeneration } from "./queue.js";

const requestHeaders = ["content-type", "accept", "mcp-session-id", "mcp-protocol-version",
  "mcp-method", "mcp-name", "last-event-id"];
const responseHeaders = ["content-type", "mcp-session-id", "mcp-protocol-version"];
const requestLimit = 1024 * 1024;
const responseLimit = 8 * requestLimit;

function reply(status, message) {
  return new Response(message, { status, headers: {
    "content-type": "text/plain; charset=utf-8", "cache-control": "no-store",
    "referrer-policy": "no-referrer", "x-content-type-options": "nosniff",
  } });
}

function equalSecret(actual, expected) {
  if (typeof actual !== "string" || actual.length !== expected.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) mismatch |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
  return mismatch === 0;
}

function selectHeaders(source, names) {
  const headers = new Headers(source);
  return Object.fromEntries(names.filter(name => headers.has(name)).map(name => [name, headers.get(name)]));
}

async function limitedBody(request, limit) {
  if (Number(request.headers.get("content-length")) > limit) throw new RangeError();
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > limit) { await reader.cancel(); throw new RangeError(); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

function encode(bytes) {
  let result = "";
  for (let offset = 0; offset < bytes.length; offset += 16384) {
    result += String.fromCharCode(...bytes.subarray(offset, offset + 16384));
  }
  return btoa(result);
}

function decode(value, limit) {
  if (typeof value !== "string" || value.length > Math.ceil(limit / 3) * 4) throw new RangeError();
  if (value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new TypeError();
  }
  const binary = atob(value);
  if (binary.length > limit) throw new RangeError();
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function jsonBody(request, limit) {
  return JSON.parse(new TextDecoder().decode(await limitedBody(request, limit)));
}

async function poll(request, queue) {
  const body = await jsonBody(request, 1024);
  const limit = Number.isInteger(body.limit) ? Math.max(1, Math.min(4, body.limit)) : 4;
  return Response.json({ requests: await queue.claim(limit) }, { headers: { "cache-control": "no-store" } });
}

async function complete(request, queue) {
  const result = await jsonBody(request, Math.ceil(responseLimit / 3) * 4 + 16384);
  if (typeof result.id !== "string" || result.id.length > 64 ||
      !Number.isInteger(result.status) || result.status < 200 || result.status > 599) throw new TypeError();
  const bytes = decode(result.body, responseLimit);
  if ([204, 205, 304].includes(result.status) && bytes.length) throw new TypeError();
  result.headers = selectHeaders(result.headers, responseHeaders);
  return await queue.complete(result) ? new Response(null, { status: 204 }) : reply(404, "Request unavailable");
}

async function forward(request, queue) {
  if (!["POST", "DELETE"].includes(request.method)) {
    const response = reply(405, "Method not allowed");
    response.headers.set("allow", "POST, DELETE");
    return response;
  }
  const body = encode(await limitedBody(request, requestLimit));
  const id = await queue.enqueue({ method: request.method,
    headers: selectHeaders(request.headers, requestHeaders), body });
  if (!id) return reply(429, "Relay queue full");
  const deadline = Date.now() + 310_000;
  let delay = 500;
  while (Date.now() < deadline && !request.signal.aborted) {
    const result = await queue.response(id);
    if (result) {
      const bytes = decode(result.body, responseLimit);
      return new Response([204, 205, 304].includes(result.status) ? null : bytes,
        { status: result.status, headers: { ...result.headers, "cache-control": "no-store" } });
    }
    await new Promise(resolve => setTimeout(resolve, Math.min(delay, Math.max(0, deadline - Date.now()))));
    delay = Math.min(delay * 2, 10_000);
  }
  return reply(504, "Bridge did not return a result in time");
}

async function handle(request, env) {
  const path = new URL(request.url).pathname;
  if (path === "/" && request.method === "GET") {
    return reply(200, "Codex Bridge · Gemini Cloud MCP\n在 Codex Bridge 中配置此公开 Site 的地址，再复制 Gemini 连接链接。\n本机 Bridge 须保持运行。\n");
  }
  const keyPattern = /^[a-f0-9]{64}$/;
  if (!keyPattern.test(env.BRIDGE_MCP_KEY ?? "") || !keyPattern.test(env.BRIDGE_RELAY_KEY ?? "") ||
      env.BRIDGE_MCP_KEY === env.BRIDGE_RELAY_KEY || !env.DB) return reply(503, "Relay not configured");
  if (path.startsWith("/gemini-mcp/")) {
    if (!equalSecret(path.slice("/gemini-mcp/".length), env.BRIDGE_MCP_KEY)) return reply(404, "Not found");
    const queue = new RelayQueue(env.DB, await relayGeneration(env.BRIDGE_MCP_KEY, env.BRIDGE_RELAY_KEY));
    return forward(request, queue);
  }
  if (["/api/bridge/poll", "/api/bridge/complete"].includes(path)) {
    if (!equalSecret(request.headers.get("authorization"), `Bearer ${env.BRIDGE_RELAY_KEY}`)) {
      return reply(401, "Unauthorized");
    }
    if (request.method !== "POST") return reply(405, "Method not allowed");
    const queue = new RelayQueue(env.DB, await relayGeneration(env.BRIDGE_MCP_KEY, env.BRIDGE_RELAY_KEY));
    return path.endsWith("/poll") ? poll(request, queue) : complete(request, queue);
  }
  return reply(404, "Not found");
}

export default {
  async fetch(request, env) {
    try { return await handle(request, env); }
    catch (error) {
      if (error instanceof RangeError) return reply(413, "Payload too large");
      if (error instanceof TypeError || error instanceof SyntaxError) return reply(400, "Invalid request");
      return reply(503, "Relay unavailable");
    }
  },
};
