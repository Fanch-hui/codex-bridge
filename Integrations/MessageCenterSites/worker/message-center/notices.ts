import { digest, fail, now, uuid, valueText } from "./common";

type Status = "draft" | "published" | "withdrawn";
type Priority = "normal" | "important";
type NoticeAction = { kind: "update" | "url"; label: string; url?: string };
interface NoticeRow {
  id: string; request_hash: string; title: string; body: string; priority: Priority; status: Status;
  action: string | null; platforms: string; min_version: string | null; max_version: string | null;
  revision: number; published_at: string | null; updated_at: string; expires_at: string | null;
}
interface Notice {
  id: string; title: string; body: string; priority: Priority; status: Status;
  action: NoticeAction | null; platforms: string[]; minVersion: string | null; maxVersion: string | null;
  revision: number; publishedAt: string | null; updatedAt: string; expiresAt: string | null;
}
const platforms = ["macos", "windows", "linux"];
const statuses = ["draft", "published", "withdrawn"];
const priorities = ["normal", "important"];
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

function optionalVersion(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.length > 50 || !semver.test(value)) fail(400, "版本号无效");
  return value;
}
function compareVersion(a: string, b: string): number {
  const left = a.split("."); const right = b.split(".");
  for (let i = 0; i < left.length; i++) {
    if (left[i].length !== right[i].length) return left[i].length - right[i].length;
    if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
  }
  return 0;
}
function date(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.length > 40 || Number.isNaN(Date.parse(value))) fail(400, "到期时间无效");
  return new Date(value).toISOString();
}
function parseAction(value: unknown): NoticeAction | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) fail(400, "通知操作无效");
  const action = value as Record<string, unknown>;
  const label = valueText(action.label, "操作名称", 60);
  if (action.kind === "update") {
    if (action.url !== undefined && action.url !== null && action.url !== "") fail(400, "更新操作不能包含链接");
    return { kind: "update", label };
  }
  if (action.kind !== "url" || typeof action.url !== "string" || action.url.length > 2048) fail(400, "操作链接无效");
  let url: URL;
  try { url = new URL(action.url); } catch { fail(400, "操作链接无效"); }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (url.protocol !== "https:" || url.username || url.password || !host.includes(".") ||
      /^(?:[0-9]+\.)+[0-9]+$/.test(host) || host.includes(":") ||
      host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") ||
      host.endsWith(".internal") || host.endsWith(".home.arpa")) fail(400, "请填写公开的 HTTPS 链接");
  return { kind: "url", label, url: url.toString() };
}
function parsePlatforms(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > platforms.length || value.some(v => typeof v !== "string" || !platforms.includes(v))) {
    fail(400, "平台范围无效");
  }
  return [...new Set(value as string[])];
}
function present(row: NoticeRow): Notice {
  return {
    id: row.id, title: row.title, body: row.body, priority: row.priority, status: row.status,
    action: row.action ? JSON.parse(row.action) : null, platforms: JSON.parse(row.platforms), minVersion: row.min_version, maxVersion: row.max_version,
    revision: row.revision, publishedAt: row.published_at, updatedAt: row.updated_at, expiresAt: row.expires_at,
  };
}
function parsed(input: Record<string, unknown>, previous?: Notice) {
  const title = valueText(input.title ?? previous?.title, "标题", 200);
  const body = valueText(input.body ?? previous?.body, "正文", 16000);
  if (new TextEncoder().encode(body).length > 16000) fail(413, "通知正文不能超过 16,000 字节");
  const priority = input.priority ?? previous?.priority ?? "normal";
  const status = input.status ?? previous?.status ?? "draft";
  if (typeof priority !== "string" || !priorities.includes(priority)) fail(400, "重要程度无效");
  if (typeof status !== "string" || !statuses.includes(status)) fail(400, "通知状态无效");
  const action = input.action === undefined ? previous?.action ?? null : parseAction(input.action);
  const selected = input.platforms === undefined ? previous?.platforms ?? [] : parsePlatforms(input.platforms);
  const min = input.minVersion === undefined ? previous?.minVersion ?? null : optionalVersion(input.minVersion);
  const max = input.maxVersion === undefined ? previous?.maxVersion ?? null : optionalVersion(input.maxVersion);
  if (min && max && compareVersion(min, max) > 0) fail(400, "最低版本不能高于最高版本");
  const expires = input.expiresAt === undefined ? previous?.expiresAt ?? null : date(input.expiresAt);
  return { title, body, priority, status, action, platforms: selected, minVersion: min, maxVersion: max, expiresAt: expires };
}
export async function listAdminNotices(db: D1Database): Promise<Notice[]> {
  const rows = await db.prepare("SELECT * FROM notices ORDER BY updated_at DESC, id DESC LIMIT 200").all<NoticeRow>();
  return rows.results.map(present);
}
export async function publicNotices(db: D1Database, platform: string | null, version: string | null, cursor: string | null) {
  if (!platform || !platforms.includes(platform)) fail(400, "平台无效");
  if (!version || !semver.test(version) || version.length > 50) fail(400, "版本号无效");
  if (cursor !== null && !/^(0|[1-9]\d{0,7})$/.test(cursor)) fail(400, "分页无效");
  let offset = Number(cursor ?? "0");
  const result: object[] = [];
  let encodedBytes = 128;
  const budget = 900 * 1024;
  for (let page = 0; page < 5; page++) {
    const rows = await db.prepare(`SELECT * FROM notices WHERE status='published'
      AND (expires_at IS NULL OR expires_at>?) AND (platforms='[]' OR EXISTS
        (SELECT 1 FROM json_each(notices.platforms) WHERE value=?))
      ORDER BY CASE priority WHEN 'important' THEN 0 ELSE 1 END,published_at DESC,id DESC LIMIT 100 OFFSET ?`)
      .bind(now(),platform,offset).all<NoticeRow>();
    for (let i = 0; i < rows.results.length; i++) {
      const n = present(rows.results[i]);
      if ((n.minVersion && compareVersion(version,n.minVersion)<0) || (n.maxVersion && compareVersion(version,n.maxVersion)>0)) {
        offset++;
        continue;
      }
      const item = { id: n.id, title: n.title, body: n.body, priority: n.priority, action: n.action, revision: n.revision,
        publishedAt: n.publishedAt, updatedAt: n.updatedAt, expiresAt: n.expiresAt };
      const size = new TextEncoder().encode(JSON.stringify(item)).length + 1;
      if (result.length && encodedBytes + size > budget) {
        return { notices: result, hasMore: true, nextCursor: String(offset) };
      }
      result.push(item); encodedBytes += size; offset++;
      if (result.length === 50) {
        const hasMore = i + 1 < rows.results.length || rows.results.length === 100;
        return { notices: result, hasMore, nextCursor: hasMore ? String(offset) : null };
      }
    }
    if (rows.results.length < 100) return { notices: result, hasMore: false, nextCursor: null };
  }
  return { notices: result, hasMore: true, nextCursor: String(offset) };
}
export async function getNotice(db: D1Database, id: string): Promise<Notice> {
  const row = await db.prepare("SELECT * FROM notices WHERE id=?").bind(uuid(id)).first<NoticeRow>();
  if (!row) fail(404, "通知不存在");
  return present(row);
}
export async function createNotice(db: D1Database, input: Record<string, unknown>): Promise<Notice> {
  const n = parsed(input); const id = input.requestId === undefined ? crypto.randomUUID() : uuid(input.requestId, "请求编号"); const time = now();
  const published = n.status === "published" ? time : null;
  const requestHash = await digest(JSON.stringify(n));
  await db.prepare(`INSERT OR IGNORE INTO notices(id,request_hash,title,body,priority,status,action,platforms,min_version,max_version,revision,published_at,updated_at,expires_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,1,?,?,?)`).bind(id,requestHash,n.title,n.body,n.priority,n.status,n.action ? JSON.stringify(n.action) : null,JSON.stringify(n.platforms),
    n.minVersion,n.maxVersion,published,time,n.expiresAt).run();
  const row = await db.prepare("SELECT * FROM notices WHERE id=?").bind(id).first<NoticeRow>();
  if (!row || row.request_hash !== requestHash) fail(409, "通知请求与已有记录不一致");
  return present(row);
}
export async function updateNotice(db: D1Database, id: string, input: Record<string, unknown>): Promise<Notice> {
  const existing = await getNotice(db, id); const n = parsed(input, existing); const time = now();
  const published = n.status === "published" && existing.status !== "published" ? time : existing.publishedAt;
  await db.prepare(`UPDATE notices SET title=?,body=?,priority=?,status=?,action=?,platforms=?,min_version=?,max_version=?,
    revision=revision+1,published_at=?,updated_at=?,expires_at=? WHERE id=?`)
    .bind(n.title,n.body,n.priority,n.status,n.action ? JSON.stringify(n.action) : null,JSON.stringify(n.platforms),n.minVersion,n.maxVersion,published,time,n.expiresAt,existing.id).run();
  return getNotice(db, existing.id);
}
