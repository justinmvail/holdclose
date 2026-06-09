CREATE TABLE `care_docs` (
	`id` text PRIMARY KEY NOT NULL,
	`circle_id` text NOT NULL,
	`collection` text NOT NULL,
	`payload` text NOT NULL,
	`client_updated_at` integer NOT NULL,
	`rev` integer NOT NULL,
	`deleted` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`circle_id`) REFERENCES `circles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `care_docs_circle_rev_idx` ON `care_docs` (`circle_id`,`rev`);--> statement-breakpoint
CREATE INDEX `care_docs_circle_collection_idx` ON `care_docs` (`circle_id`,`collection`);--> statement-breakpoint
CREATE TABLE `patients` (
	`id` text PRIMARY KEY NOT NULL,
	`circle_id` text NOT NULL,
	`payload` text NOT NULL,
	`client_updated_at` integer NOT NULL,
	`rev` integer NOT NULL,
	`deleted` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`circle_id`) REFERENCES `circles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `patients_circle_unique` ON `patients` (`circle_id`);--> statement-breakpoint
ALTER TABLE `circles` ADD `sync_counter` integer DEFAULT 0 NOT NULL;