import { bodyJson, fail, json, requireDb, serverError } from "./common";
import type { CenterEnv } from "./common";
import { adminRoute } from "./admin";
import { publicNotices } from "./notices";
import { clientFeedback, clientMessage, createFeedback, downloadAttachment, removePendingAttachment, uploadAttachment } from "./feedback";
import { mcpRoute } from "./mcp";

async function route(request: Request, env: CenterEnv): Promise<Response> {
  const url = new URL(request.url); const path = url.pathname;
  if (path === "/mcp") return mcpRoute(request, env);
  if (path.startsWith("/api/admin/")) return adminRoute(request, env, path);
  const db = requireDb(env);
  if (path === "/api/v1/notices" && request.method === "GET") {
    return json(await publicNotices(db, url.searchParams.get("platform"), url.searchParams.get("version"), url.searchParams.get("cursor")));
  }
  if (path === "/api/v1/feedback" && request.method === "POST") {
    return json({ feedback: await createFeedback(request, db, await bodyJson(request)) }, 201);
  }
  const messages = /^\/api\/v1\/feedback\/([^/]+)\/messages$/.exec(path);
  if (messages && request.method === "POST") return json({ feedback: await clientMessage(request, db, messages[1], await bodyJson(request)) });
  const feedback = /^\/api\/v1\/feedback\/([^/]+)$/.exec(path);
  if (feedback && request.method === "GET") return json({ feedback: await clientFeedback(request, db, feedback[1]) });
  const attachment = /^\/api\/v1\/attachments\/([^/]+)$/.exec(path);
  if (attachment && request.method === "PUT") return json({ attachment: await uploadAttachment(request, env, db, attachment[1]) });
  if (attachment && request.method === "GET") return downloadAttachment(request, env, db, attachment[1], false);
  if (attachment && request.method === "DELETE") { await removePendingAttachment(request, env, db, attachment[1]); return new Response(null, { status: 204 }); }
  fail(404, "接口不存在");
}
export async function messageCenterFetch(request: Request, env: CenterEnv): Promise<Response> {
  try { return await route(request, env); } catch (error) { return serverError(error); }
}
