ALTER TABLE ytel_followup_log CHANGE description templateData TEXT;
ALTER TABLE ytel_followup_log ADD COLUMN `leadData` TEXT CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL AFTER `templateData`;
