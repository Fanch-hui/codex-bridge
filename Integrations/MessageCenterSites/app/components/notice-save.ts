import { request } from "./api";
import type { Notice, NoticeAction, NoticeStatus, Platform } from "./types";

export type NoticePayload = {
  title: string;
  body: string;
  priority: "normal" | "important";
  status: NoticeStatus;
  platforms: Platform[];
  minVersion: string | null;
  maxVersion: string | null;
  expiresAt: string | null;
  action: NoticeAction | null;
};

function comparable(payload: NoticePayload): NoticePayload {
  return {
    title: payload.title, body: payload.body, priority: payload.priority, status: payload.status,
    platforms: [...payload.platforms].sort(), minVersion: payload.minVersion,
    maxVersion: payload.maxVersion, expiresAt: payload.expiresAt, action: payload.action ?? null,
  };
}

export async function saveNotice(
  existing: Notice | undefined,
  body: NoticePayload,
  pending: { requestId: string; pendingRequest: string },
  remember: (pending: { requestId: string; pendingRequest: string }) => void,
): Promise<Notice> {
  if (existing) {
    return (await request<{ notice: Notice }>(`/api/admin/notices/${encodeURIComponent(existing.id)}`, {
      method: "PATCH", body: JSON.stringify(body),
    })).notice;
  }
  const requestId = pending.requestId || crypto.randomUUID();
  const pendingRequest = pending.pendingRequest || JSON.stringify({ ...body, requestId });
  remember({ requestId, pendingRequest });
  const created = (await request<{ notice: Notice }>("/api/admin/notices", {
    method: "POST", body: pendingRequest,
  })).notice;
  if (JSON.stringify(comparable(created)) === JSON.stringify(comparable(body))) return created;
  return (await request<{ notice: Notice }>(`/api/admin/notices/${encodeURIComponent(created.id)}`, {
    method: "PATCH", body: JSON.stringify(body),
  })).notice;
}
