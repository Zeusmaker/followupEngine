SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE `ytel_followup_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `leadID` int(11) DEFAULT '0',
  `templateType` varchar(10) COLLATE utf8_unicode_ci DEFAULT '0',
  `callCount` int(11) DEFAULT '0',
  `templateData` text COLLATE utf8_unicode_ci,
  `leadData` text CHARACTER SET utf8,
  `request` text CHARACTER SET utf8,
  `response` text COLLATE utf8_unicode_ci,
  `timestamp` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `leadID_type_count` (`leadID`,`callCount`,`templateType`) USING BTREE,
  KEY `lead` (`leadID`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;

CREATE TABLE `ytel_followup_templates` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `callCount` int(11) DEFAULT '0',
  `type` varchar(128) DEFAULT NULL,
  `fromPrimary` varchar(128) DEFAULT NULL,
  `fromAlternate` varchar(128) DEFAULT NULL,
  `subject` varchar(128) DEFAULT NULL,
  `body` text,
  `bodyUrl` text,
  `callbackUrl` text,
  `active` tinyint(1) DEFAULT '0',
  `includedStatuses` varchar(500) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `includedLists` varchar(255) DEFAULT NULL,
  `includedCampaigns` varchar(255) DEFAULT NULL,
  `description` varchar(100) DEFAULT NULL,
  `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8;

CREATE TABLE `ytel_settings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accountSID` varchar(128) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `accountToken` varchar(128) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `apiUrl` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `excludedStatuses` varchar(500) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `includedLists` varchar(500) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `testMode` tinyint(1) DEFAULT 0,
  `testEmail` varchar(128) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `testPhone` varchar(128) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `dbSchema` bigint(10) DEFAULT 0,
  `runInterval` int(2) DEFAULT 5,
  `runWindow` varchar(10) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT '8:00-17:00',
  `excludedCarriers` varchar(255) DEFAULT NULL,
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=MyISAM AUTO_INCREMENT=21 DEFAULT CHARSET=utf8;

INSERT INTO `ytel_settings` (`id`, `accountSID`, `accountToken`, `apiUrl`, `excludedStatuses`, `includedLists`, `testMode`, `testEmail`, `testPhone`, `dbSchema`, `runInterval`, `runWindow`) VALUES (1,NULL,NULL,'api.ytel.com',NULL,NULL,0,NULL,NULL,7,5,'8:00-17:00');

SET FOREIGN_KEY_CHECKS = 1;
