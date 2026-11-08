import { index, integer, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

export const notices = sqliteTable("notices", {
  id: text("id").primaryKey(),
  requestHash: text("request_hash").notNull(),
  title: text("title").notNull(),
  body: text("body").notNull(),
  priority: text("priority").notNull(),
  status: text("status").notNull(),
  action: text("action"),
  platforms: text("platforms").notNull(),
  minVersion: text("min_version"),
  maxVersion: text("max_version"),
  revision: integer("revision").notNull(),
  publishedAt: text("published_at"),
  updatedAt: text("updated_at").notNull(),
  expiresAt: text("expires_at"),
}, (table) => [index("notices_public_idx").on(table.status, table.publishedAt)]);

export const feedback = sqliteTable("feedback", {
  id: text("id").primaryKey(),
  tokenHash: text("token_hash").notNull(),
  requestId: text("request_id").notNull(),
  requestHash: text("request_hash").notNull(),
  category: text("category").notNull(),
  status: text("status").notNull(),
  appVersion: text("app_version").notNull(),
  platform: text("platform").notNull(),
  createdAt: text("created_at").notNull(),
  updatedAt: text("updated_at").notNull(),
}, (table) => [
  uniqueIndex("feedback_token_unique").on(table.tokenHash),
  index("feedback_updated_idx").on(table.updatedAt, table.id),
]);

export const messages = sqliteTable("messages", {
  sequence: integer("sequence").primaryKey({ autoIncrement: true }),
  id: text("id").notNull().unique(),
  feedbackId: text("feedback_id").notNull().references(() => feedback.id),
  requestId: text("request_id").notNull(),
  requestHash: text("request_hash").notNull(),
  author: text("author").notNull(),
  body: text("body").notNull(),
  createdAt: text("created_at").notNull(),
}, (table) => [
  uniqueIndex("messages_request_unique").on(table.feedbackId, table.requestId),
  index("messages_feedback_idx").on(table.feedbackId, table.sequence),
]);

export const attachments = sqliteTable("attachments", {
  id: text("id").primaryKey(),
  tokenHash: text("token_hash").notNull(),
  feedbackId: text("feedback_id").references(() => feedback.id),
  messageId: text("message_id").references(() => messages.id),
  name: text("name").notNull(),
  contentType: text("content_type").notNull(),
  size: integer("size").notNull(),
  digest: text("digest").notNull(),
  state: text("state").notNull(),
  createdAt: text("created_at").notNull(),
}, (table) => [index("attachments_token_idx").on(table.tokenHash)]);

export const rateLimits = sqliteTable("rate_limits", {
  bucket: text("bucket").primaryKey(),
  count: integer("count").notNull(),
  expiresAt: integer("expires_at").notNull(),
}, (table) => [index("rate_limits_expiry_idx").on(table.expiresAt)]);

export const objectDeletions = sqliteTable("object_deletions", {
  id: text("id").primaryKey(),
  size: integer("size").notNull(),
  createdAt: text("created_at").notNull(),
});
