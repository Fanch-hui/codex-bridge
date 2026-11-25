/**
 * Model catalogue owner: Zen's own model list (`/inference/v1/models`) is the
 * single source of truth for WHICH free models exist and for what each one can
 * do — limits, input modalities, reasoning levels and the channel it speaks. A
 * model is free when the list says every cost it declares is zero; nothing else
 * decides membership.
 *
 * Three layers, deliberately separable so each failure mode is attributable:
 *   1. derivation (pure): free test, list validation, channel and metadata
 *      mapping — no I/O, fully fixture-testable;
 *   2. fetch + cache: one GET of the list (~95KB, no ETag), persisting only the
 *      free entries so a warm start never has to wait for the network;
 *   3. the state container: one lazy refresh axis, single-flight, degradation.
 *
 * Being listed is necessary, not sufficient: whether a listed model actually
 * answers is the probe's question (see `runProbeRound`).
 *
 * DSH never calls `provider.refreshModels` for this list (no host caller
 * exists), so this module owns its own trigger. It is host-side only: no DSH
 * `ctx` concepts live here, lifecycle wiring stays in `index.ts`.
 *
 * Identity (`provider` / `baseUrl` / `headers`) is NOT defined here — it is
 * inherited from `template`, an already identity-mapped pi-ai record, so the
 * Zen identity constants keep exactly one owner in `zen-provider.ts`.
 */
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { zenListRequest } from "./zen-provider.js";
/**
 * Cache schema version. Version 1 held a third-party models dictionary; its
 * verdicts and round report are still read (see {@link readCache}), its models
 * are not. Anything else is treated as no cache at all.
 */
export const CACHE_VERSION = 2;
/**
 * Lazy revalidation window for the whole list. The GET spends no inference
 * quota, so thirty minutes keeps a withdrawn or newly free model's lag small;
 * the answer has no ETag and is re-downloaded in full (~95KB), which is why the
 * window is not shorter. Not driven by a timer: a read past the window starts
 * the refresh.
 */
export const CATALOG_TTL_MS = 30 * 60_000;
/**
 * Floor between two MANUAL probe rounds. The automatic round is bounded by
 * `probedToday(lastProbeAt, now)` (one per local calendar day), but `forceProbes()` is reachable
 * from the POST route, which has no server-side rate limit, and each round is up
 * to 34 real inference requests against a bucket shared per egress IP. Five
 * minutes is far below anything a user would notice and far above a double click
 *.
 */
export const FORCED_PROBE_MIN_INTERVAL_MS = 5 * 60_000;
/** D1: bounded so a hung endpoint cannot pin a plugin fiber. */
export const DEFAULT_TIMEOUT_MS = 10_000;
/** R1: the real answer is ~95KB; 2MB leaves headroom and rejects a runaway. */
export const DEFAULT_MAX_BYTES = 2 * 1024 * 1024;
/** Re-exported so `catalog.ts` consumers do not need a second import. */
export { PLUGIN_VERSION } from "./zen-provider.js";
function isPlainObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
function finitePositive(value) {
    return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}
function nonNegative(value) {
    return typeof value === "number" && Number.isFinite(value) && value >= 0;
}
/**
 * What one entry's declared text cost says. The input and output prices must be
 * readable numbers; a cache price is optional but, when declared, must be one
 * too. Anything unreadable is `unparseable` — never guessed free.
 */
export function costClassOf(record) {
    const cost = record.cost;
    const text = isPlainObject(cost) ? cost.text : undefined;
    if (!isPlainObject(text))
        return "unparseable";
    const { input, output } = text;
    if (!isPlainObject(input) || !isPlainObject(output))
        return "unparseable";
    if (!nonNegative(input.price) || !nonNegative(output.price))
        return "unparseable";
    const declared = [input.price, output.price];
    for (const side of [input, output]) {
        if (side.cache === undefined)
            continue;
        if (!isPlainObject(side.cache))
            return "unparseable";
        for (const price of [side.cache.read, side.cache.write]) {
            if (price === undefined)
                continue;
            if (!nonNegative(price))
                return "unparseable";
            declared.push(price);
        }
    }
    return declared.every((price) => price === 0) ? "free" : "paid";
}
/** D2: a conversational entry whose every declared cost is zero. */
export function isFree(record) {
    return record.type === "chat" && costClassOf(record) === "free";
}
/**
 * Validate one answer. `null` means "could not tell" and must leave the current
 * list alone: the body is not `{data: [...]}`, the list is empty, or not one
 * entry has a readable cost (a renamed field, not a withdrawal of everything).
 * A well-formed answer naming zero free models is NOT `null` — it is the answer.
 */
export function parseOfficialList(body) {
    if (!isPlainObject(body) || !Array.isArray(body.data))
        return null;
    const seen = new Set();
    const free = [];
    let readable = 0;
    let unclassified = 0;
    let entries = 0;
    for (const entry of body.data) {
        if (!isPlainObject(entry) || typeof entry.id !== "string" || entry.id === "" || seen.has(entry.id))
            continue;
        seen.add(entry.id);
        entries += 1;
        const cost = costClassOf(entry);
        if (cost !== "unparseable")
            readable += 1;
        if (entry.type !== "chat")
            continue;
        if (cost === "unparseable")
            unclassified += 1;
        else if (cost === "free")
            free.push(entry);
    }
    if (entries === 0 || readable === 0)
        return null;
    return { free, unclassified };
}
/** pi-ai's level vocabulary, in the order it filters them. */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/**
 * `getSupportedThinkingLevels` treats `xhigh` and `max` as opt-in — absent from
 * the map means NOT offered — but includes `off`/`minimal`/`low`/`medium`/`high`
 * unless they are explicitly mapped to `null`. A faithful map therefore has to
 * null out the ones the list does not publish; leaving them absent would
 * offer a level the model rejects.
 */
const OPT_IN_THINKING_LEVELS = new Set(["xhigh", "max"]);
/**
 * D6: the reasoning levels the list publishes for this model
 * (`capabilities.reasoning.effort`), as pi-ai's `thinkingLevelMap`.
 *
 * The values are identity because OpenCode is OpenAI-compatible and the level
 * name is what goes on the wire (`reasoning_effort` on completions, `effort` on
 * responses); the map's job here is to say which levels EXIST. A published
 * `none` is not a level pi-ai has a name for and is ignored.
 *
 * `off` is deliberately left absent (offered) rather than nulled: it means
 * "send no reasoning parameter", which is a real choice the user asked to keep
 * as an explicit row. The placeholder effort pi-ai would otherwise put on the
 * wire for it (`"none"` by default, `"off"` when explicitly chosen — neither of
 * which pi-ai's own builtin records nor OpenCode ever send) is stripped back
 * to "no reasoning object" by the plugin's onPayload guard in zen-provider.ts,
 * so offering it is safe.
 *
 * `undefined` means "no level list was published, so make no claim" — pi-ai
 * then falls back to its own default set. Guessing there would offer levels
 * upstream rejects, which surfaces as an `UNSUPPORTED_REASONING_EFFORT` failure
 * rather than as a clamp.
 */
export function thinkingLevelMapFor(record) {
    const capabilities = record.capabilities;
    const reasoning = isPlainObject(capabilities) ? capabilities.reasoning : undefined;
    const effort = isPlainObject(reasoning) ? reasoning.effort : undefined;
    if (!Array.isArray(effort))
        return undefined;
    const published = new Set();
    for (const value of effort) {
        if (typeof value === "string" && THINKING_LEVELS.includes(value))
            published.add(value);
    }
    if (published.size === 0)
        return undefined;
    const map = {};
    for (const level of THINKING_LEVELS) {
        // `off` stays absent (offered) rather than nulled: the user asked to keep
        // it as an explicit choice. The placeholder effort this would otherwise
        // put on the wire is stripped back to "no reasoning object" by the
        // plugin's onPayload guard (see zen-provider.ts), so offering it is safe.
        if (level === "off")
            continue;
        if (published.has(level))
            map[level] = level;
        else if (!OPT_IN_THINKING_LEVELS.has(level))
            map[level] = null;
    }
    return map;
}
/**
 * D6, three tiers: the channel the entry itself declares (`api` keys), then the
 * pi-ai builtin table when it knows the model, then the provider's own default.
 * The entry wins because it is the upstream's own statement of where the model
 * is served; the rest are inference.
 */
export function channelFor(record, knownApis) {
    const api = record.api;
    if (isPlainObject(api)) {
        if ("chat-completions" in api)
            return "openai-completions";
        if ("responses" in api)
            return "openai-responses";
    }
    const id = typeof record.id === "string" ? record.id : undefined;
    if (id !== undefined && knownApis !== undefined) {
        const known = knownApis.get(id);
        if (known !== undefined)
            return known;
    }
    return "openai-completions";
}
/**
 * One list entry → one pi-ai model. Everything the plugin can learn about a
 * model's CAPABILITIES is taken from the entry rather than inherited:
 *
 *   - image input      ← `modalities.input` (pi-ai knows only text/image, so any
 *                        `image/*` type counts as image; audio/video/pdf are
 *                        dropped, not silently kept)
 *   - context window   ← `limit.context`
 *   - max output       ← `limit.output`
 *   - thinking levels  ← `capabilities.reasoning.effort`
 *
 * A field the list does not publish falls back to the template, and the
 * template is one fixed record — so `thinkingLevelMap` is set EXPLICITLY in
 * both branches. Inheriting another model's level list would offer levels this
 * model rejects, which the host reports as `UNSUPPORTED_REASONING_EFFORT`
 * rather than clamping.
 */
function buildModel(record, template, knownApis) {
    const id = typeof record.id === "string" && record.id !== "" ? record.id : "";
    const api = channelFor(record, knownApis);
    const limit = isPlainObject(record.limit) ? record.limit : {};
    const capabilities = isPlainObject(record.capabilities) ? record.capabilities : {};
    const reasoning = isPlainObject(capabilities.reasoning) ? capabilities.reasoning : {};
    const modalities = isPlainObject(record.modalities) ? record.modalities : {};
    const declaredInput = [];
    if (Array.isArray(modalities.input)) {
        const types = modalities.input.filter((entry) => typeof entry === "string");
        if (types.includes("text"))
            declaredInput.push("text");
        if (types.some((type) => type === "image" || type.startsWith("image/")))
            declaredInput.push("image");
    }
    const levels = thinkingLevelMapFor(record);
    return {
        ...template,
        id,
        name: typeof record.name === "string" && record.name !== "" ? record.name : id,
        api,
        reasoning: typeof reasoning.supported === "boolean" ? reasoning.supported : template.reasoning,
        input: declaredInput.length > 0 ? declaredInput : template.input,
        // Free by construction here (isFree already proved it); stated explicitly
        // so a stray inherited tier cannot reintroduce a non-zero rate.
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: finitePositive(limit.context) ?? template.contextWindow,
        maxTokens: finitePositive(limit.output) ?? template.maxTokens,
        thinkingLevelMap: (levels ?? undefined),
        // `compat` is transport-specific. Carrying the template's completions
        // overrides onto a responses model would misconfigure it, so a channel
        // change drops them and lets pi-ai auto-detect from baseUrl.
        // A `reasoning_content` field additionally requires passback on every
        // assistant message in thinking mode with tools.
        compat: compatFor(record, template, api),
    };
}
/**
 * Whether the entry says its reasoning travels in a `reasoning_content` field
 * (`api["chat-completions"].compatibility.reasoning_field`) that the endpoint
 * requires on every assistant message in thinking mode when tools are present.
 */
function requiresReasoningContentPassback(record) {
    const api = record.api;
    const completions = isPlainObject(api) ? api["chat-completions"] : undefined;
    const compatibility = isPlainObject(completions) ? completions.compatibility : undefined;
    return isPlainObject(compatibility) && compatibility.reasoning_field === "reasoning_content";
}
/**
 * The compat block for one derived model. Dropped entirely when the channel
 * changes, so a responses model never inherits completions overrides.
 */
function compatFor(record, template, api) {
    if (api !== template.api)
        return undefined;
    if (!requiresReasoningContentPassback(record))
        return template.compat;
    return { ...template.compat, requiresReasoningContentOnAssistantMessages: true };
}
/**
 * Alphabetical by id, with a plain comparison rather than `localeCompare`: the
 * ids are lowercase ASCII, and ICU collation orders `kimi-k2.5-free` and
 * `kimi-k2-5-free` differently depending on the host's locale — a list whose
 * order depends on the machine is not an order anyone can rely on.
 */
export function byId(a, b) {
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}
/** Pure: list entries → catalogue. Anything that is not a free chat entry is skipped. */
export function derive(entries, options) {
    const candidates = [];
    const seen = new Set();
    for (const entry of entries) {
        if (!isPlainObject(entry) || typeof entry.id !== "string" || entry.id === "" || seen.has(entry.id))
            continue;
        if (!isFree(entry))
            continue;
        seen.add(entry.id);
        candidates.push(buildModel(entry, options.template, options.knownApis));
    }
    // Sorted HERE, at the one place the list is born, so the snapshot, the
    // visible set and the picker all inherit the same order instead of each
    // deciding for itself.
    return { candidates: candidates.sort(byId) };
}
/** D1: one GET. Every failure mode is reported, never thrown. */
export async function fetchOfficialList(options) {
    const { fetchImpl, request = zenListRequest(), timeoutMs = DEFAULT_TIMEOUT_MS, maxBytes = DEFAULT_MAX_BYTES, } = options;
    try {
        const response = await fetchImpl(request.url, {
            headers: { ...request.headers },
            signal: AbortSignal.timeout(timeoutMs),
        });
        if (!response.ok)
            return { kind: "failed", reason: `http ${response.status}` };
        const text = await readBounded(response, maxBytes);
        if (text === null)
            return { kind: "failed", reason: "response too large" };
        let body;
        try {
            body = JSON.parse(text);
        }
        catch {
            // A stable reason, not the engine's SyntaxError text: callers and logs
            // compare on this vocabulary.
            return { kind: "failed", reason: "malformed response body" };
        }
        const list = parseOfficialList(body);
        if (list === null)
            return { kind: "failed", reason: "unrecognised model list" };
        return { kind: "ok", list };
    }
    catch (error) {
        const name = isPlainObject(error) && typeof error.name === "string" ? error.name : "Error";
        const message = error instanceof Error ? error.message : String(error);
        return { kind: "failed", reason: name === "TimeoutError" || name === "AbortError" ? "timeout" : message };
    }
}
/**
 * Read a response body, refusing to grow past `maxBytes`.
 *
 * `await response.text()` first and check the length afterwards can only
 * REJECT an oversized body, never prevent it: by the time the check ran, the
 * whole thing was already resident in the DSH process. A 20MB ceiling that still
 * admits a 400MB error page buys nothing, and the symptom (a desktop host dying
 * with no visible cause) is three steps removed from the reason. Measured
 * 2026-09-30: a 40MB body against a 20MB cap buffered all 40MB.
 *
 * `content-length` is consulted first because it makes the common case free; the
 * streaming read is what makes the chunked case honest. Returns null when the
 * body is refused, which the caller reports as `response too large` — the same
 * reason string as before, so nothing downstream had to change.
 */
async function readBounded(response, maxBytes) {
    const declared = Number(response.headers.get("content-length") ?? "");
    if (Number.isFinite(declared) && declared > maxBytes)
        return null;
    const body = response.body;
    // No stream (a hand-rolled fetch double, or a Response subclass): fall back to
    // the buffered read and check afterwards. Slightly less safe, and the only way
    // to serve those inputs at all.
    if (!body || typeof body.getReader !== "function") {
        const text = await response.text();
        return Buffer.byteLength(text, "utf8") > maxBytes ? null : text;
    }
    const reader = body.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done)
            break;
        if (value === undefined)
            continue;
        total += value.byteLength;
        // Stop the transfer rather than finishing it: the point of the cap is not
        // to spend the memory, and cancelling is what actually returns it.
        if (total > maxBytes) {
            await reader.cancel().catch(() => undefined);
            return null;
        }
        chunks.push(value);
    }
    return Buffer.concat(chunks).toString("utf8");
}
/** The two channels this provider speaks, and so the only values worth keeping. */
const MEASURED_CHANNELS = ["openai-completions", "openai-responses"];
export function isMeasuredChannel(value) {
    return typeof value === "string" && MEASURED_CHANNELS.includes(value);
}
/**
 * Point a model at the channel it was last MEASURED on.
 *
 * The single place that claim is applied. Two callers, one rule: the round when
 * it records the answer, and the warm read when it adopts a cache that already
 * holds one — which is the half that makes it survive a restart. Without both,
 * the probe knows and nothing else does.
 */
export function applyMeasuredChannel(models, probes) {
    for (const model of models) {
        const measured = probes[model.id]?.api;
        if (measured === undefined || measured === model.api)
            continue;
        model.api = measured;
    }
}
/** Read persisted verdicts defensively: a damaged entry is dropped, not fatal. */
function readProbes(value) {
    if (!isPlainObject(value))
        return {};
    const probes = {};
    for (const [id, entry] of Object.entries(value)) {
        if (!isPlainObject(entry))
            continue;
        if (entry.verdict !== "ok" && entry.verdict !== "dead")
            continue;
        if (typeof entry.at !== "number" || !Number.isFinite(entry.at))
            continue;
        probes[id] = {
            verdict: entry.verdict,
            at: entry.at,
            ...(typeof entry.reason === "string" && entry.reason !== "" ? { reason: entry.reason } : {}),
            ...(entry.swept === true ? { swept: true } : {}),
            ...(isMeasuredChannel(entry.api) ? { api: entry.api } : {}),
        };
    }
    return probes;
}
/** D5: `$DSH_HOME/dsh-opencode-free/catalog.json` (same convention as dsh-pocket). */
export function cachePath(env = process.env) {
    const home = env.DSH_HOME !== undefined && env.DSH_HOME !== "" ? env.DSH_HOME : join(homedir(), ".dsh");
    return join(home, "dsh-opencode-free", "catalog.json");
}
/**
 * Any unreadable/foreign cache is simply "no cache" — never an error.
 *
 * Version 1 files (written before the list became the source) still carry the
 * verdicts and the last round's report, which are worth keeping across the
 * upgrade; their models dictionary and ETag belong to a source that no longer
 * exists and are dropped, so `fetchedAt` is 0 and the first read fetches.
 */
export async function readCache(path) {
    try {
        return parseCache(await readFile(path, "utf8"));
    }
    catch {
        return null;
    }
}
/**
 * Same answer as {@link readCache}, without yielding. The file holds only the
 * free entries, so a local read is cheap, and the catalogue needs it before the
 * host asks for its first model list: with an asynchronous read that first
 * answer could be empty even though a perfectly good cache is on disk.
 */
export function readCacheSync(path) {
    try {
        return parseCache(readFileSync(path, "utf8"));
    }
    catch {
        return null;
    }
}
function parseCache(text) {
    try {
        const parsed = JSON.parse(text);
        if (!isPlainObject(parsed))
            return null;
        let models;
        let fetchedAt;
        if (parsed.version === CACHE_VERSION) {
            if (!Array.isArray(parsed.models))
                return null;
            models = parsed.models.filter(isPlainObject);
            fetchedAt = typeof parsed.fetchedAt === "number" && Number.isFinite(parsed.fetchedAt) ? parsed.fetchedAt : 0;
        }
        else if (parsed.version === 1) {
            if (!isPlainObject(parsed.models))
                return null;
            models = [];
            fetchedAt = 0;
        }
        else {
            return null;
        }
        return {
            version: CACHE_VERSION,
            fetchedAt,
            models,
            probes: readProbes(parsed.probes),
            lastProbeAt: typeof parsed.lastProbeAt === "number" && Number.isFinite(parsed.lastProbeAt)
                ? parsed.lastProbeAt
                : 0,
            lastRound: readLastRound(parsed.lastRound),
        };
    }
    catch {
        return null;
    }
}
/**
 * The last round's report, read defensively. A damaged or absent field means
 * "no report to show", which is exactly what the panel showed before — the
 * report is a convenience, never a verdict.
 */
function readLastRound(value) {
    if (!isPlainObject(value))
        return undefined;
    const total = value.total;
    const done = value.done;
    if (typeof total !== "number" || !isFinite(total) || total <= 0)
        return undefined;
    if (typeof done !== "number" || !isFinite(done))
        return undefined;
    const results = {};
    if (isPlainObject(value.results)) {
        for (const [id, entry] of Object.entries(value.results)) {
            if (!isPlainObject(entry))
                continue;
            if (entry.status === "ok" && typeof entry.ms === "number") {
                results[id] = { status: "ok", ms: entry.ms };
                continue;
            }
            if (entry.status === "failed" && typeof entry.ms === "number") {
                results[id] = {
                    status: "failed",
                    ms: entry.ms,
                    code: typeof entry.code === "string" ? entry.code : "unknown",
                    http: typeof entry.http === "number" && isFinite(entry.http) ? entry.http : 0,
                    // Both directions, or the report that comes back is not the report
                    // that was written. Keeping only the `false` form meant a row that
                    // really DID remove a model came back with no flag — and
                    // `isFreshRemoval` reads a missing `removed` as a fresh removal, so
                    // a restart re-announced a removal for a round that finished hours
                    // ago.
                    ...(typeof entry.removed === "boolean" ? { removed: entry.removed } : {}),
                    ...(typeof entry.marker === "string" && entry.marker !== "" ? { marker: entry.marker } : {}),
                };
            }
        }
    }
    const targets = Array.isArray(value.targets)
        ? value.targets.filter((id) => typeof id === "string")
        : [];
    return { total, done, results, targets };
}
/** Temp file + rename, so a crash mid-write can never leave a torn cache. */
export async function writeCacheAtomic(path, record) {
    // Unpredictable on purpose. `${path}.${process.pid}.tmp` was both the path and
    // the pid: on a shared machine another local user could pre-create that exact
    // name as a symlink and have `writeFile` follow it.
    const temporary = join(dirname(path), `.catalog.${randomUUID()}.tmp`);
    try {
        // 0700/0600 rather than the umask default: the file records which models
        // this user hides and when each was last probed, which is nobody else's
        // business on a multi-user host.
        await mkdir(dirname(path), { recursive: true, mode: 0o700 });
        const payload = {
            version: CACHE_VERSION,
            fetchedAt: record.fetchedAt,
            models: record.models,
        };
        // Probe fields are omitted until a round has something to record, so a
        // never-probed cache keeps exactly the file shape it had before probing
        // existed (and a catalogue sync must carry the current verdicts forward
        // rather than silently dropping them).
        if (record.probes !== undefined && Object.keys(record.probes).length > 0)
            payload.probes = record.probes;
        if (record.lastProbeAt !== undefined && record.lastProbeAt > 0)
            payload.lastProbeAt = record.lastProbeAt;
        const round = record.lastRound;
        if (round !== undefined && round.total > 0)
            payload.lastRound = round;
        await writeFile(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
        await rename(temporary, path);
        return true;
    }
    catch {
        // A cache we cannot persist is a performance loss, never a failure.
        //
        // But the staged file is OURS: on Windows a rename onto a target that is
        // being written concurrently fails with EPERM/EBUSY, and leaving the staged
        // copy behind means a crash loop accumulates one partial per attempt in the
        // user's own cache directory
        // test rather than by inspection).
        await rm(temporary, { force: true }).catch(() => undefined);
        return false;
    }
}
/** Strongest-first thinking levels; `off` is never a badge. */
const THINKING_LEVEL_RANK = ["max", "xhigh", "high", "medium", "low", "minimal"];
/**
 * The badge level for one derived record: the strongest level whose map value
 * is a real (string) entry. A string-valued map entry IS a published level —
 * `thinkingLevelMapFor` only writes identity entries for published names and
 * `null` for unpublished ones — so this reads the same fact back without
 * re-parsing the list. No map, or no string entry, means no badge.
 */
export function topThinkingLevel(model) {
    const map = model.thinkingLevelMap;
    if (!map || typeof map !== "object")
        return null;
    for (const level of THINKING_LEVEL_RANK) {
        if (typeof map[level] === "string")
            return level;
    }
    return null;
}
/** Project one effective record to the panel's capability card. */
export function modelCapability(model) {
    return {
        id: model.id,
        image: Array.isArray(model.input) && model.input.includes("image"),
        thinking: topThinkingLevel(model),
    };
}
/** Empty until a list is adopted: there is no offline floor to show instead. */
export function initialState() {
    return {
        cache: null,
        models: [],
        source: "none",
        updatedAt: 0,
        unclassified: 0,
        inflight: null,
        probes: {},
        lastProbeAt: 0,
        probeUntrusted: false,
        probeRun: { running: false, total: 0, done: 0, current: null, results: {}, targets: [], startedAt: 0 },
        probeInflight: null,
    };
}
/**
 * D2: at most one round per LOCAL calendar day — the plan's rule, compared
 * against the previous round's local day via the injected `now` so a test can
 * place both ends exactly.
 *
 * Calendar day, not a rolling 24h window: the bound is on how much of the
 * shared anonymous bucket one day's sweep may spend, and "same day" is what a
 * user reading the panel would expect. The known edge is a round at 23:50
 * followed by one at 00:10 — different days, so both run. That is deliberate,
 * not an oversight; `forceProbes` bypasses this gate entirely, so a manual
 * click is never blocked either way.
 */
export function probedToday(lastProbeAt, now) {
    if (lastProbeAt <= 0)
        return false;
    const previous = new Date(lastProbeAt);
    const today = new Date(now());
    return (previous.getFullYear() === today.getFullYear() &&
        previous.getMonth() === today.getMonth() &&
        previous.getDate() === today.getDate());
}
/**
 * The one list the picker and the panel share: the catalogue minus everything
 * a probe judged dead. A dead model is dropped from here and named nowhere —
 * the user asked for it to simply not be in the list, so there is deliberately
 * no companion "unavailable" list to restore or to go stale.
 *
 * `models` itself still carries dead entries, and that is load-bearing rather
 * than untidy: the verdict lives in `probes`, keyed by id, and a model the list
 * drops and later names again must come back with its verdict instead of as a
 * fresh candidate to be re-probed to the same answer.
 */
export function effectiveList(models, probes) {
    // Order comes from where the catalogue is born (derive); this only filters,
    // so it cannot drift from it.
    return models.filter((model) => probes[model.id]?.verdict !== "dead");
}
function effectiveVisible(list) {
    return list.map((model) => model.id);
}
export function catalogueIsStale(updatedAt, now, ttl) {
    // "Never fetched" is stale by definition, not by arithmetic. Testing it as an
    // inequality would let a small or injected clock read 0 as fresh, which is
    // exactly the case where a real question is still outstanding.
    return updatedAt === 0 || now() - updatedAt > ttl;
}
/**
 * How one probe outcome becomes the row the panel paints.
 *
 * This used to live inline in the round loop, where the interesting rule was
 * invisible between the transport plumbing: the card cannot say "failed" without
 * a `code`, and it must not call a re-confirmed death a removal. Both are
 * load-bearing — a row with no reason is the bug this field exists to prevent,
 * and reporting an old verdict as a fresh removal dates a change to this round
 * that happened in an earlier one.
 *
 * `priorVerdict` is read BEFORE the round writes the new one, which is the only
 * reason the `removed` flag can be answered at all.
 */
export function probeRowFor(outcome, elapsed, priorVerdict) {
    if (outcome !== undefined && outcome !== null && outcome.kind === "ok") {
        return { status: "ok", ms: elapsed };
    }
    // A prober that predates the coded outcome still gets a reason: the verdict
    // itself is the coarse fallback, never a silent failure.
    const code = typeof outcome?.code === "string" && outcome.code !== ""
        ? outcome.code
        : outcome?.kind === "dead"
            ? "dead"
            : "unknown";
    return {
        status: "failed",
        ms: elapsed,
        code,
        http: typeof outcome?.http === "number" && isFinite(outcome.http) ? outcome.http : 0,
        ...(code === "dead" ? { removed: priorVerdict !== "dead" } : {}),
        // Which gate marker the body carried, so the refusal names itself instead of
        // arriving as one anonymous "未测到".
        ...(typeof outcome?.marker === "string" && outcome.marker !== "" ? { marker: outcome.marker } : {}),
    };
}
/**
 * A dead verdict is final ONLY once it has been earned by asking every channel.
 * A verdict without that marker predates the sweep, so it gets one re-check:
 * those are precisely the verdicts that may have been a wrong channel refused
 * rather than a model that is gone — and a permanent verdict on a wrong channel
 * is how a working model goes missing for good.
 */
function isSettled(id, probes) {
    const record = probes[id];
    if (record === undefined || record.verdict !== "dead")
        return false;
    return record.swept === true;
}
/**
 * What one round will ask: the models the user has switched ON that no earned
 * verdict has settled — a probe costs a request from a bucket shared by
 * everything behind this egress, so asking about a hidden model is an answer
 * nobody will read. A model the list no longer names is not in `models` at all,
 * so it is out of scope without being asked.
 */
export function planRound(models, probes, hidden) {
    const isShown = (id) => hidden?.(id) !== true;
    return models.filter((model) => isShown(model.id) && !isSettled(model.id, probes));
}
/**
 * Install a list as the catalogue. The one place `state.models` is written, so
 * the warm start and a fetch cannot disagree about what adopting means.
 *
 * A channel a previous process MEASURED is re-applied: without it a refresh
 * would silently revert every model to its declared channel and the very
 * failure the probe ruled out would come back.
 */
function install(state, deps, entries, stamp, unclassified) {
    state.models = derive(entries, { knownApis: deps.knownApis, template: deps.template }).candidates;
    state.source = "official";
    state.updatedAt = stamp;
    state.unclassified = unclassified;
    applyMeasuredChannel(state.models, state.probes);
}
// Warm start: a valid state.cache restores the catalogue without any network.
function adopt(state, deps, record, 
// Restoring the finished-round report belongs to STARTUP. It is what makes a
// restarted host show the last outcome instead of an empty progress area —
// but it is a snapshot of a round that already ended, and an ordinary sync
// re-adopting it mid-round replaced a live `probeRun` (running:true) with
// the previous one (running:false, done:2). The round then carried on
// incrementing `done` on that swapped-in object, so the panel reported 4/2 and
// the wrong tally was persisted. A refresh updates the
// catalogue and the verdicts; it has nothing to say about a round in flight.
restoreRound = false) {
    if (Object.keys(record.probes).length > 0)
        state.probes = { ...record.probes };
    // A record that never held a fetched list (`fetchedAt` 0: verdicts only, or a
    // version 1 file) is NOT a catalogue. Adopting it would empty the picker for
    // the sake of verdicts; keep "no list yet" and take only the probe state. A
    // fetched list that really is empty is a catalogue and is adopted.
    if (record.fetchedAt > 0)
        install(state, deps, record.models, record.fetchedAt, 0);
    else
        applyMeasuredChannel(state.models, state.probes);
    if (record.lastProbeAt > state.lastProbeAt)
        state.lastProbeAt = record.lastProbeAt;
    // The report of a round that already finished, so a restart shows the
    // outcome instead of an empty progress area. `running` stays false: this is
    // a completed round, not one to follow.
    const restored = record.lastRound;
    if (restoreRound && restored !== undefined && restored.total > 0) {
        state.probeRun = {
            running: false,
            total: restored.total,
            done: restored.done,
            current: null,
            results: { ...restored.results },
            targets: Array.isArray(restored.targets) ? restored.targets.slice() : [],
            startedAt: record.lastProbeAt,
        };
    }
    // Verdicts for models the list no longer names are KEPT: a model Zen drops
    // and later names again comes back with its verdict (see effectiveList).
}
async function sync(state, deps) {
    const { path, fetchImpl, request, warmReadTimeoutMs } = deps;
    // Never fetch before the warm read settles: the answer below is adopted over
    // whatever the warm start installed, so letting the two interleave either
    // resurrects a removed model or drops the persisted probe history.
    await Promise.race([
        deps.warm,
        new Promise((resolve) => setTimeout(resolve, warmReadTimeoutMs).unref?.()),
    ]);
    const result = await fetchOfficialList({ fetchImpl, request });
    if (result.kind === "failed")
        return; // failure preserves the current catalogue
    const stamp = deps.now();
    // Carry `lastRound` across the rebuild: a sync is not a probe round and has
    // nothing new to report, but its write replaces the whole record — so
    // omitting the field deletes the last round's report from disk.
    const previousRound = state.cache?.lastRound;
    state.cache = {
        version: CACHE_VERSION,
        fetchedAt: stamp,
        models: result.list.free,
        probes: state.probes,
        lastProbeAt: state.lastProbeAt,
        lastRound: previousRound,
    };
    install(state, deps, result.list.free, stamp, result.list.unclassified);
    await writeCacheAtomic(path, {
        fetchedAt: stamp,
        models: result.list.free,
        probes: state.probes,
        lastProbeAt: state.lastProbeAt,
        lastRound: previousRound,
    });
}
function runSingle(state, deps) {
    if (state.inflight !== null)
        return state.inflight;
    state.inflight = sync(state, deps).finally(() => {
        state.inflight = null;
    });
    return state.inflight;
}
function runProbeSingle(state, deps) {
    if (state.probeInflight !== null)
        return state.probeInflight;
    state.probeInflight = runProbeRound(state, deps).finally(() => {
        state.probeInflight = null;
    });
    return state.probeInflight;
}
/**
 * Exported for tests, and for that is the whole point of the extraction: a round
 * can now be driven with two plain objects, with no factory, no temp directory
 * and no network. Everything else in this file moved for the same reason.
 */
export async function runProbeRound(state, deps) {
    const { path, hidden, probe } = deps;
    // A round reads `state.probes` twice — to decide what is already settled, and
    // to answer `priorVerdict`, which is the only thing that lets it tell a fresh
    // removal from a re-confirmed old one — and `state.models` to decide what to
    // ask. All of it arrives with the warm cache read, which is fire-and-forget.
    //
    // A round that started before that read landed therefore computed every prior
    // verdict as "unknown": it re-asked models it already knew the answer for, and
    // reported old deaths as removals that had just happened. `sync()` already
    // waits on this same promise for this same reason; a round has to as well.
    await Promise.race([
        deps.warm,
        new Promise((resolve) => setTimeout(resolve, deps.warmReadTimeoutMs).unref?.()),
    ]);
    const stamp = deps.now();
    // Ask the list again first. One GET spends no inference quota, so a model the
    // list has withdrawn since the last sync costs nothing: it leaves the
    // catalogue here and is never asked. A failed GET leaves the held list in
    // place, and the round probes that.
    //
    // It is deliberately NOT recorded as a `dead` verdict. `dead` is permanent
    // and learned by asking the model; membership is recomputed from the list on
    // every sync, so a model Zen puts back simply reappears.
    await runSingle(state, deps);
    // A `dead` verdict is final ONLY once it has been earned by asking every
    // channel. A verdict without that marker predates the sweep, so it gets one
    // re-check: those are precisely the verdicts that may have been a wrong
    // channel refused rather than a model that is gone — and a permanent verdict
    // on a wrong channel is how a working model goes missing for good.
    // The round's scope, decided by one pure function.
    const targets = planRound(state.models, state.probes, hidden);
    // The panel polls this while the round runs: a progress pill ("4/10") and
    // one badge per row (ok with latency / failed / probing / waiting). It is
    // replaced wholesale at the start of every round and frozen when the round
    // ends, so a late poll never shows a previous round's leftovers as live.
    state.probeRun = {
        running: true,
        // The round's whole scope, so the panel can tell "queued" from "skipped".
        targets: targets.map((model) => model.id),
        total: targets.length,
        done: 0,
        current: null,
        results: {},
        startedAt: stamp,
    };
    let untrusted = false;
    try {
        for (const model of targets) {
            state.probeRun.current = model.id;
            const started = deps.now();
            let outcome;
            try {
                outcome = await probe(model);
            }
            catch {
                untrusted = true;
                state.probeRun.results[model.id] = {
                    status: "failed",
                    ms: Math.max(0, deps.now() - started),
                    code: "error",
                    http: 0,
                };
                state.probeRun.done += 1;
                continue;
            }
            // The row badge reports whether the model ANSWERED, not what the
            // verdict was: `dead` removes the model from the list, but from this
            // round's point of view it is still "did not answer usably". Only
            // `ok` earns the green badge; everything else is red — and red carries
            // WHY, because a red badge with no reason is not a report.
            const elapsed = Math.max(0, deps.now() - started);
            state.probeRun.results[model.id] = probeRowFor(outcome, elapsed, state.probes[model.id]?.verdict);
            state.probeRun.done += 1;
            if (outcome === undefined || outcome === null || outcome.kind === "inconclusive") {
                untrusted = true;
                continue;
            }
            if (outcome.kind !== "ok" && outcome.kind !== "dead") {
                untrusted = true;
                continue;
            }
            state.probes[model.id] = {
                verdict: outcome.kind,
                at: stamp,
                ...(typeof outcome.reason === "string" && outcome.reason !== "" ? { reason: outcome.reason } : {}),
                // Only an answer names a channel. A refusal is evidence that the
                // channel did not work, not evidence that another one would.
                ...(outcome.kind === "ok" && isMeasuredChannel(outcome.api) ? { api: outcome.api } : {}),
                // Reaching here means the prober exhausted every channel before
                // concluding, so this `dead` is earned and can be final.
                ...(outcome.kind === "dead" ? { swept: true } : {}),
            };
            // Applied HERE, not when the round ends. A row is painted the moment its
            // verdict lands, so a model shown as working must already be routed the
            // way it worked — waiting for the last model to finish left a visibly
            // successful model still going down the channel the probe had just ruled
            // out. The cache write stays once per round.
            if (outcome.kind === "ok")
                applyMeasuredChannel(state.models, state.probes);
        }
    }
    finally {
        state.probeRun.running = false;
        state.probeRun.current = null;
    }
    // The round marker is written even when nothing concluded: it is the only
    // thing that stops a fully-gated day from re-probing on every single read.
    state.lastProbeAt = stamp;
    state.probeUntrusted = untrusted;
    // One atomic write per round, never per model: a half-finished round must
    // not be read back as a complete set of verdicts.
    //
    // Written even when `state.cache` is null — i.e. a first boot whose list
    // fetch failed. With no list there is nothing to probe, so this records only
    // the round marker; `fetchedAt` stays 0, which `adopt` reads as "no list
    // yet", leaving the picker empty while any verdicts survive.
    const report = {
        total: state.probeRun.total,
        done: state.probeRun.done,
        results: state.probeRun.results,
        targets: state.probeRun.targets,
    };
    await writeCacheAtomic(path, {
        fetchedAt: state.cache?.fetchedAt ?? 0,
        models: state.cache?.models ?? [],
        probes: state.probes,
        lastProbeAt: state.lastProbeAt,
        // The report, so the panel's progress area survives a restart.
        lastRound: report,
    });
    // Mirror the write back into the in-memory record. Every sync path carries
    // `state.cache.lastRound` forward rather than re-deriving it, so a round that
    // writes the report to disk without recording it here leaves the NEXT sync
    // carrying `undefined` — which deleted the very report it had just written.
    // Two writers of one field, only one of which updated the state.source of truth:
    // reproduced 2026-09-30 (fixing the sync branch alone was not enough).
    if (state.cache !== null)
        state.cache = { ...state.cache, lastRound: report };
}
export function createCatalog(options) {
    const { template, knownApis, cachePath: path, fetchImpl, ttlMs = CATALOG_TTL_MS, } = options;
    const now = options.now ?? Date.now;
    const probe = options.probe;
    const hidden = options.hidden;
    const state = initialState();
    /**
     * Resolves once the warm state.cache read has settled.
     *
     * The warm start is deliberately fire-and-forget — a container must answer
     * synchronously — but that left it free to land AFTER a sync and replace the
     * fresher section with the older cached one, holding a removed model in the
     * picker for a whole TTL. `sync(state, deps)` therefore waits for this before fetching.
     * The wait is one local `readFile` of the state.cache (megabytes, not a download)
     * and is bounded, so a wedged filesystem delays a sync rather than hanging
     * it forever.
     */
    const WARM_READ_TIMEOUT_MS = 2_000;
    let settleWarm = () => undefined;
    const warm = new Promise((resolve) => {
        settleWarm = resolve;
    });
    // A one-liner over the pure rule above, so the call site reads as a question
    // ("is the catalogue stale?") rather than as an expression.
    const stale = () => catalogueIsStale(state.updatedAt, now, ttlMs);
    // The outside world, named once so the lifted functions can take it.
    const deps = {
        path,
        fetchImpl,
        now,
        request: options.request,
        ttlMs,
        probe,
        hidden,
        template,
        knownApis,
        warmReadTimeoutMs: WARM_READ_TIMEOUT_MS,
        warm,
    };
    // Read synchronously, once: see `readCacheSync`. `settleWarm` still runs so
    // the waits in `sync` and the probe round resolve at once.
    const found = readCacheSync(path);
    if (found !== null) {
        state.cache = found;
        // Adopted whatever its age: a stale state.cache is still a far better answer
        // than an empty picker, and `ensureFresh` revalidates on the first read
        // in the background rather than making the user wait for the network.
        adopt(state, deps, found, true);
    }
    settleWarm();
    /**
     * D2/D6b: one ordered round over the state.models that are still unjudged.
     *
     * Sequential `for…await` on purpose (no concurrency, no batching): the round
     * spends a shared anonymous-quota bucket, and firing 30+ requests at once
     * would both exhaust it faster and hammer upstream.
     *
     * A model already judged `dead` is NOT re-probed. The verdict is final by
     * design: re-asking a model the route has already refused spends quota to
     * re-learn a settled fact, and on this provider that is the difference
     * between ~34 requests a day and ~10. A Zen key does not change this — it
     * raises the quota, not the model list, so a refused model is refused with a
     * key too. Recovery is manual and is for upstream changes (a model coming
     * back, a channel being fixed): delete
     * `$DSH_HOME/dsh-opencode-free/catalog.json` and the next start re-derives
     * and re-state.probes the whole catalogue.
     *
     * Only conclusive verdicts are recorded. An `inconclusive` — or a prober that
     * rejects — leaves the model exactly as it was (D5): one gated IP must never
     * empty the picker.
     */
    return {
        current() {
            // One pass over the single effective list feeds both `visible` and
            // `capabilities`, so the ids and the cards can never disagree.
            const effective = effectiveList(state.models, state.probes);
            return {
                models: state.models.slice(),
                visible: effective.map((model) => model.id),
                capabilities: effective.map(modelCapability),
                source: state.source,
                updatedAt: state.updatedAt,
                unclassified: state.unclassified,
                refreshing: state.inflight !== null,
                probedAt: state.lastProbeAt,
                probeInconclusive: state.probeUntrusted,
            };
        },
        effectiveModels() {
            return effectiveList(state.models, state.probes);
        },
        async ensureFresh() {
            // Single-flight: a read that lands mid-refresh joins it instead of
            // starting a second GET.
            const refresh = state.inflight ?? (stale() ? runSingle(state, deps) : null);
            if (refresh !== null)
                await refresh;
        },
        async forceRefresh() {
            return runSingle(state, deps);
        },
        async runProbes() {
            if (probe === undefined)
                return;
            if (state.probeInflight !== null)
                return state.probeInflight;
            if (probedToday(state.lastProbeAt, now))
                return;
            return runProbeSingle(state, deps);
        },
        async forceProbes() {
            if (probe === undefined)
                return;
            // A manual round still costs one request per model from a bucket shared
            // per egress IP, and the POST route has no rate limit of its own — so
            // repeated clicks spent the whole office's quota. A short floor keeps the
            // button honest without making it useless: the user asked for a fresh
            // answer, not a second one five seconds later.
            if (now() - state.lastProbeAt < FORCED_PROBE_MIN_INTERVAL_MS)
                return;
            return runProbeSingle(state, deps);
        },
        probeProgress() {
            // A copy: the round mutates `state.probeRun` while the panel reads this.
            return {
                running: state.probeRun.running,
                total: state.probeRun.total,
                done: state.probeRun.done,
                current: state.probeRun.current,
                results: { ...state.probeRun.results },
                targets: state.probeRun.targets.slice(),
                startedAt: state.probeRun.startedAt,
            };
        },
    };
}
