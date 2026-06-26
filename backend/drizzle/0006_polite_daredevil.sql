CREATE TABLE `llm_usage` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`created_at` integer NOT NULL,
	`model` text NOT NULL,
	`prompt_tokens` integer DEFAULT 0 NOT NULL,
	`completion_tokens` integer DEFAULT 0 NOT NULL,
	`cost_micros` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE INDEX `llm_usage_user_created_idx` ON `llm_usage` (`user_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `llm_usage_created_idx` ON `llm_usage` (`created_at`);