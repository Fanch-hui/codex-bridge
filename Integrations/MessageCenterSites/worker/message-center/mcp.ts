import { ApiError, bodyJson, digest, fail, json, requireAdmin, requireDb, valueText } from "./common";
import type { CenterEnv } from "./common";
import { createNotice, listAdminNotices, updateNotice } from "./notices";
import { addMessage, changeStatus, deleteFeedback, getFeedback, listFeedback } from "./feedback";

const objectSchema = (properties: Record<string, unknown>, required: string[] = []) => ({
  type: "object", properties, required, additionalProperties: false,
});
const id = { type: "string", description: "反馈或通知的编号" };
const string = { type: "string" };
const noticeProperties = {
  title: { type: "string", description: "通知标题" }, body: { type: "string", description: "通知正文" },
  priority: { type: "string", enum: ["normal", "important"] },
  action: { type: "object", properties: { kind: { type: "string", enum: ["update", "url"] }, label: string, url: string }, required: ["kind", "label"] },
  platforms: { type: "array", items: { type: "string", enum: ["macos", "windows", "linux"] }, description: "限定平台，省略或空数组表示全部平台" },
  minVersion: { type: "string", description: "最低应用版本，例如 3.0.1" },
  maxVersion: { type: "string", description: "最高应用版本" },
  expiresAt: { type: "string", description: "到期时间，ISO 8601" },
  requestId: { type: "string", description: "本次发布唯一 UUID，重试时保持不变" },
};
const tools = [
  { name: "publish_notice", description: "发布一条新通知给指定平台和版本的 Codex Bridge 用户；默认发布给全部用户，调用后立即可见。", inputSchema: objectSchema(noticeProperties, ["title", "body"]) },
  { name: "list_notices", description: "查看管理员发布和保存的通知。", inputSchema: objectSchema({}) },
  { name: "withdraw_notice", description: "撤回一条已发布通知；用户同步后不再显示。", inputSchema: objectSchema({ id }, ["id"]) },
  { name: "list_feedback", description: "查看私密用户反馈列表，按最近更新时间排序。", inputSchema: objectSchema({ cursor: string }) },
  { name: "get_feedback", description: "读取一条私密反馈的完整对话。", inputSchema: objectSchema({ id }, ["id"]) },
  { name: "reply_feedback", description: "向指定用户发送反馈回复，调用后用户可在 App 中查看。", inputSchema: objectSchema({ id, body: string, requestId: string }, ["id", "body"]) },
  { name: "delete_feedback", description: "永久删除指定反馈及其全部对话、截图；仅在用户明确要求删除时调用。", inputSchema: objectSchema({ id }, ["id"]) },
  { name: "set_feedback_status", description: "修改反馈处理状态。", inputSchema: objectSchema({ id, status: { type: "string", enum: ["received", "processing", "resolved"] } }, ["id", "status"]) },
];
async function derivedRequestId(method: string, rpcId: unknown, args: Record<string, unknown>): Promise<string> {
  const hash = await digest(JSON.stringify({ method, rpcId, args }));
  return `${hash.slice(0,8)}-${hash.slice(8,12)}-${hash.slice(12,16)}-${hash.slice(16,20)}-${hash.slice(20,32)}`;
}
async function invoke(name: string, args: Record<string, unknown>, db: D1Database, rpcId: unknown, env: CenterEnv) {
  switch (name) {
    case "publish_notice": return { notice: await createNotice(db, {
      ...args, requestId: args.requestId ?? await derivedRequestId(name, rpcId, args), status: "published",
    }) };
    case "list_notices": return { notices: await listAdminNotices(db) };
    case "withdraw_notice": return { notice: await updateNotice(db, valueText(args.id, "通知编号", 36), { status: "withdrawn" }) };
    case "list_feedback": return listFeedback(db, args.cursor === undefined ? null : valueText(args.cursor, "分页", 6));
    case "get_feedback": return { feedback: await getFeedback(db, valueText(args.id, "反馈编号", 36)) };
    case "reply_feedback": return { feedback: await addMessage(db, valueText(args.id, "反馈编号", 36), {
      body: args.body, requestId: args.requestId ?? await derivedRequestId(name, rpcId, args),
    }, "admin") };
    case "delete_feedback": await deleteFeedback(env, db, valueText(args.id, "反馈编号", 36)); return { deleted: true };
    case "set_feedback_status": return { feedback: await changeStatus(db, valueText(args.id, "反馈编号", 36), args.status) };
    default: fail(404, "工具不存在");
  }
}
export async function mcpRoute(request: Request, env: CenterEnv): Promise<Response> {
  if (request.method !== "POST") fail(405, "仅支持 POST 请求");
  const origin = request.headers.get("origin");
  if (origin && origin !== new URL(request.url).origin) fail(403, "请求来源无效");
  const rpc = await bodyJson(request);
  if (rpc.jsonrpc !== "2.0" || typeof rpc.method !== "string") fail(400, "请求无效");
  const rpcId = rpc.id ?? null;
  if (rpc.method.startsWith("notifications/")) return new Response(null, { status: 202 });
  const reply = (result: unknown) => json({ jsonrpc: "2.0", id: rpcId, result });
  if (rpc.method === "server/discover") return reply({ supportedVersions: ["2026-07-28"], capabilities: { tools: {} } });
  if (rpc.method === "initialize") return reply({ protocolVersion: "2026-07-28", capabilities: { tools: {} }, serverInfo: { name: "codex-bridge-message-center", version: "1.0.0" } });
  if (rpc.method === "tools/list") return reply({ tools });
  if (rpc.method !== "tools/call") return json({ jsonrpc: "2.0", id: rpcId, error: { code: -32601, message: "Method not found" } });
  requireAdmin(request, env);
  const params = rpc.params as Record<string, unknown> | undefined;
  if (!params || typeof params.name !== "string") fail(400, "工具参数无效");
  const args = params.arguments ?? {};
  if (!args || typeof args !== "object" || Array.isArray(args)) fail(400, "工具参数无效");
  try {
    const result = await invoke(params.name, args as Record<string, unknown>, requireDb(env), rpcId, env);
    return reply({ content: [{ type: "text", text: JSON.stringify(result) }] });
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    return reply({ isError: true, content: [{ type: "text", text: error.message }] });
  }
}
