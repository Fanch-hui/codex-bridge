/**
 * OpenCode / Magpie community provider host entrypoint for dsh-opencode-free.
 * Adapts upstream dsh-opencode-free (0.6.0) for Codex Bridge's Bun host and
 * Model Gateway without importing DSH-only or pi-ai runtime dependencies.
 */

import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import {
  DEFAULT_BASE_URL,
  PATHS,
  PROVIDER_ID,
  SDK,
  buildGatewayModels,
  fetchOfficialCatalog,
} from "./bridge-catalog.mjs";
import {
  applyAnonymousGate,
  buildZenHeaders,
  deriveSessionSeed,
  isEncryptedContentError,
  sessionHeader,
  stripNoopReasoning,
  stripStaleReasoning,
  validateApiKey,
} from "./bridge-gate.mjs";
import { guardAndRestoreResponse } from "./bridge-response.mjs";
import { needsOpenCodeCiphers, zenHttpsFetch } from "./lib/zen-tls.js";

export { PROVIDER_ID };

function normalizeBaseURL(value) {
  if (value === undefined) return DEFAULT_BASE_URL;
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("dsh-opencode-free: baseURL must be a non-empty URL");
  }
  const url = new URL(value.trim());
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("dsh-opencode-free: baseURL must use http(s) without embedded credentials");
  }
  return url.href.replace(/\/+$/, "");
}

function selectTransport(targetURL) {
  // Under Bun (Bridge's community host), BoringSSL already offers the 17 CLI
  // cipher suites and globalThis.fetch carries Bridge's proxy/LAN routing.
  if (typeof targetURL === "string" && targetURL.startsWith("https://") && needsOpenCodeCiphers()) {
    return zenHttpsFetch;
  }
  return globalThis.fetch;
}

function jsonError(status, message, code = "invalid_request_error", type = "invalid_request_error") {
  return new Response(JSON.stringify({ error: { type, code, message } }), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function protocolFromInput(input) {
  const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input?.url ?? "";
  let pathname = raw;
  try {
    pathname = new URL(raw, "http://placeholder.invalid").pathname;
  } catch {
    return null;
  }
  if (pathname.endsWith("/chat/completions")) return "chat";
  if (pathname.endsWith("/responses")) return "responses";
  if (pathname.endsWith("/messages")) return "anthropic";
  return null;
}

async function readJsonBody(input, init) {
  let raw = init?.body;
  if (raw === undefined && input instanceof Request) raw = await input.text();
  if (raw instanceof ArrayBuffer) {
    raw = Buffer.from(raw).toString("utf8");
  } else if (ArrayBuffer.isView(raw)) {
    raw = Buffer.from(raw.buffer, raw.byteOffset, raw.byteLength).toString("utf8");
  }
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export async function server(_input, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const fallbackSession = randomUUID();
  let knownModels = {};

  async function discover(signal) {
    const result = await fetchOfficialCatalog({
      fetchImpl: selectTransport(baseURL),
      baseURL,
      signal,
    });
    if (!result.ok) {
      const fallback = { ...knownModels };
      fallback[Symbol.for("magpie.fellBack")] = true;
      return fallback;
    }
    knownModels = buildGatewayModels(result.entries, baseURL);
    return knownModels;
  }

  async function sendUpstream(targetURL, headers, payload, signal) {
    return await selectTransport(targetURL)(targetURL, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal,
      redirect: "error",
    });
  }

  async function wrappedFetch(input, init) {
    const protocol = protocolFromInput(input);
    if (!protocol) return jsonError(400, "Unsupported OpenCode Zen endpoint path.");
    const rawBody = await readJsonBody(input, init);
    if (!rawBody) return jsonError(400, "Request body must be a JSON object.");
    const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);

    if (Object.keys(knownModels).length === 0) await discover(signal);
    if (Object.keys(knownModels).length === 0) {
      return jsonError(
        503,
        "Unable to verify OpenCode Zen free model catalog; request refused to protect billing.",
        "catalog_unavailable",
        "api_error"
      );
    }

    const requestedID = typeof rawBody.model === "string" ? rawBody.model : "";
    const model = Object.hasOwn(knownModels, requestedID) ? knownModels[requestedID] : null;
    if (!model) {
      const available = Object.keys(knownModels).sort().join(", ") || "none";
      return new Response(
        JSON.stringify({
          type: "error",
          error: {
            type: "not_found_error",
            message: `Model ${requestedID} is not an available OpenCode Zen free model. Free models: ${available}.`,
          },
        }),
        { status: 404, headers: { "content-type": "application/json; charset=utf-8" } }
      );
    }
    if (model.api.npm !== SDK[protocol]) {
      return jsonError(400, `Model ${requestedID} is not served on the ${protocol} protocol.`);
    }

    return { protocol, rawBody, signal, model };
  }

  return {
    async config(cfg) {
      cfg.provider ??= {};
      cfg.provider[PROVIDER_ID] ??= {
        name: "OpenCode Zen Free (dsh-opencode-free)",
        npm: SDK.chat,
        api: baseURL,
        models: {},
      };
    },
    auth: {
      provider: PROVIDER_ID,
      single: true,
      icon: "https://opencode.ai/favicon-v3.ico",
      maxConcurrency: 2,
      methods: [
        {
          type: "api",
          label: "填写个人 OpenCode Zen API Key",
          labels: { en: "Personal OpenCode Zen API Key" },
          placeholder: "输入你在 opencode.ai 获取的 Zen API Key",
          async authorize() {
            // Returning success without a key lets host.js reject empty key
            // submissions while keeping the single-step password prompt UI.
            return { type: "success" };
          },
        },
        {
          type: "api",
          keyless: true,
          label: "免费匿名访问（public，无需 API Key）",
          labels: { en: "Anonymous Free Tier (public)" },
          placeholder: "public",
          async authorize() {
            return { type: "success", key: "public", accountId: "anonymous" };
          },
        },
      ],
      async loader(getAuth) {
        const current = await getAuth();
        if (!current) return {};
        return {
          apiKey: "",
          baseURL,
          async fetch(input, init) {
            const auth = await getAuth();
            const keyCheck = validateApiKey(auth?.key);
            if (!keyCheck.valid) {
              return jsonError(
                401,
                keyCheck.error || "Invalid OpenCode Zen API Key.",
                "invalid_api_key",
                "authentication_error"
              );
            }
            const validated = await wrappedFetch(input, init);
            if (validated instanceof Response) return validated;
            const { protocol, rawBody, signal, model } = validated;

            const wantStream = rawBody.stream === true;
            let outgoingBody = stripNoopReasoning(rawBody, protocol);
            let restoration = null;
            if (keyCheck.isAnonymous) {
              const gated = applyAnonymousGate(outgoingBody, protocol);
              outgoingBody = gated.body;
              restoration = gated.restoration;
              outgoingBody.stream = true;
              if (protocol === "chat") {
                outgoingBody.stream_options = { ...outgoingBody.stream_options, include_usage: true };
              }
            } else if (protocol === "chat" && wantStream) {
              outgoingBody = {
                ...outgoingBody,
                stream_options: { ...outgoingBody.stream_options, include_usage: true },
              };
            }

            const incomingHeaders = init?.headers ?? (input instanceof Request ? input.headers : undefined);
            const seedInfo = deriveSessionSeed(incomingHeaders, outgoingBody, fallbackSession);
            const session = seedInfo.passthrough ?? sessionHeader(seedInfo.seed);
            const targetURL = `${model.api.url}${PATHS[protocol]}`;

            let headers = buildZenHeaders({
              effectiveApiKey: keyCheck.key,
              protocol,
              session,
              incomingHeaders,
            });
            let response = await sendUpstream(targetURL, headers, outgoingBody, signal);

            if (response.status === 400) {
              const text = await response.clone().text().catch(() => "");
              if (isEncryptedContentError(400, text)) {
                const stripped = stripStaleReasoning(outgoingBody);
                if (stripped) {
                  await response.body?.cancel?.().catch(() => {});
                  headers = buildZenHeaders({
                    effectiveApiKey: keyCheck.key,
                    protocol,
                    session,
                    incomingHeaders,
                  });
                  response = await sendUpstream(targetURL, headers, stripped, signal);
                }
              }
            }

            return await guardAndRestoreResponse(response, protocol, restoration, { wantStream });
          },
        };
      },
      async usage(getAuth) {
        const auth = await getAuth();
        const keyCheck = validateApiKey(auth?.key);
        if (!keyCheck.valid) {
          return { plan: "OpenCode Zen Free", error: keyCheck.error, signIn: "expired", windows: [] };
        }
        return {
          plan: keyCheck.isAnonymous
            ? "OpenCode Zen Free（匿名免费层）"
            : "OpenCode Zen Free（个人 API Key）",
          windows: [],
        };
      },
    },
    provider: {
      id: PROVIDER_ID,
      async models(provider, { auth, signal } = {}) {
        if (!auth) return provider.models;
        const keyCheck = validateApiKey(auth.key);
        if (!keyCheck.valid) {
          throw Object.assign(new Error("OpenCode Zen API Key 为空或格式无效，请重新连接。"), {
            signIn: "expired",
          });
        }
        return await discover(signal);
      },
    },
    async "chat.headers"(input, output) {
      if (input.model?.providerID !== PROVIDER_ID || !input.sessionID) return;
      output.headers["x-session-id"] = input.sessionID;
    },
  };
}

export const DshOpenCodeFreePlugin = server;
export default { id: PROVIDER_ID, server };
