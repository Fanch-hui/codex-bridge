export interface CenterEnv {
  DB?: D1Database;
  BUCKET?: R2Bucket;
  MESSAGE_CENTER_ADMIN_EMAIL?: string;
  MESSAGE_CENTER_ATTACHMENT_LIMIT_BYTES?: string;
}

export class ApiError extends Error {
  constructor(public readonly status: number, message: string) { super(message); }
}

export function fail(status: number, message: string): never { throw new ApiError(status, message); }
export function requireDb(env: CenterEnv): D1Database {
  if (!env.DB) fail(503, "消息服务暂不可用");
  return env.DB;
}
export function requireBucket(env: CenterEnv): R2Bucket {
  if (!env.BUCKET) fail(503, "附件服务暂不可用");
  return env.BUCKET;
}
export function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: {
    "cache-control": "no-store", "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer", "cross-origin-resource-policy": "same-origin",
  } });
}
export function isAdmin(request: Request, env: CenterEnv): boolean {
  const expected = env.MESSAGE_CENTER_ADMIN_EMAIL?.trim().toLowerCase();
  const email = request.headers.get("oai-authenticated-user-email")?.trim().toLowerCase();
  return !!expected && !!request.headers.get("oai-authenticated-user-id") && email === expected;
}
export function requireAdmin(request: Request, env: CenterEnv): void {
  if (!request.headers.get("oai-authenticated-user-id")) fail(401, "请先登录 ChatGPT");
  if (!isAdmin(request, env)) fail(403, "当前账号没有管理权限");
}
export function requireOrigin(request: Request): void {
  if (request.headers.get("origin") !== new URL(request.url).origin) fail(403, "请求来源无效");
}
export function requireJson(request: Request): void {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("content-type") ?? "")) {
    fail(415, "请求类型无效");
  }
}
export async function bytes(request: Request, max: number): Promise<Uint8Array> {
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (!Number.isFinite(declared) || declared < 0 || declared > max) fail(413, "内容过大");
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) { await reader.cancel(); fail(413, "内容过大"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}
export async function bodyJson(request: Request, max = 128 * 1024): Promise<Record<string, unknown>> {
  requireJson(request);
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await bytes(request, max))); }
  catch (error) { if (error instanceof ApiError) throw error; fail(400, "请求内容无效"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(400, "请求内容无效");
  return value as Record<string, unknown>;
}
export function valueText(value: unknown, label: string, max: number): string {
  if (typeof value !== "string") fail(400, `${label}无效`);
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > max || trimmed.includes("\0")) fail(400, `${label}无效`);
  return trimmed;
}
export function uuid(value: unknown, label = "编号"): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
    fail(400, `${label}无效`);
  }
  return value.toLowerCase();
}
export function bearer(request: Request): string {
  const match = /^Bearer ([a-f0-9]{64})$/i.exec(request.headers.get("authorization") ?? "");
  if (!match) fail(401, "反馈凭据无效");
  return match[1].toLowerCase();
}
export async function digest(value: string | Uint8Array): Promise<string> {
  const data = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const result = await crypto.subtle.digest("SHA-256", data as BufferSource);
  return Array.from(new Uint8Array(result), b => b.toString(16).padStart(2, "0")).join("");
}
export async function limitRequest(request: Request, db: D1Database, scope: string, limit: number): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const window = Math.floor(now / 3600);
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const key = `${scope}:${window}:${await digest(ip)}`;
  await db.prepare("DELETE FROM rate_limits WHERE expires_at <= ?").bind(now).run();
  const row = await db.prepare(`INSERT INTO rate_limits(bucket,count,expires_at) VALUES(?,1,?)
    ON CONFLICT(bucket) DO UPDATE SET count=count+1 WHERE count<? RETURNING count`)
    .bind(key, (window + 1) * 3600, limit).first();
  if (!row) fail(429, "操作过于频繁，请稍后重试");
}
export function now(): string { return new Date().toISOString(); }
export function serverError(error: unknown): Response {
  const codes: Record<number, string> = { 400: "invalid_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 405: "method_not_allowed", 409: "conflict", 413: "too_large", 415: "invalid_request", 429: "rate_limited", 503: "unavailable" };
  if (error instanceof ApiError) return json({ error: { code: codes[error.status] ?? "request_failed", message: error.message } }, error.status);
  console.error("Message center request failed", error instanceof Error ? error.name : "unknown");
  return json({ error: { code: "internal_error", message: "消息服务暂不可用，请稍后重试" } }, 500);
}
