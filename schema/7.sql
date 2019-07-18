ALTER TABLE ytel_followup_templates CHANGE COLUMN `bodyUrl` `bodyUrl` TEXT CHARACTER SET utf8 COLLATE utf8_general_ci NULL  COMMENT '' AFTER `body`;
ALTER TABLE ytel_followup_templates CHANGE COLUMN `callbackUrl` `callbackUrl` TEXT CHARACTER SET utf8 COLLATE utf8_general_ci NULL  COMMENT '' AFTER `bodyUrl`;
