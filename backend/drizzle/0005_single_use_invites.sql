ALTER TABLE `circle_invites` ADD `used_at` integer;--> statement-breakpoint
ALTER TABLE `circle_invites` ADD `used_by_profile_id` text REFERENCES profiles(id);