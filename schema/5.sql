ALTER TABLE ytel_settings ADD COLUMN `runInterval` INT(2) NULL DEFAULT 5 AFTER `dbSchema`;
ALTER TABLE ytel_settings ADD COLUMN `runWindow` VARCHAR(10) NULL DEFAULT '8:00-17:00' AFTER `runInterval`;
