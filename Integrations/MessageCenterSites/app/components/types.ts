export type Platform = "macos" | "windows" | "linux";
export type NoticeStatus = "draft" | "published" | "withdrawn";
export type FeedbackStatus = "received" | "processing" | "resolved";

export type NoticeAction = { kind: "update" | "url"; label: string; url?: string };

export type Notice = {
  id: string;
  title: string;
  body: string;
  priority: "normal" | "important";
  status: NoticeStatus;
  revision: number;
  action: NoticeAction | null;
  platforms: Platform[];
  minVersion: string | null;
  maxVersion: string | null;
  expiresAt: string | null;
  publishedAt: string | null;
  updatedAt: string;
};

export type Attachment = {
  id: string;
  name: string;
  contentType: string;
  size: number;
};

export type FeedbackMessage = {
  id: string;
  author: "user" | "admin";
  body: string;
  createdAt: string;
  attachments?: Attachment[];
};

export type Feedback = {
  id: string;
  category: "bug" | "suggestion" | "other";
  status: FeedbackStatus;
  appVersion: string;
  platform: Platform;
  createdAt: string;
  updatedAt: string;
  messages: FeedbackMessage[];
};

export const platformLabels: Record<Platform, string> = { macos: "macOS", windows: "Windows", linux: "Linux" };

export const statusLabels: Record<FeedbackStatus, string> = {
  received: "已收到",
  processing: "处理中",
  resolved: "已解决",
};

export const categoryLabels: Record<Feedback["category"], string> = {
  bug: "问题反馈",
  suggestion: "功能建议",
  other: "其他",
};

export const noticeStatusLabels: Record<NoticeStatus, string> = {
  draft: "草稿",
  published: "已发布",
  withdrawn: "已撤回",
};

export function displayDate(value: string | null | undefined): string {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
  }).format(date);
}
