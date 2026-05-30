ALTER TABLE `comments` ADD `crisis_flagged` integer DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE `posts` ADD `crisis_flagged` integer DEFAULT false NOT NULL;