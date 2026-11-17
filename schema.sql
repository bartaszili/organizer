USE organizer;

CREATE TABLE IF NOT EXISTS statuses (
  status VARCHAR(100) NOT NULL,
  description VARCHAR(255) DEFAULT NULL,
  sortOrder INT DEFAULT NULL,
  isActive TINYINT(1) DEFAULT 1,
  PRIMARY KEY (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS review_reasons (
  reason VARCHAR(100) NOT NULL,
  description VARCHAR(255) DEFAULT NULL,  
  isActive TINYINT(1) DEFAULT 1,
  PRIMARY KEY (reason)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS photos (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  status VARCHAR(100) NOT NULL,
  review_reason TEXT DEFAULT NULL,
  md5 CHAR(32) DEFAULT NULL,
  fileName VARCHAR(255) NOT NULL,
  filePath VARCHAR(400) NOT NULL,
  fileSize BIGINT UNSIGNED DEFAULT NULL,
  fileCreated TIMESTAMP NULL DEFAULT NULL,
  fileUpdated TIMESTAMP NULL DEFAULT NULL,
  exifDateTime TIMESTAMP NULL DEFAULT NULL,
  exifDigitized TIMESTAMP NULL DEFAULT NULL,
  exifOriginal TIMESTAMP NULL DEFAULT NULL,
  metaData LONGTEXT DEFAULT NULL,
  newFileName VARCHAR(100) DEFAULT NULL,
  newFilePath VARCHAR(100) DEFAULT NULL,
  newFileCounter INT DEFAULT NULL,
  newFileDuplicateCounter INT DEFAULT NULL,
  notes TEXT DEFAULT NULL,
  isMain TINYINT(1) NOT NULL DEFAULT 0,
  isDuplicate TINYINT(1) NOT NULL DEFAULT 0,
  isDeleted TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY photos_fileName_IDX (fileName),
  KEY photos_md5_IDX (md5),
  KEY photos_status_IDX (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS videos (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  status VARCHAR(100) NOT NULL,
  review_reason TEXT DEFAULT NULL,
  md5 CHAR(32) DEFAULT NULL,
  fileName VARCHAR(255) NOT NULL,
  filePath VARCHAR(400) NOT NULL,
  fileSize BIGINT UNSIGNED DEFAULT NULL,
  fileCreated TIMESTAMP NULL DEFAULT NULL,
  fileUpdated TIMESTAMP NULL DEFAULT NULL,
  metaData LONGTEXT DEFAULT NULL,
  newFileName VARCHAR(100) DEFAULT NULL,
  newFilePath VARCHAR(100) DEFAULT NULL,
  newFileCounter INT DEFAULT NULL,
  newFileDuplicateCounter INT DEFAULT NULL,
  notes TEXT DEFAULT NULL,
  isMain TINYINT(1) NOT NULL DEFAULT 0,
  isDuplicate TINYINT(1) NOT NULL DEFAULT 0,
  isDeleted TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY videos_fileName_IDX (fileName),
  KEY videos_md5_IDX (md5),
  KEY videos_status_IDX (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

INSERT IGNORE INTO statuses (status, description, sortOrder) VALUES
  ('new', 'Discovered; not yet processed', 1),
  ('processing', 'Checksum calculation in progress', 2),
  ('ready', 'Checksum available; ready for analysis', 3),
  ('prepared', 'Analysis and destination plan recorded', 4),
  ('review', 'Needs manual review', 5),
  ('completed', 'File operation completed', 6),
  ('rejected', 'Excluded from processing', 7);

INSERT IGNORE INTO review_reasons (reason, description) VALUES
  ('conflicting_capture_times',	'Available timestamps disagree'),
  ('invalid_capture_time',	'Capture timestamp is invalid or implausible'),
  ('metadata_conflict',	'Conflicting or inconsistent metadata'),
  ('missing_capture_time',	'Missing or invalid capture time'),
  ('missing_exif_metadata',	'No usable EXIF metadata was found'),
  ('possible_visual_duplicate',	'Possible visual duplicate; manual comparison needed'),
  ('same_name_different_time',	'Same filename, different timestamp'),
  ('sequence_conflict',	'Nearby files suggest a timestamp conflict'),
  ('unreliable_file_time',	'Filesystem time is missing or cannot be trusted');

