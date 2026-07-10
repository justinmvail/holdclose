CREATE TABLE `entitlements` (
	`user_id` text PRIMARY KEY NOT NULL,
	`platform` text NOT NULL,
	`product_id` text NOT NULL,
	`status` text DEFAULT 'none' NOT NULL,
	`expires_at` integer,
	`environment` text DEFAULT 'production' NOT NULL,
	`latest_receipt` text,
	`updated_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT "entitlements_platform_enum" CHECK("entitlements"."platform" IN ('ios', 'android')),
	CONSTRAINT "entitlements_status_enum" CHECK("entitlements"."status" IN ('active', 'expired', 'trial', 'none')),
	CONSTRAINT "entitlements_environment_enum" CHECK("entitlements"."environment" IN ('production', 'sandbox'))
);
