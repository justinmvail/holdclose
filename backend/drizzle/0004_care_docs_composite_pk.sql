PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_care_docs` (
	`id` text NOT NULL,
	`circle_id` text NOT NULL,
	`collection` text NOT NULL,
	`payload` text NOT NULL,
	`client_updated_at` integer NOT NULL,
	`rev` integer NOT NULL,
	`deleted` integer DEFAULT false NOT NULL,
	PRIMARY KEY(`id`, `circle_id`),
	FOREIGN KEY (`circle_id`) REFERENCES `circles`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `__new_care_docs`("id", "circle_id", "collection", "payload", "client_updated_at", "rev", "deleted") SELECT "id", "circle_id", "collection", "payload", "client_updated_at", "rev", "deleted" FROM `care_docs`;--> statement-breakpoint
DROP TABLE `care_docs`;--> statement-breakpoint
ALTER TABLE `__new_care_docs` RENAME TO `care_docs`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `care_docs_circle_rev_idx` ON `care_docs` (`circle_id`,`rev`);--> statement-breakpoint
CREATE INDEX `care_docs_circle_collection_idx` ON `care_docs` (`circle_id`,`collection`);