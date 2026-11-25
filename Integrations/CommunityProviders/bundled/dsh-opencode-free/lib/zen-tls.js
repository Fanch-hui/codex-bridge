import { request as httpsRequest } from "node:https";
import { Readable } from "node:stream";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";
/**
 * The cipher suites the official CLI offers (Bun / BoringSSL), in its order.
 * The inference gate rejects a client whose list differs — Node's default of
 * 52 suites is refused even with byte-identical headers and body — and accepts
 * Node once only this list is aligned. The legacy CBC-SHA suites are part of
 * the list; dropping them is refused. See docs/protocol-notes.md.
 */
export const OPENCODE_TLS_CIPHERS = [
    "TLS_AES_128_GCM_SHA256",
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256",
    "ECDHE-ECDSA-AES128-GCM-SHA256",
    "ECDHE-RSA-AES128-GCM-SHA256",
    "ECDHE-ECDSA-AES256-GCM-SHA384",
    "ECDHE-RSA-AES256-GCM-SHA384",
    "ECDHE-ECDSA-CHACHA20-POLY1305",
    "ECDHE-RSA-CHACHA20-POLY1305",
    "ECDHE-ECDSA-AES128-SHA",
    "ECDHE-RSA-AES128-SHA",
    "ECDHE-ECDSA-AES256-SHA",
    "ECDHE-RSA-AES256-SHA",
    "AES128-GCM-SHA256",
    "AES256-GCM-SHA384",
    "AES128-SHA",
    "AES256-SHA",
].join(":");
/** Setting this to `default` keeps the runtime's own cipher list. */
export const TLS_CIPHERS_ENV = "DSH_OPENCODE_FREE_TLS_CIPHERS";
/**
 * Bun already offers the list, so its own fetch and `node:https` need no help.
 * The environment switch is the way out if the upstream ever changes its rule.
 */
export function needsOpenCodeCiphers() {
    if (process.env[TLS_CIPHERS_ENV]?.trim().toLowerCase() === "default")
        return false;
    return process.versions.bun === undefined;
}
const DECODERS = {
    gzip: createGunzip,
    "x-gzip": createGunzip,
    deflate: createInflate,
    br: createBrotliDecompress,
};
async function requestParts(input, init) {
    const options = (init ?? {});
    const source = input instanceof Request ? input : undefined;
    const url = new URL(source ? source.url : String(input));
    const method = (options.method ?? source?.method ?? "GET").toUpperCase();
    const headers = new Headers(options.headers ?? source?.headers);
    let body;
    if (typeof options.body === "string")
        body = Buffer.from(options.body);
    else if (options.body instanceof Uint8Array)
        body = Buffer.from(options.body);
    else if (options.body instanceof ArrayBuffer)
        body = Buffer.from(options.body);
    else if (options.body === undefined && source && method !== "GET" && method !== "HEAD")
        body = Buffer.from(await source.arrayBuffer());
    else if (options.body !== undefined && options.body !== null)
        throw new TypeError("zenHttpsFetch supports string, Uint8Array and ArrayBuffer bodies only");
    return { url, method, headers, body, signal: options.signal ?? source?.signal ?? undefined };
}
/**
 * A `fetch` over `node:https` that offers {@link OPENCODE_TLS_CIPHERS}. Node's
 * global fetch (undici) takes no per-request TLS options without a dispatcher
 * from a package this plugin does not ship.
 *
 * Covers what the provider's SDK and the catalogue use: string or binary
 * bodies, abort signals, streamed responses. It follows no redirects. Network
 * failures surface as undici's `TypeError("fetch failed")` with the cause
 * attached, which the transport diagnosis reads.
 */
export async function zenHttpsFetch(input, init) {
    const { url, method, headers, body, signal } = await requestParts(input, init);
    if (body !== undefined && !headers.has("content-length"))
        headers.set("content-length", String(body.length));
    const outgoing = {};
    headers.forEach((value, name) => {
        outgoing[name] = value;
    });
    const options = {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port,
        path: `${url.pathname}${url.search}`,
        method,
        headers: outgoing,
        ciphers: OPENCODE_TLS_CIPHERS,
        ...(signal ? { signal } : {}),
    };
    return await new Promise((resolve, reject) => {
        const fail = (error) => {
            if (signal?.aborted)
                return reject(signal.reason ?? error);
            reject(Object.assign(new TypeError("fetch failed"), { cause: error }));
        };
        const req = httpsRequest(options, (res) => {
            const responseHeaders = new Headers();
            for (const [name, value] of Object.entries(res.headers)) {
                for (const item of Array.isArray(value) ? value : value === undefined ? [] : [value]) {
                    responseHeaders.append(name, item);
                }
            }
            const status = res.statusCode ?? 0;
            const encoding = String(res.headers["content-encoding"] ?? "").toLowerCase();
            const decode = DECODERS[encoding];
            let stream = res;
            if (decode) {
                stream = res.pipe(decode());
                res.on("error", (error) => stream.destroy(error));
                responseHeaders.delete("content-encoding");
                responseHeaders.delete("content-length");
            }
            const empty = status === 204 || status === 205 || status === 304 || method === "HEAD";
            if (empty)
                stream.resume();
            resolve(new Response(empty ? null : Readable.toWeb(stream), {
                status,
                statusText: res.statusMessage ?? "",
                headers: responseHeaders,
            }));
        });
        req.on("error", fail);
        req.end(body);
    });
}
