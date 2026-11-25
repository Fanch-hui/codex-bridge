/**
 * OpenCode Zen free-tier identity helpers ported from pi-opencode-direct.
 * @module dsh-opencode-free/zen
 */
import { createHash, randomBytes } from 'node:crypto';
/**
 * Provider route key selecting this adapter.
 */
export const ZEN_PROVIDER = 'opencode-zen-free';
/**
 * Zen endpoint root.
 */
export const ZEN_BASE_URL = 'https://opencode.ai/zen/v1';
/**
 * Credential reference naming the optional Zen key.
 */
export const ZEN_API_KEY_ENV = 'OPENCODE_API_KEY';
/**
 * Anonymous free-tier bearer.
 */
export const ZEN_ANONYMOUS_KEY = 'public';
/**
 * OpenCode CLI identity Zen gates anonymous requests on.
 */
export const OPENCODE_USER_AGENT = 'opencode/1.18.31 ai-sdk/provider-utils/4.0.40 runtime/bun/1.3.14 dsh-opencode-free/0.1.2';
/**
 * OpenCode client name.
 */
export const OPENCODE_CLIENT = 'cli';
/**
 * OpenCode project scope.
 */
export const OPENCODE_PROJECT = 'global';
/**
 * Static Zen gate headers.
 */
export const STATIC_ZEN_HEADERS = {
    'x-opencode-client': OPENCODE_CLIENT,
    'x-opencode-project': OPENCODE_PROJECT,
};
/**
 * OpenCode compaction system prompt, byte-identical to the CLI.
 * Zen anonymous tier accepts it while rejecting Pi/dsh summarization wording.
 */
export const OPENCODE_SUMMARIZATION_PROMPT = 'You are a context summarization agent. You are given a conversation between a user and an agent. Your goal is to produce a structured summary matching the format specified so another coding agent can continue the work.\n'
    + 'Always follow the exact output structure requested by the user prompt. Keep every section, preserve exact file paths and identifiers when known, and prefer terse bullets over paragraphs.\n'
    + 'Do not continue the conversation. Do not respond to any questions in the conversation. Only output the structured summary in the exact format requested by the user prompt. Respond in the same language as the conversation.\n';
const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
/**
 * Encode bytes as base62.
 * @param bytes - source bytes; an empty input encodes as `0` digits.
 * @param length - output length.
 * @returns base62 string.
 */
export function base62FromBytes(bytes, length) {
    let out = '';
    for (let i = 0; i < length; i += 1) {
        const digit = BASE62.charAt((bytes[i % bytes.length] ?? 0) % 62);
        out += digit;
    }
    return out;
}
/**
 * Map a harness session id to a valid OpenCode session id.
 * @param sessionId - harness session identity.
 * @returns `ses_` + 12 hex + 14 base62.
 */
export function sessionHeader(sessionId) {
    const hash = createHash('sha256').update(`${ZEN_PROVIDER}:${sessionId}`).digest();
    const hex = hash.subarray(0, 6).toString('hex');
    return `ses_${hex}${base62FromBytes(hash.subarray(6), 14)}`;
}
/**
 * Random valid OpenCode request id.
 * @returns `msg_` + 12 hex + 14 base62.
 */
export function requestHeader() {
    return `msg_${randomBytes(6).toString('hex')}${base62FromBytes(randomBytes(14), 14)}`;
}
/**
 * Whether a 400 body reports stale encrypted reasoning after Zen backend rotation.
 * @param status - HTTP status.
 * @param bodyText - response body.
 * @returns true when retrying without replayed reasoning may succeed.
 */
export function isEncryptedContentError(status, bodyText) {
    if (status !== 400)
        return false;
    return /encrypted[_ ]content/i.test(bodyText);
}
/**
 * Read the `type` discriminator of one unknown request-body item.
 * @param item - raw item.
 * @returns its type, or undefined when absent.
 */
function itemType(item) {
    if (typeof item !== 'object' || item === null)
        return undefined;
    return item.type;
}
/**
 * Drop stale Responses `reasoning` items so a retried request looks fresh.
 * @param payload - parsed request body.
 * @returns stripped body, or null when nothing was stripped.
 */
export function stripStaleReasoning(payload) {
    if (payload === null || typeof payload !== 'object')
        return null;
    const input = payload.input;
    if (!Array.isArray(input))
        return null;
    const items = input;
    if (!items.some((item) => itemType(item) === 'reasoning'))
        return null;
    const nextInput = items
        .filter((item) => itemType(item) !== 'reasoning')
        .map((item) => {
        const type = itemType(item);
        const isCall = type === 'function_call' || type === 'custom_tool_call';
        const target = item;
        const hasId = typeof item === 'object' && item !== null && typeof target?.id === 'string';
        if (isCall && hasId) {
            const rest = { ...item };
            delete rest.id;
            return rest;
        }
        return item;
    });
    return { ...payload, input: nextInput };
}
/**
 * Wrap fetch with one retry dropping stale reasoning on Zen rotation.
 * @param inner - underlying fetch, defaults to global fetch.
 * @returns fetch with encrypted-content fallback.
 */
export function withEncryptedContentFallback(inner) {
    const base = inner ?? globalThis.fetch;
    const wrapped = async (url, init) => {
        const first = await base(url, init);
        if (first.status !== 400)
            return first;
        let text = '';
        try {
            text = await first.clone().text();
        }
        catch {
            return first;
        }
        if (!isEncryptedContentError(first.status, text))
            return first;
        const raw = init?.body;
        if (typeof raw !== 'string')
            return first;
        let parsed;
        try {
            parsed = JSON.parse(raw);
        }
        catch {
            return first;
        }
        const stripped = stripStaleReasoning(parsed);
        if (!stripped)
            return first;
        return base(url, { ...init, body: JSON.stringify(stripped) });
    };
    return wrapped;
}
/**
 * Whether a Zen key is anonymous.
 * @param apiKey - resolved key.
 * @returns true for the literal public tier.
 */
export function isAnonymousKey(apiKey) {
    return apiKey.trim().length === 0 || apiKey.trim() === ZEN_ANONYMOUS_KEY;
}
