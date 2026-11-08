import { bearer, bytes, digest, fail, limitRequest, now, requireBucket, uuid, valueText } from "./common";
import type { CenterEnv } from "./common";

interface FeedbackRow {
  id: string; token_hash: string; request_id: string; request_hash: string; category: string;
  status: string; app_version: string; platform: string; created_at: string; updated_at: string;
}
interface MessageRow {
  id: string; feedback_id: string; request_id: string; request_hash: string; author: string;
  body: string; created_at: string; sequence: number;
}
interface AttachmentRow {
  id: string; token_hash: string; feedback_id: string | null; message_id: string | null;
  name: string; content_type: string; size: number; digest: string; state: string; created_at: string;
}
const maxBytes = 10 * 1024 * 1024;
const supported = ["image/png", "image/jpeg", "image/webp"];
const categories = ["bug", "suggestion", "other"];
const platforms = ["macos", "windows", "linux"];
const statuses = ["received", "processing", "resolved"];
function feedbackBody(value: unknown, label: string): string {
  const text = valueText(value, label, 16000);
  if (new TextEncoder().encode(text).length > 16000) fail(413, `${label}不能超过 16,000 字节`);
  return text;
}

function publicAttachment(row: AttachmentRow) {
  return { id: row.id, name: row.name, contentType: row.content_type, size: row.size };
}
function tokenHash(request: Request): Promise<string> { return digest(bearer(request)); }
function attachmentIDs(input: unknown): string[] {
  if (input === undefined || input === null) return [];
  if (!Array.isArray(input) || input.length > 3) fail(400, "附件数量无效");
  const ids = input.map(item => {
    if (!item || typeof item !== "object" || Array.isArray(item)) fail(400, "附件无效");
    return uuid((item as Record<string, unknown>).id, "附件编号");
  });
  if (new Set(ids).size !== ids.length) fail(400, "附件重复");
  return ids;
}
function condition(ids: string[], hash: string): { sql: string; values: unknown[] } {
  if (!ids.length) return { sql: "1=1", values: [] };
  return { sql: `(SELECT COUNT(*) FROM attachments WHERE id IN (${ids.map(() => "?").join(",")})
    AND token_hash=? AND state='ready' AND message_id IS NULL)=?`, values: [...ids, hash, ids.length] };
}
function presentFeedback(row: FeedbackRow, messages: object[]) {
  return { id: row.id, category: row.category, status: row.status, appVersion: row.app_version,
    platform: row.platform, createdAt: row.created_at, updatedAt: row.updated_at, messages };
}
function presentMessage(row: MessageRow, items: AttachmentRow[]) {
  return { id: row.id, author: row.author, body: row.body, createdAt: row.created_at,
    attachments: items.filter(item => item.message_id === row.id).map(publicAttachment) };
}
async function feedbackRow(db: D1Database, id: string): Promise<FeedbackRow> {
  const row = await db.prepare("SELECT * FROM feedback WHERE id=?").bind(uuid(id, "反馈编号")).first<FeedbackRow>();
  if (!row) fail(404, "反馈不存在");
  return row;
}
export async function getFeedback(db: D1Database, id: string, hash?: string) {
  const row = await feedbackRow(db, id);
  if (hash !== undefined && row.token_hash !== hash) fail(404, "反馈不存在");
  const [messages, attachments] = await Promise.all([
    db.prepare("SELECT * FROM messages WHERE feedback_id=? ORDER BY sequence ASC LIMIT 80").bind(row.id).all<MessageRow>(),
    db.prepare("SELECT * FROM attachments WHERE feedback_id=? AND state='ready' ORDER BY created_at,id").bind(row.id).all<AttachmentRow>(),
  ]);
  return presentFeedback(row, messages.results.map(item => presentMessage(item, attachments.results)));
}
export async function clientFeedback(request: Request, db: D1Database, id: string) {
  return getFeedback(db, id, await tokenHash(request));
}
export async function listFeedback(db: D1Database, rawCursor: string | null) {
  if (rawCursor !== null && !/^(0|[1-9]\d{0,4})$/.test(rawCursor)) fail(400, "分页无效");
  const offset = Number(rawCursor ?? "0");
  if (offset > 10000) fail(400, "分页无效");
  const rows = await db.prepare("SELECT * FROM feedback ORDER BY updated_at DESC,id DESC LIMIT 21 OFFSET ?")
    .bind(offset).all<FeedbackRow>();
  const visible = rows.results.slice(0, 20);
  if (!visible.length) return { feedbacks: [], nextCursor: null };
  const placeholders = visible.map(() => "?").join(",");
  const messages = await db.prepare(`SELECT * FROM messages WHERE sequence IN
    (SELECT MIN(sequence) FROM messages WHERE feedback_id IN (${placeholders}) GROUP BY feedback_id)`)
    .bind(...visible.map(row => row.id)).all<MessageRow>();
  return { feedbacks: visible.map(row => presentFeedback(row,
    messages.results.filter(message => message.feedback_id === row.id).map(message => presentMessage(message, [])))),
    nextCursor: rows.results.length > 20 && offset + 20 <= 10000 ? String(offset + 20) : null };
}
export async function createFeedback(request: Request, db: D1Database, input: Record<string, unknown>) {
  const hash = await tokenHash(request); const requestId = uuid(input.requestId, "请求编号");
  const category = valueText(input.category, "反馈类型", 20);
  if (!categories.includes(category)) fail(400, "反馈类型无效");
  const body = feedbackBody(input.body, "反馈内容");
  const appVersion = valueText(input.appVersion, "应用版本", 50);
  const platform = valueText(input.platform, "平台", 20);
  if (!platforms.includes(platform)) fail(400, "平台无效");
  const ids = attachmentIDs(input.attachments);
  const requestHash = await digest(JSON.stringify({ requestId, category, body, appVersion, platform, ids }));
  const existing = await db.prepare("SELECT * FROM feedback WHERE token_hash=?").bind(hash).first<FeedbackRow>();
  if (existing) {
    if (existing.request_id !== requestId || existing.request_hash !== requestHash) fail(409, "反馈请求与已有记录不一致");
    return getFeedback(db, existing.id, hash);
  }
  await limitRequest(request, db, "feedback", 10);
  const id = crypto.randomUUID(); const messageId = crypto.randomUUID(); const time = now();
  const cond = condition(ids, hash);
  const statements = [
    db.prepare(`INSERT OR IGNORE INTO feedback(id,token_hash,request_id,request_hash,category,status,app_version,platform,created_at,updated_at)
      SELECT ?,?,?,?,?,'received',?,?,?,? WHERE ${cond.sql}`)
      .bind(id,hash,requestId,requestHash,category,appVersion,platform,time,time,...cond.values),
    db.prepare(`INSERT OR IGNORE INTO messages(id,feedback_id,request_id,request_hash,author,body,created_at)
      SELECT ?,?,?,?,'user',?,? WHERE EXISTS(SELECT 1 FROM feedback WHERE id=? AND token_hash=?)`)
      .bind(messageId,id,requestId,requestHash,body,time,id,hash),
  ];
  if (ids.length) statements.push(db.prepare(`UPDATE attachments SET feedback_id=?,message_id=?
    WHERE id IN (${ids.map(() => "?").join(",")}) AND token_hash=? AND message_id IS NULL
    AND EXISTS(SELECT 1 FROM messages WHERE id=? AND feedback_id=?)`).bind(id,messageId,...ids,hash,messageId,id));
  await db.batch(statements);
  const result = await db.prepare("SELECT * FROM feedback WHERE token_hash=?").bind(hash).first<FeedbackRow>();
  if (!result) fail(409, "附件不可用，请重新选择");
  if (result.request_id !== requestId || result.request_hash !== requestHash) fail(409, "反馈请求与已有记录不一致");
  return getFeedback(db, result.id, hash);
}
export async function addMessage(db: D1Database, id: string, input: Record<string, unknown>, author: "user" | "admin", hash?: string) {
  const row = await feedbackRow(db, id);
  if (hash !== undefined && row.token_hash !== hash) fail(404, "反馈不存在");
  const requestId = uuid(input.requestId, "请求编号"); const body = feedbackBody(input.body, "回复内容");
  const ids = attachmentIDs(input.attachments);
  if (author === "admin" && ids.length) fail(400, "管理员回复暂不支持上传附件");
  const requestHash = await digest(JSON.stringify({ requestId, author, body, ids }));
  const existing = await db.prepare("SELECT * FROM messages WHERE feedback_id=? AND request_id=?")
    .bind(row.id,requestId).first<MessageRow>();
  if (existing) {
    if (existing.request_hash !== requestHash) fail(409, "回复请求与已有记录不一致");
    return getFeedback(db, row.id, hash);
  }
  const idNew = crypto.randomUUID(); const time = now(); const cond = condition(ids, row.token_hash);
  const statements = [
    db.prepare(`INSERT OR IGNORE INTO messages(id,feedback_id,request_id,request_hash,author,body,created_at)
      SELECT ?,?,?,?,?,?,? WHERE ${cond.sql}
      AND (SELECT COUNT(*) FROM messages WHERE feedback_id=?)<80
      AND COALESCE((SELECT SUM(length(CAST(json_quote(body) AS BLOB))) FROM messages WHERE feedback_id=?),0)
        + length(CAST(json_quote(?) AS BLOB))<=1700000`)
      .bind(idNew,row.id,requestId,requestHash,author,body,time,...cond.values,row.id,row.id,body),
    db.prepare(`UPDATE feedback SET updated_at=?,status=CASE WHEN ?='user' AND status='resolved' THEN 'received' ELSE status END
      WHERE id=? AND EXISTS(SELECT 1 FROM messages WHERE id=?)`).bind(time,author,row.id,idNew),
  ];
  if (ids.length) statements.push(db.prepare(`UPDATE attachments SET feedback_id=?,message_id=?
    WHERE id IN (${ids.map(() => "?").join(",")}) AND token_hash=? AND message_id IS NULL
    AND EXISTS(SELECT 1 FROM messages WHERE id=? AND feedback_id=?)`).bind(row.id,idNew,...ids,row.token_hash,idNew,row.id));
  await db.batch(statements);
  const result = await db.prepare("SELECT * FROM messages WHERE feedback_id=? AND request_id=?")
    .bind(row.id,requestId).first<MessageRow>();
  if (!result) {
    const usage = await db.prepare(`SELECT COUNT(*) AS count,COALESCE(SUM(length(CAST(json_quote(body) AS BLOB))),0) AS total
      FROM messages WHERE feedback_id=?`).bind(row.id).first<{count:number; total:number}>();
    if (usage && (usage.count >= 80 || usage.total + new TextEncoder().encode(JSON.stringify(body)).length > 1700000)) {
      fail(413, "该反馈对话已达到长度上限，请新建反馈");
    }
    fail(409, "附件不可用，请重新选择");
  }
  if (result.request_hash !== requestHash) fail(409, "回复请求与已有记录不一致");
  return getFeedback(db, row.id, hash);
}
export async function clientMessage(request: Request, db: D1Database, id: string, input: Record<string, unknown>) {
  const hash = await tokenHash(request);
  const row = await feedbackRow(db, id);
  if (row.token_hash !== hash) fail(404, "反馈不存在");
  const requestId = uuid(input.requestId, "请求编号");
  const previous = await db.prepare("SELECT 1 FROM messages WHERE feedback_id=? AND request_id=?").bind(row.id, requestId).first();
  if (!previous) await limitRequest(request, db, "message", 60);
  return addMessage(db, id, input, "user", hash);
}
export async function changeStatus(db: D1Database, id: string, status: unknown) {
  if (typeof status !== "string" || !statuses.includes(status)) fail(400, "反馈状态无效");
  const row = await feedbackRow(db, id);
  await db.prepare("UPDATE feedback SET status=?,updated_at=? WHERE id=?").bind(status,now(),row.id).run();
  return getFeedback(db, row.id);
}

function imageMatches(type: string, data: Uint8Array): boolean {
  if (type === "image/jpeg") {
    return data.length >= 4 && data[0] === 255 && data[1] === 216 && data[data.length - 2] === 255 && data[data.length - 1] === 217;
  }
  if (type === "image/webp") {
    if (data.length < 20 || new TextDecoder().decode(data.slice(0,4)) !== "RIFF" ||
        new TextDecoder().decode(data.slice(8,12)) !== "WEBP") return false;
    const size = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(4, true);
    return size + 8 === data.length && ["VP8 ", "VP8L", "VP8X"].includes(new TextDecoder().decode(data.slice(12,16)));
  }
  if (data.length < 45 || ![137,80,78,71,13,10,26,10].every((v,i) => data[i] === v)) return false;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let offset = 8; let header = false; let pixels = false;
  while (offset + 12 <= data.length) {
    const length = view.getUint32(offset); const next = offset + length + 12;
    if (next > data.length) return false;
    const kind = new TextDecoder().decode(data.slice(offset + 4, offset + 8));
    if (!header) {
      if (kind !== "IHDR" || length !== 13 || view.getUint32(offset + 8) === 0 || view.getUint32(offset + 12) === 0) return false;
      header = true;
    } else if (kind === "IDAT") pixels = true;
    else if (kind === "IEND") return length === 0 && pixels && next === data.length;
    offset = next;
  }
  return false;
}
function fileName(request: Request): string {
  let result: string;
  try { result = decodeURIComponent(request.headers.get("x-filename") ?? "image"); }
  catch { fail(400, "文件名无效"); }
  result = result.replace(/[\\/\x00-\x1f\x7f]/g, "_").trim();
  if (!result || result.length > 128) fail(400, "文件名无效");
  return result;
}
async function drainDeletionQueue(db: D1Database, bucket: R2Bucket): Promise<void> {
  const rows = await db.prepare("SELECT id FROM object_deletions ORDER BY created_at,id LIMIT 3").all<{id: string}>();
  for (const row of rows.results) {
    await bucket.delete(`attachments/${row.id}`);
    await db.prepare("DELETE FROM object_deletions WHERE id=?").bind(row.id).run();
  }
}
function storageLimit(env: CenterEnv): number {
  if (env.MESSAGE_CENTER_ATTACHMENT_LIMIT_BYTES === undefined) return 512 * 1024 * 1024;
  const value = Number(env.MESSAGE_CENTER_ATTACHMENT_LIMIT_BYTES);
  if (!Number.isSafeInteger(value) || value <= 0 || value > 10 * 1024 * 1024 * 1024) fail(503, "附件服务配置无效");
  return value;
}
export async function deleteFeedback(env: CenterEnv, db: D1Database, rawID: string): Promise<void> {
  const id = uuid(rawID, "反馈编号");
  const row = await db.prepare("SELECT * FROM feedback WHERE id=?").bind(id).first<FeedbackRow>();
  if (!row) return;
  const bucket = requireBucket(env);
  await db.batch([
    db.prepare(`INSERT OR IGNORE INTO object_deletions(id,size,created_at)
      SELECT id,size,? FROM attachments WHERE token_hash=?`).bind(now(),row.token_hash),
    db.prepare("DELETE FROM attachments WHERE token_hash=?").bind(row.token_hash),
    db.prepare("DELETE FROM messages WHERE feedback_id=?").bind(id),
    db.prepare("DELETE FROM feedback WHERE id=?").bind(id),
  ]);
  try { await drainDeletionQueue(db, bucket); }
  catch (error) { console.error("Attachment cleanup pending", error instanceof Error ? error.name : "unknown"); }
}
async function cleanPending(db: D1Database, bucket: R2Bucket): Promise<void> {
  const before = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const rows = await db.prepare("SELECT id FROM attachments WHERE message_id IS NULL AND created_at<? LIMIT 3")
    .bind(before).all<{id: string}>();
  for (const row of rows.results) {
    const claimed = await db.prepare("UPDATE attachments SET state='deleting' WHERE id=? AND message_id IS NULL AND created_at<? RETURNING id")
      .bind(row.id, before).first();
    if (!claimed) continue;
    await bucket.delete(`attachments/${row.id}`);
    await db.prepare("DELETE FROM attachments WHERE id=? AND state='deleting' AND message_id IS NULL").bind(row.id).run();
  }
}
export async function uploadAttachment(request: Request, env: CenterEnv, db: D1Database, rawID: string) {
  const id = uuid(rawID, "附件编号"); const hash = await tokenHash(request); const bucket = requireBucket(env);
  const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!supported.includes(type)) fail(415, "仅支持 PNG、JPEG、WebP 图片");
  const name = fileName(request);
  let row = await db.prepare("SELECT * FROM attachments WHERE id=?").bind(id).first<AttachmentRow>();
  if (!row) await limitRequest(request, db, "attachment", 30);
  if (row && (row.token_hash !== hash || row.state === "deleting")) fail(409, "附件编号不可用");
  const data = await bytes(request, maxBytes);
  if (!imageMatches(type, data)) fail(400, "图片文件格式无效");
  const sum = await digest(data);
  if (row && (row.size !== data.length || row.digest !== sum || row.content_type !== type || row.name !== name)) {
    fail(409, "附件内容与之前的请求不一致");
  }
  if (row?.state === "ready") return publicAttachment(row);
  if (!row) {
    await drainDeletionQueue(db, bucket);
    await cleanPending(db, bucket);
    const globalLimit = storageLimit(env);
    await db.prepare(`INSERT OR IGNORE INTO attachments(id,token_hash,name,content_type,size,digest,state,created_at)
      SELECT ?,?,?,?,?,?,'uploading',? WHERE
      (SELECT COUNT(*) FROM attachments WHERE token_hash=?)<3 AND
      COALESCE((SELECT SUM(size) FROM attachments WHERE token_hash=?),0)+?<=? AND
      COALESCE((SELECT SUM(size) FROM attachments),0)+COALESCE((SELECT SUM(size) FROM object_deletions),0)+?<=?`)
      .bind(id,hash,name,type,data.length,sum,now(),hash,hash,data.length,maxBytes,data.length,globalLimit).run();
    row = await db.prepare("SELECT * FROM attachments WHERE id=?").bind(id).first<AttachmentRow>();
    if (!row) {
      const usage = await db.prepare("SELECT COUNT(*) AS count,COALESCE(SUM(size),0) AS total FROM attachments WHERE token_hash=?")
        .bind(hash).first<{count: number; total: number}>();
      if (!usage || usage.count >= 3 || usage.total + data.length > maxBytes) fail(413, "每条反馈最多 3 张图片，合计不超过 10 MB");
      fail(503, "附件存储空间已满，请稍后重试");
    }
    if (row.token_hash !== hash || row.digest !== sum || row.name !== name || row.content_type !== type || row.state === "deleting") {
      fail(409, "附件编号不可用");
    }
    if (row.state === "ready") return publicAttachment(row);
  }
  await bucket.put(`attachments/${id}`, data, { httpMetadata: { contentType: type } });
  await db.prepare("UPDATE attachments SET state='ready' WHERE id=? AND token_hash=? AND state='uploading'").bind(id,hash).run();
  row = await db.prepare("SELECT * FROM attachments WHERE id=? AND token_hash=?").bind(id,hash).first<AttachmentRow>();
  if (!row || row.state !== "ready") {
    await bucket.delete(`attachments/${id}`);
    fail(409, "附件已被移除，请重新选择");
  }
  return publicAttachment(row);
}
export async function downloadAttachment(request: Request, env: CenterEnv, db: D1Database, rawID: string, admin: boolean): Promise<Response> {
  const id = uuid(rawID, "附件编号");
  const hash = admin ? null : await tokenHash(request);
  const row = await db.prepare("SELECT * FROM attachments WHERE id=? AND state='ready'").bind(id).first<AttachmentRow>();
  if (!row || (!admin && row.token_hash !== hash)) fail(404, "附件不存在");
  const object = await requireBucket(env).get(`attachments/${id}`);
  if (!object) fail(404, "附件不存在");
  const encoded = encodeURIComponent(row.name).replace(/['()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return new Response(object.body, { headers: {
    "content-type": row.content_type, "content-length": String(row.size),
    "content-disposition": `inline; filename*=UTF-8''${encoded}`, "cache-control": "private, no-store",
    "x-content-type-options": "nosniff", "content-security-policy": "sandbox", "referrer-policy": "no-referrer",
  } });
}
export async function removePendingAttachment(request: Request, env: CenterEnv, db: D1Database, rawID: string): Promise<void> {
  const id = uuid(rawID, "附件编号"); const hash = await tokenHash(request);
  const row = await db.prepare("UPDATE attachments SET state='deleting' WHERE id=? AND token_hash=? AND message_id IS NULL AND state IN ('ready','deleting') RETURNING id")
    .bind(id,hash).first();
  if (!row) fail(404, "附件不存在或已提交");
  await requireBucket(env).delete(`attachments/${id}`);
  await db.prepare("DELETE FROM attachments WHERE id=? AND token_hash=? AND state='deleting' AND message_id IS NULL").bind(id,hash).run();
}
