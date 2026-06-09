CREATE TABLE `circle_invites` (
	`token` text PRIMARY KEY NOT NULL,
	`circle_id` text NOT NULL,
	`created_by_profile_id` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL,
	`revoked` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`circle_id`) REFERENCES `circles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`created_by_profile_id`) REFERENCES `profiles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `circle_invites_circle_id_idx` ON `circle_invites` (`circle_id`);--> statement-breakpoint
CREATE TABLE `circle_members` (
	`id` text PRIMARY KEY NOT NULL,
	`circle_id` text NOT NULL,
	`profile_id` text NOT NULL,
	`role` text DEFAULT 'member' NOT NULL,
	`joined_at` integer NOT NULL,
	FOREIGN KEY (`circle_id`) REFERENCES `circles`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`profile_id`) REFERENCES `profiles`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "circle_members_role_enum" CHECK("circle_members"."role" IN ('owner', 'member', 'viewer'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `circle_members_circle_profile_unique` ON `circle_members` (`circle_id`,`profile_id`);--> statement-breakpoint
CREATE INDEX `circle_members_circle_id_idx` ON `circle_members` (`circle_id`);--> statement-breakpoint
CREATE INDEX `circle_members_profile_id_idx` ON `circle_members` (`profile_id`);--> statement-breakpoint
CREATE TABLE `circles` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`owner_profile_id` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`owner_profile_id`) REFERENCES `profiles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `circles_owner_profile_id_idx` ON `circles` (`owner_profile_id`);--> statement-breakpoint
ALTER TABLE `profiles` ADD `username` text;--> statement-breakpoint
CREATE UNIQUE INDEX `profiles_username_unique` ON `profiles` (`username`);