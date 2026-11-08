CREATE TABLE `attachments` (
	`id` text PRIMARY KEY NOT NULL,
	`token_hash` text NOT NULL,
	`feedback_id` text,
	`message_id` text,
	`name` text NOT NULL,
	`content_type` text NOT NULL,
	`size` integer NOT NULL,
	`digest` text NOT NULL,
	`state` text NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`feedback_id`) REFERENCES `feedback`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `attachments_token_idx` ON `attachments` (`token_hash`);--> statement-breakpoint
CREATE TABLE `feedback` (
	`id` text PRIMARY KEY NOT NULL,
	`token_hash` text NOT NULL,
	`request_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`category` text NOT NULL,
	`status` text NOT NULL,
	`app_version` text NOT NULL,
	`platform` text NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `feedback_token_unique` ON `feedback` (`token_hash`);--> statement-breakpoint
CREATE INDEX `feedback_updated_idx` ON `feedback` (`updated_at`,`id`);--> statement-breakpoint
CREATE TABLE `messages` (
	`sequence` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`id` text NOT NULL,
	`feedback_id` text NOT NULL,
	`request_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`author` text NOT NULL,
	`body` text NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`feedback_id`) REFERENCES `feedback`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `messages_id_unique` ON `messages` (`id`);--> statement-breakpoint
CREATE UNIQUE INDEX `messages_request_unique` ON `messages` (`feedback_id`,`request_id`);--> statement-breakpoint
CREATE INDEX `messages_feedback_idx` ON `messages` (`feedback_id`,`sequence`);--> statement-breakpoint
CREATE TABLE `notices` (
	`id` text PRIMARY KEY NOT NULL,
	`request_hash` text NOT NULL,
	`title` text NOT NULL,
	`body` text NOT NULL,
	`priority` text NOT NULL,
	`status` text NOT NULL,
	`action` text,
	`platforms` text NOT NULL,
	`min_version` text,
	`max_version` text,
	`revision` integer NOT NULL,
	`published_at` text,
	`updated_at` text NOT NULL,
	`expires_at` text
);
--> statement-breakpoint
CREATE INDEX `notices_public_idx` ON `notices` (`status`,`published_at`);--> statement-breakpoint
CREATE TABLE `object_deletions` (
	`id` text PRIMARY KEY NOT NULL,
	`size` integer NOT NULL,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `rate_limits` (
	`bucket` text PRIMARY KEY NOT NULL,
	`count` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `rate_limits_expiry_idx` ON `rate_limits` (`expires_at`);