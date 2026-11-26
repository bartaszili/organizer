USE organizer;

START TRANSACTION;

-- Plan names only for non-duplicate ready records with a capture timestamp.
-- Numbering is assigned within each timestamp second, in photo-id order.
CREATE TEMPORARY TABLE photo_plan (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    capture_time DATETIME NOT NULL,
    photos_in_second INT NOT NULL,
    sequence_number INT NOT NULL
) ENGINE=InnoDB;

INSERT INTO photo_plan (id, capture_time, photos_in_second, sequence_number)
SELECT id, capture_time, photos_in_second, sequence_number
FROM (
    SELECT
        id,
        capture_time,
        COUNT(*) OVER (PARTITION BY capture_time) AS photos_in_second,
        ROW_NUMBER() OVER (PARTITION BY capture_time ORDER BY id) AS sequence_number
    FROM (
        SELECT
            id,
            COALESCE(exifOriginal, exifDigitized, exifDateTime) AS capture_time
        FROM photos
        WHERE status = 'ready'
          AND isDuplicate = 0
          AND COALESCE(exifOriginal, exifDigitized, exifDateTime) IS NOT NULL
    ) AS dated_photos
) AS numbered_photos;

-- Prepare mains. newFilePath is the YYYY/YYYY-MM/ destination folder.
UPDATE photos AS p
JOIN photo_plan AS plan ON plan.id = p.id
SET
    p.status = 'prepared',
    p.isMain = 1,
    p.newFilePath = CONCAT(
        DATE_FORMAT(plan.capture_time, '%Y'),
        '/',
        DATE_FORMAT(plan.capture_time, '%Y-%m'),
        '/'
    ),
    p.newFileName = CONCAT(
        DATE_FORMAT(plan.capture_time, '%Y%m%d_%H%i%s'),
        CASE
            WHEN plan.photos_in_second > 1
            THEN CONCAT('_', LPAD(plan.sequence_number, 3, '0'))
            ELSE ''
        END,
        CASE
            WHEN LOCATE('.', p.fileName) > 0
            THEN CONCAT('.', SUBSTRING_INDEX(p.fileName, '.', -1))
            ELSE ''
        END
    ),
    p.newFileCounter = CASE
        WHEN plan.photos_in_second > 1 THEN plan.sequence_number
        ELSE NULL
    END,
    p.newFileDuplicateCounter = NULL
WHERE p.status = 'ready';

-- Reject records already marked as duplicates.
UPDATE photos
SET
    status = 'rejected',
    isMain = 0,
    isDuplicate = 1
WHERE status = 'ready'
  AND isDuplicate = 1;

-- Records without a capture timestamp cannot be named safely; leave them
-- available for review rather than assigning a fabricated date.
UPDATE photos
SET status = 'review'
WHERE status = 'ready'
  AND isDuplicate = 0
  AND COALESCE(exifOriginal, exifDigitized, exifDateTime) IS NULL;

DROP TEMPORARY TABLE photo_plan;

COMMIT;
