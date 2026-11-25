/**
 * Model catalog discovery and metadata mapping for dsh-opencode-free in Codex Bridge.
 * Derives free chat models solely from Zen's `/inference/v1/models` catalog without
 * importing `@earendil-works/pi-ai`.
 */

import { Buffer } from "node:buffer";

export const PROVIDER_ID = "dsh-opencode-free";
export const UPSTREAM_VERSION = "0.6.0";
export const DEFAULT_BASE_URL = "https://opencode.ai/inference/v1";
export const ANTHROPIC_BASE_URL = "https://opencode.ai/inference/anthropic/v1";
export const OPENCODE_CLIENT = "cli";
export const OPENCODE_PROJECT = "global";
export const OPENCODE_USER_AGENT =
  `opencode/1.18.31 ai-sdk/provider-utils/4.0.40 runtime/bun/1.3.14 dsh-opencode-free/${UPSTREAM_VERSION}`;

export const SDK = Object.freeze({
  chat: "@ai-sdk/openai-compatible",
  responses: "@ai-sdk/openai",
  anthropic: "@ai-sdk/anthropic",
});

export const PATHS = Object.freeze({
  chat: "/chat/completions",
  responses: "/responses",
  anthropic: "/messages",
});

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_BYTES = 2 * 1024 * 1024;
const DEFAULT_CONTEXT_WINDOW = 200_000;
const DEFAULT_OUTPUT_TOKENS = 32_000;
const REASONING_EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"];

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finitePositiveInt(value) {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : undefined;
}

function nonNegative(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

/**
 * Classify a catalog entry's declared text pricing. Any missing or non-numeric field
 * is treated as `unparseable` and never guessed free.
 */
export function costClassOf(record) {
  const text = isPlainObject(record?.cost) ? record.cost.text : undefined;
  if (!isPlainObject(text)) return "unparseable";
  const { input, output } = text;
  if (!isPlainObject(input) || !isPlainObject(output)) return "unparseable";
  if (!nonNegative(input.price) || !nonNegative(output.price)) return "unparseable";
  const declared = [input.price, output.price];
  for (const side of [input, output]) {
    if (side.cache === undefined) continue;
    if (!isPlainObject(side.cache)) return "unparseable";
    for (const price of [side.cache.read, side.cache.write]) {
      if (price === undefined) continue;
      if (!nonNegative(price)) return "unparseable";
      declared.push(price);
    }
  }
  return declared.every((price) => price === 0) ? "free" : "paid";
}

/** Return true only for conversational (`type === "chat"`) zero-cost entries. */
export function isFree(record) {
  return isPlainObject(record) && record.type === "chat" && costClassOf(record) === "free";
}

/**
 * Parse and validate Zen's `/models` JSON payload. Returns `null` when the payload
 * cannot be trusted so callers retain the previous list rather than emptying it.
 */
export function parseOfficialList(body) {
  if (!isPlainObject(body) || !Array.isArray(body.data)) return null;
  const seen = new Set();
  const free = [];
  let readable = 0;
  let unclassified = 0;
  let entries = 0;
  for (const entry of body.data) {
    if (!isPlainObject(entry) || typeof entry.id !== "string" || !entry.id || seen.has(entry.id)) {
      continue;
    }
    seen.add(entry.id);
    entries += 1;
    const cost = costClassOf(entry);
    if (cost !== "unparseable") readable += 1;
    if (entry.type !== "chat") continue;
    if (cost === "unparseable") unclassified += 1;
    else if (cost === "free") free.push(entry);
  }
  if (entries === 0 || readable === 0) return null;
  return { free, unclassified };
}

/**
 * Determine which Bridge-supported wire protocol a catalog model speaks.
 * Returns `null` when the entry declares only unsupported protocols (e.g. Gemini native).
 */
export function protocolFor(record) {
  if (!isPlainObject(record?.api)) return "chat";
  if ("chat-completions" in record.api) return "chat";
  if ("responses" in record.api) return "responses";
  if ("messages" in record.api) return "anthropic";
  return null;
}

function inputModalitiesFor(record) {
  const raw = Array.isArray(record?.modalities?.input)
    ? record.modalities.input.filter((item) => typeof item === "string")
    : [];
  const has = (kind, mimePrefix) =>
    raw.some((item) => item === kind || item.startsWith(mimePrefix));
  return {
    text: true,
    image: has("image", "image/"),
    audio: has("audio", "audio/"),
    video: has("video", "video/"),
    pdf: has("pdf", "application/pdf"),
  };
}

function variantsFor(record) {
  const effort = record?.capabilities?.reasoning?.effort;
  if (!Array.isArray(effort)) return {};
  const declared = new Set(effort.filter((value) => typeof value === "string"));
  const variants = {};
  for (const level of REASONING_EFFORTS) {
    if (declared.has(level)) variants[level] = { reasoningEffort: level };
  }
  return variants;
}

/**
 * Convert validated free catalog entries into the OpenCode/Magpie host model map,
 * sorted deterministically by ASCII model ID.
 */
export function buildGatewayModels(entries, baseURL = DEFAULT_BASE_URL) {
  const cleanBase = baseURL.replace(/\/+$/, "");
  const sorted = [...entries].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const models = {};
  for (const record of sorted) {
    if (!isFree(record) || typeof record.id !== "string" || !record.id || record.id === "__proto__") {
      continue;
    }
    const protocol = protocolFor(record);
    if (!protocol || !Object.hasOwn(SDK, protocol)) continue;
    const channelURL =
      protocol === "anthropic" && cleanBase === DEFAULT_BASE_URL ? ANTHROPIC_BASE_URL : cleanBase;
    const input = inputModalitiesFor(record);
    const reasoningSupported = record.capabilities?.reasoning?.supported === true;
    const toolcallSupported = record.capabilities?.tools?.supported !== false;
    const tempDeclared = record.capabilities?.temperature;
    const context = finitePositiveInt(record.limit?.context) ?? DEFAULT_CONTEXT_WINDOW;
    const inputLimit = finitePositiveInt(record.limit?.input);
    const output = finitePositiveInt(record.limit?.output) ?? DEFAULT_OUTPUT_TOKENS;
    const reasoningField =
      record.api?.["chat-completions"]?.compatibility?.reasoning_field === "reasoning_content";

    models[record.id] = {
      id: record.id,
      providerID: PROVIDER_ID,
      name: typeof record.name === "string" && record.name ? record.name : record.id,
      api: { id: record.id, url: channelURL, npm: SDK[protocol] },
      limit: {
        context,
        ...(inputLimit !== undefined ? { input: inputLimit } : {}),
        output,
      },
      ...(typeof tempDeclared === "boolean" ? { temperature: tempDeclared } : {}),
      capabilities: {
        temperature: typeof tempDeclared === "boolean" ? tempDeclared : true,
        reasoning: reasoningSupported,
        attachment: input.image || input.pdf,
        toolcall: toolcallSupported,
        input,
        output: { text: true, image: false, audio: false, video: false, pdf: false },
        interleaved: reasoningField ? { field: "reasoning_content" } : false,
      },
      cost: { input: 0, output: 0, cache: { read: 0, write: 0 } },
      variants: variantsFor(record),
      options: {},
      headers: {},
      status: "active",
      release_date: "",
      free: true,
    };
  }
  return models;
}

/** Build the GET `/models` request parameters expected by Zen's free catalog endpoint. */
export function zenListRequest(baseURL = DEFAULT_BASE_URL) {
  const cleanBase = baseURL.replace(/\/+$/, "");
  return {
    url: `${cleanBase}/models`,
    headers: {
      Authorization: "Bearer public",
      "User-Agent": OPENCODE_USER_AGENT,
      "x-opencode-client": OPENCODE_CLIENT,
      "x-opencode-project": OPENCODE_PROJECT,
    },
  };
}

/**
 * Fetch and parse Zen's official free model list with bounded size and timeout.
 */
export async function fetchOfficialCatalog({
  fetchImpl = globalThis.fetch,
  baseURL = DEFAULT_BASE_URL,
  signal,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxBytes = DEFAULT_MAX_BYTES,
} = {}) {
  const request = zenListRequest(baseURL);
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;
  try {
    const response = await fetchImpl(request.url, {
      method: "GET",
      headers: request.headers,
      signal: combinedSignal,
      redirect: "error",
    });
    if (!response.ok) {
      await response.body?.cancel?.().catch(() => {});
      return { ok: false, error: `HTTP ${response.status}` };
    }
    let text;
    if (response.body) {
      const chunks = [];
      let total = 0;
      for await (const chunk of response.body) {
        total += chunk.byteLength ?? chunk.length ?? 0;
        if (total > maxBytes) {
          await response.body.cancel?.().catch(() => {});
          return { ok: false, error: "Zen model catalog exceeded maximum response size" };
        }
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      }
      text = Buffer.concat(chunks).toString("utf8");
    } else {
      text = await response.text();
      if (Buffer.byteLength(text, "utf8") > maxBytes) {
        return { ok: false, error: "Zen model catalog exceeded maximum response size" };
      }
    }
    const parsed = parseOfficialList(JSON.parse(text));
    if (!parsed) return { ok: false, error: "Zen model catalog payload was invalid" };
    return { ok: true, entries: parsed.free, unclassified: parsed.unclassified };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}
