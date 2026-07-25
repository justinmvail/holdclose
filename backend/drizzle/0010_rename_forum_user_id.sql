ALTER TABLE `profiles` RENAME COLUMN `careblazers_user_id` TO `holdclose_user_id`;--> statement-breakpoint
DROP INDEX IF EXISTS `profiles_careblazers_user_id_unique`;--> statement-breakpoint
CREATE UNIQUE INDEX `profiles_holdclose_user_id_unique` ON `profiles` (`holdclose_user_id`);