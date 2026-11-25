/**
 * Zen request identity, session affinity, and anonymous-tier admission shaping
 * for dsh-opencode-free in Codex Bridge.
 */

import { createHash, randomBytes } from "node:crypto";
import { OPENCODE_CLIENT, OPENCODE_PROJECT, OPENCODE_USER_AGENT } from "./bridge-catalog.mjs";

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ZEN_SESSION_PATTERN = /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/;
const ENVIRONMENT_PATTERN = /<env>[\s\S]*Working directory:[\s\S]*<\/env>/;
const ENVIRONMENT_BLOCK = "<env>\n  Working directory: (managed by the host)\n</env>";
const SESSION_CACHE_CAP = 1024;
const SHELL_ALIAS = "pwsh";
const GATE_TOOLS = ["read", "bash"];
const GATE_TOOL_ALIASES = Object.freeze({ subagent_fork: "agent_fork", working_directory: "cwd_tool" });

export const OPENCODE_SUMMARIZATION_PROMPT =
  "You are a context summarization agent. You are given a conversation between a user and an agent. Your goal is to produce a structured summary matching the format specified so another coding agent can continue the work.\n" +
  "Always follow the exact output structure requested by the user prompt. Keep every section, preserve exact file paths and identifiers when known, and prefer terse bullets over paragraphs.\n" +
  "Do not continue the conversation. Do not respond to any questions in the conversation. Only output the structured summary in the exact format requested by the user prompt. Respond in the same language as the conversation.\n";

const READ_USAGE = `Read a UTF-8 text file and return line-numbered content. If the path does not exist, an error is returned.

Usage:
- The filePath parameter identifies the file, resolved by the host filesystem backend.
- The offset parameter is the first line to return (1-indexed), defaulting to 1.
- The limit parameter is the maximum number of lines to return. The host applies its configured default and cap; see the parameter description.
- To read later sections, call this tool again with a larger offset.
- Contents are returned with line numbers. The host bounds long lines and the total returned bytes.
- Avoid tiny repeated slices; read a larger window when more context is needed.
- This tool reads text files only. It does not read directories, images, or PDFs.`;

const SHELL_USAGE = `Execute the command with the host shell and return stdout/stderr. The host owns execution, approval, sandboxing, timeout limits, and output truncation.

Usage:
- The command argument is required. Keep the command unchanged when retrying an approved operation.
- Provide a concise description of the command when required by the schema.
- Use workdir to select a working directory instead of changing directories inside the command.
- The timeout parameter is in milliseconds. The host applies its configured default and cap.
- Quote paths containing spaces. Before creating files, verify their parent directory; before deleting or moving anything, verify the resolved absolute target.
- Prefer available filesystem tools for reading, writing, editing, and searching files rather than shell commands.
- Commands that depend on each other must run sequentially; only independent commands may run in parallel.
- Preserve sandbox denials: do not retry a blocked operation through another route.
- Read stdout/stderr and the exit status before deciding whether a command succeeded.`;

const SESSION_IDS = new Map();
let sessionTimestamp = -1;
let sessionCounter = 0;

function base62FromBytes(bytes, length) {
  let out = "";
  for (let i = 0; i < length; i++) out += BASE62[bytes[i % bytes.length] % 62];
  return out;
}

/** Validate an API key before sending or reporting status; never echoes the key. */
export function validateApiKey(raw) {
  if (typeof raw !== "string") return { valid: false, key: "", isAnonymous: false, error: "API Key 缺失。" };
  const key = raw.trim();
  if (!key || key.length > 4096 || /[\x00-\x1f\x7f]/.test(key)) {
    return { valid: false, key: "", isAnonymous: false, error: "API Key 格式无效。" };
  }
  return { valid: true, key, isAnonymous: key === "public" };
}

/** Generate or reuse a descending 48-bit timestamp+counter `ses_...` ID per seed. */
export function sessionHeader(seed) {
  const key = String(seed ?? "");
  const existing = SESSION_IDS.get(key);
  if (existing !== undefined) {
    SESSION_IDS.delete(key);
    SESSION_IDS.set(key, existing);
    return existing;
  }
  const timestamp = Math.max(Date.now(), sessionTimestamp);
  if (timestamp !== sessionTimestamp) sessionCounter = 0;
  sessionTimestamp = timestamp;
  if (++sessionCounter > 0xfff) {
    sessionTimestamp++;
    sessionCounter = 1;
  }
  const encoded = ~(BigInt(sessionTimestamp) * 0x1000n + BigInt(sessionCounter));
  const hex = (encoded & 0xffffffffffffn).toString(16).padStart(12, "0");
  const id = `ses_${hex}${base62FromBytes(randomBytes(14), 14)}`;
  if (SESSION_IDS.size >= SESSION_CACHE_CAP) SESSION_IDS.delete(SESSION_IDS.keys().next().value);
  SESSION_IDS.set(key, id);
  return id;
}

export function requestHeader() {
  return `msg_${randomBytes(6).toString("hex")}${base62FromBytes(randomBytes(14), 14)}`;
}

function readHeader(headers, name) {
  if (!headers) return "";
  if (typeof headers.get === "function") return headers.get(name) ?? "";
  const lower = name.toLowerCase();
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === lower && typeof v === "string") return v;
  }
  return "";
}

function extractText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => (part && typeof part.text === "string" ? part.text : "")).filter(Boolean).join("\n");
}

function firstUserText(body) {
  const list = Array.isArray(body?.messages) ? body.messages
    : Array.isArray(body?.input) ? body.input
    : typeof body?.input === "string" ? [{ role: "user", content: body.input }] : [];
  for (const item of list) {
    if (item?.role === "user") {
      const text = extractText(item.content);
      if (text) return text;
    }
  }
  return "";
}

/** Determine whether to pass through a `ses_...` ID or derive a stable session seed. */
export function deriveSessionSeed(incomingHeaders, body, fallbackSeed) {
  for (const name of ["x-opencode-session", "x-session-id", "x-session-affinity"]) {
    const val = readHeader(incomingHeaders, name).trim();
    if (ZEN_SESSION_PATTERN.test(val)) return { passthrough: val };
  }
  for (const name of ["x-magpie-session", "x-session-id", "x-opencode-session", "x-session-affinity"]) {
    const val = readHeader(incomingHeaders, name).trim();
    if (val) return { seed: val };
  }
  if (typeof body?.prompt_cache_key === "string" && body.prompt_cache_key.trim()) {
    return { seed: body.prompt_cache_key.trim() };
  }
  const userText = firstUserText(body);
  return userText ? { seed: `conv:${createHash("sha256").update(userText).digest("hex")}` } : { seed: fallbackSeed };
}

/** Construct a clean OpenCode CLI header set, stripping caller UA/Stainless headers. */
export function buildZenHeaders({ effectiveApiKey, protocol, session, incomingHeaders }) {
  const headers = new Headers();
  headers.set("content-type", "application/json");
  if (protocol === "anthropic") {
    headers.set("x-api-key", effectiveApiKey);
    headers.set("anthropic-version", readHeader(incomingHeaders, "anthropic-version") || "2023-06-01");
    const beta = readHeader(incomingHeaders, "anthropic-beta").trim();
    if (beta) headers.set("anthropic-beta", beta);
  } else {
    headers.set("Authorization", `Bearer ${effectiveApiKey}`);
  }
  headers.set("User-Agent", OPENCODE_USER_AGENT);
  headers.set("x-opencode-client", OPENCODE_CLIENT);
  headers.set("x-opencode-project", OPENCODE_PROJECT);
  headers.set("x-opencode-session", session);
  headers.set("x-opencode-request", requestHeader());
  headers.set("x-client-request-id", session);
  headers.set("x-session-affinity", session);
  return headers;
}

/** Drop no-op `"none"`/`"off"` reasoning placeholders that Zen rejects. */
export function stripNoopReasoning(body, protocol) {
  if (!body || typeof body !== "object") return body;
  if (protocol === "responses" && (body.reasoning?.effort === "none" || body.reasoning?.effort === "off")) {
    const { effort: _dropped, ...restReasoning } = body.reasoning;
    const next = { ...body };
    if (Object.keys(restReasoning).length === 0) delete next.reasoning;
    else next.reasoning = restReasoning;
    return next;
  }
  if (protocol === "chat" && (body.reasoning_effort === "none" || body.reasoning_effort === "off")) {
    const { reasoning_effort: _dropped, ...rest } = body;
    return rest;
  }
  return body;
}

export function isEncryptedContentError(status, bodyText) {
  return status === 400 && /encrypted[_ ]content/i.test(String(bodyText ?? ""));
}

/** Strip stale Responses `reasoning` items and call item `id`s before retrying once. */
export function stripStaleReasoning(payload) {
  if (!payload || typeof payload !== "object" || !Array.isArray(payload.input)) return null;
  if (!payload.input.some((item) => item?.type === "reasoning")) return null;
  const nextInput = payload.input.filter((item) => item?.type !== "reasoning").map((item) => {
    if ((item?.type === "function_call" || item?.type === "custom_tool_call") && typeof item.id === "string") {
      const { id: _dropped, ...rest } = item;
      return rest;
    }
    return item;
  });
  return { ...payload, input: nextInput };
}

function admissionTool(name) {
  return name === "read"
    ? {
        name,
        description: `${READ_USAGE}\n\nUnavailable in this request. Do not call.`,
        parameters: {
          type: "object",
          properties: {
            filePath: { type: "string", description: "The path to the text file to read" },
            offset: { type: "integer", description: "The first line to return (1-indexed)" },
            limit: { type: "integer", description: "The maximum number of lines to return" },
          },
          required: ["filePath"],
        },
      }
    : {
        name,
        description: `${SHELL_USAGE}\n\nUnavailable in this request. Do not call.`,
        parameters: {
          type: "object",
          properties: {
            command: { type: "string", description: "The shell command to execute" },
            timeout: { type: "integer", description: "Optional timeout in milliseconds" },
            workdir: { type: "string", description: "The working directory for the command" },
          },
          required: ["command"],
        },
      };
}

export function renameField(value, from, to) {
  if (!value || typeof value !== "object" || Array.isArray(value) || !(from in value)) return value;
  const { [from]: field, ...rest } = value;
  return { ...rest, [to]: field };
}

function renameParameter(parameters, from, to) {
  if (!parameters || typeof parameters !== "object") return parameters;
  return {
    ...parameters,
    properties: renameField(parameters.properties, from, to),
    ...(Array.isArray(parameters.required) ? { required: parameters.required.map((n) => (n === from ? to : n)) } : {}),
  };
}

function rewriteSerializedArgs(raw, from, to) {
  if (typeof raw !== "string") return renameField(raw, from, to);
  try {
    const parsed = JSON.parse(raw);
    const renamed = renameField(parsed, from, to);
    return renamed === parsed ? raw : JSON.stringify(renamed);
  } catch {
    return raw;
  }
}

function systemTextOf(body, protocol) {
  if (protocol === "anthropic") return extractText(body.system);
  const parts = protocol === "responses" && typeof body.instructions === "string" ? [body.instructions] : [];
  const list = protocol === "responses" ? body.input : body.messages;
  for (const m of Array.isArray(list) ? list : []) {
    if (m?.role === "system" || m?.role === "developer") parts.push(extractText(m.content));
  }
  return parts.join("\n");
}

function appendToContent(content, suffix) {
  if (typeof content === "string") return content ? `${content}\n\n${suffix}` : suffix;
  return Array.isArray(content) ? [...content, { type: "text", text: `\n\n${suffix}` }] : suffix;
}

function swapCompactionPrompt(body, protocol) {
  if (Array.isArray(body.tools) && body.tools.length > 0) return;
  const prompt = systemTextOf(body, protocol).trim();
  if (!prompt || prompt.length > 2000 || !/context summarization/i.test(prompt) ||
      prompt === OPENCODE_SUMMARIZATION_PROMPT.trim()) return;
  if (protocol === "anthropic") {
    if (typeof body.system === "string" || Array.isArray(body.system)) body.system = OPENCODE_SUMMARIZATION_PROMPT;
    return;
  }
  const listKey = protocol === "responses" ? "input" : "messages";
  const list = Array.isArray(body[listKey]) ? body[listKey] : [];
  const nonSystem = list.filter((m) => m?.role !== "system" && m?.role !== "developer");
  if (nonSystem.length !== 1 || nonSystem[0]?.role !== "user") return;
  if (protocol === "responses" && typeof body.instructions === "string") {
    body.instructions = OPENCODE_SUMMARIZATION_PROMPT;
    body.input = nonSystem;
    return;
  }
  body[listKey] = list.map((m) =>
    m?.role === "system" || m?.role === "developer" ? { ...m, content: OPENCODE_SUMMARIZATION_PROMPT } : m
  );
}

function ensureEnvironmentBlock(body, protocol) {
  if (ENVIRONMENT_PATTERN.test(systemTextOf(body, protocol))) return;
  if (protocol === "anthropic") {
    body.system = body.system ? appendToContent(body.system, ENVIRONMENT_BLOCK) : ENVIRONMENT_BLOCK;
    return;
  }
  if (protocol === "responses" && typeof body.instructions === "string" && body.instructions.length > 0) {
    body.instructions = `${body.instructions}\n\n${ENVIRONMENT_BLOCK}`;
    return;
  }
  const listKey = protocol === "responses" ? "input" : "messages";
  if (Array.isArray(body[listKey])) {
    const idx = body[listKey].findIndex((m) => m?.role === "system" || m?.role === "developer");
    if (idx >= 0) {
      body[listKey][idx] = { ...body[listKey][idx], content: appendToContent(body[listKey][idx].content, ENVIRONMENT_BLOCK) };
      return;
    }
  }
  if (protocol === "responses") body.instructions = ENVIRONMENT_BLOCK;
  else {
    body.messages = Array.isArray(body.messages) ? body.messages : [];
    body.messages.unshift({ role: "system", content: ENVIRONMENT_BLOCK });
  }
}

function toolRef(entry, protocol) {
  if (!entry || typeof entry !== "object") return null;
  if (protocol === "chat" && entry.type === "function" && entry.function) return { target: entry.function, paramKey: "parameters" };
  if (protocol === "responses" && entry.type === "function") return { target: entry, paramKey: "parameters" };
  if (protocol === "anthropic" && (!entry.type || entry.type === "custom")) return { target: entry, paramKey: "input_schema" };
  return null;
}

function formatAdmissionTool(tool, protocol) {
  if (protocol === "chat") return { type: "function", function: tool };
  if (protocol === "responses") return { type: "function", ...tool };
  return { name: tool.name, description: tool.description, input_schema: tool.parameters };
}

function rewriteHistory(body, protocol, rename, rewriteArgs) {
  if (protocol === "responses") {
    for (const item of Array.isArray(body.input) ? body.input : []) {
      if (item?.type === "function_call" && typeof item.name === "string") {
        const orig = item.name;
        item.name = rename(orig);
        item.arguments = rewriteArgs(orig, item.arguments);
      }
    }
    return;
  }
  for (const msg of Array.isArray(body.messages) ? body.messages : []) {
    if (protocol === "chat") {
      if (msg?.role === "tool" && typeof msg.name === "string") msg.name = rename(msg.name);
      for (const tc of msg?.role === "assistant" && Array.isArray(msg.tool_calls) ? msg.tool_calls : []) {
        if (tc?.function && typeof tc.function.name === "string") {
          const orig = tc.function.name;
          tc.function.name = rename(orig);
          tc.function.arguments = rewriteArgs(orig, tc.function.arguments);
        }
      }
    } else if (Array.isArray(msg?.content)) {
      for (const block of msg.content) {
        if (block?.type === "tool_use" && typeof block.name === "string") {
          const orig = block.name;
          block.name = rename(orig);
          block.input = rewriteArgs(orig, block.input);
        }
      }
    }
  }
}

/** Apply Zen's anonymous-tier admission shaping to a cloned wire request. */
export function applyAnonymousGate(rawBody, protocol) {
  const body = structuredClone(rawBody);
  swapCompactionPrompt(body, protocol);
  ensureEnvironmentBlock(body, protocol);

  const tools = Array.isArray(body.tools) ? body.tools : [];
  const refs = tools.map((t) => toolRef(t, protocol)).filter(Boolean);
  const declared = new Set(refs.map((r) => r.target.name).filter((n) => typeof n === "string"));
  const restoreShell = !declared.has("bash") && declared.has(SHELL_ALIAS);
  const ownsProp = (name, prop) => refs.some((r) => r.target.name === name && r.target[r.paramKey]?.properties && prop in r.target[r.paramKey].properties);
  const restoreRead = ownsProp("read", "file_path") && !ownsProp("read", "filePath");
  const restoreTimeout = ownsProp(restoreShell ? SHELL_ALIAS : "bash", "timeoutMs") && !ownsProp(restoreShell ? SHELL_ALIAS : "bash", "timeout");

  const renamed = new Map();
  const rename = (name) => {
    if (typeof name !== "string") return name;
    if (Object.hasOwn(GATE_TOOL_ALIASES, name) && !declared.has(GATE_TOOL_ALIASES[name])) {
      renamed.set(GATE_TOOL_ALIASES[name], name);
      return GATE_TOOL_ALIASES[name];
    }
    if (restoreShell && name === SHELL_ALIAS) {
      renamed.set("bash", SHELL_ALIAS);
      return "bash";
    }
    return name;
  };
  const rewriteArgs = (origName, args) => {
    let out = restoreRead && origName === "read" ? rewriteSerializedArgs(args, "file_path", "filePath") : args;
    if (restoreTimeout && (origName === "bash" || (restoreShell && origName === SHELL_ALIAS))) {
      out = rewriteSerializedArgs(out, "timeoutMs", "timeout");
    }
    return out;
  };

  const postNames = new Set();
  for (const { target, paramKey } of refs) {
    const nextName = rename(target.name);
    target.name = nextName;
    postNames.add(nextName);
    if (nextName === "read") {
      if (restoreRead) target[paramKey] = renameParameter(target[paramKey], "file_path", "filePath");
      if (!String(target.description ?? "").includes(READ_USAGE)) target.description = target.description ? `${target.description}\n\n${READ_USAGE}` : READ_USAGE;
    } else if (nextName === "bash") {
      if (restoreTimeout) target[paramKey] = renameParameter(target[paramKey], "timeoutMs", "timeout");
      if (!String(target.description ?? "").includes(SHELL_USAGE)) target.description = target.description ? `${target.description}\n\n${SHELL_USAGE}` : SHELL_USAGE;
    }
  }
  const choiceTarget = protocol === "chat" && body.tool_choice?.type === "function" ? body.tool_choice.function
    : (protocol === "responses" && body.tool_choice?.type === "function") || (protocol === "anthropic" && body.tool_choice?.type === "tool") ? body.tool_choice : null;
  if (choiceTarget?.name) choiceTarget.name = rename(choiceTarget.name);
  rewriteHistory(body, protocol, rename, rewriteArgs);

  const unavailable = new Set(GATE_TOOLS.filter((name) => !postNames.has(name)));
  if (unavailable.size > 0) {
    body.tools = [...tools, ...[...unavailable].map((name) => formatAdmissionTool(admissionTool(name), protocol))];
  }
  return { body, restoration: { renamed, restoreShell, restoreRead, restoreTimeout, unavailable } };
}
