import { bodyJson, fail, json, requireAdmin, requireDb, requireOrigin } from "./common";
import type { CenterEnv } from "./common";
import { createNotice, listAdminNotices, updateNotice } from "./notices";
import { addMessage, changeStatus, deleteFeedback, downloadAttachment, getFeedback, listFeedback } from "./feedback";

export async function adminRoute(request: Request, env: CenterEnv, path: string): Promise<Response> {
  requireAdmin(request, env);
  if (path === "/api/admin/session" && request.method === "GET") return json({ authenticated: true });
  const db = requireDb(env);
  if (["POST", "PATCH", "PUT", "DELETE"].includes(request.method)) requireOrigin(request);
  if (path === "/api/admin/notices") {
    if (request.method === "GET") return json({ notices: await listAdminNotices(db) });
    if (request.method === "POST") return json({ notice: await createNotice(db, await bodyJson(request)) }, 201);
  }
  const notice = /^\/api\/admin\/notices\/([^/]+)$/.exec(path);
  if (notice && request.method === "PATCH") return json({ notice: await updateNotice(db, notice[1], await bodyJson(request)) });
  if (path === "/api/admin/feedback" && request.method === "GET") {
    return json(await listFeedback(db, new URL(request.url).searchParams.get("cursor")));
  }
  const message = /^\/api\/admin\/feedback\/([^/]+)\/messages$/.exec(path);
  if (message && request.method === "POST") return json({ feedback: await addMessage(db, message[1], await bodyJson(request), "admin") });
  const feedback = /^\/api\/admin\/feedback\/([^/]+)$/.exec(path);
  if (feedback && request.method === "GET") return json({ feedback: await getFeedback(db, feedback[1]) });
  if (feedback && request.method === "PATCH") return json({ feedback: await changeStatus(db, feedback[1], (await bodyJson(request)).status) });
  if (feedback && request.method === "DELETE") { await deleteFeedback(env, db, feedback[1]); return new Response(null, { status: 204 }); }
  const attachment = /^\/api\/admin\/attachments\/([^/]+)$/.exec(path);
  if (attachment && request.method === "GET") return downloadAttachment(request, env, db, attachment[1], true);
  fail(404, "接口不存在");
}
