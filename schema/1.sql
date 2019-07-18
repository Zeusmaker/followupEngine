RENAME TABLE ytel_followup_settings TO ytel_settings;
ALTER TABLE ytel_followup_templates ADD COLUMN `includedLists` VARCHAR(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL AFTER `includedStatuses`;
ALTER TABLE ytel_followup_templates ADD COLUMN `description` VARCHAR(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL AFTER `includedLists`;
ALTER TABLE ytel_followup_log ADD COLUMN `request` TEXT CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL AFTER `callCount`;
ALTER TABLE ytel_settings ADD COLUMN `dbSchema` BIGINT(10) NULL DEFAULT 0 AFTER `testPhone`;
