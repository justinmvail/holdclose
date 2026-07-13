CREATE TABLE `feedback` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`created_at` integer NOT NULL,
	`category` text DEFAULT 'bug' NOT NULL,
	`message` text NOT NULL,
	`route` text DEFAULT '' NOT NULL,
	`tester_name` text DEFAULT '' NOT NULL,
	`platform` text DEFAULT '' NOT NULL,
	`os_version` text DEFAULT '' NOT NULL,
	`demo_mode` integer DEFAULT false NOT NULL,
	`app_version` text DEFAULT '' NOT NULL,
	`build_stamp` text DEFAULT '' NOT NULL,
	`logs` text DEFAULT '' NOT NULL,
	`screenshot_key` text
);
--> statement-breakpoint
CREATE INDEX `feedback_created_idx` ON `feedback` (`created_at`);