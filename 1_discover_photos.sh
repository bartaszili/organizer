#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="/data/unsorted"
DB_CONFIG="${HOME}/.config/organizer/client.cnf"
EARLIEST_TRUSTED_EPOCH=946684800 # 2000-01-01 00:00:00 UTC

for command in find stat mariadb od tr; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -r "$DB_CONFIG" ]]; then
  echo "MariaDB client config not found or not readable: $DB_CONFIG" >&2
  echo "Run the database setup script first." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

file_list="$tmp_dir/photos.list0"
sql_file="$tmp_dir/insert.sql"

if ! find "$SOURCE_DIR" -type f \( \
  -iname '*.jpg'   -o -iname '*.jpeg' -o -iname '*.jpe'  -o \
  -iname '*.jfif'  -o -iname '*.png'  -o -iname '*.tif'  -o \
  -iname '*.tiff'  -o -iname '*.heic' -o -iname '*.heif' -o \
  -iname '*.webp'  -o -iname '*.gif'  -o -iname '*.bmp'  -o \
  -iname '*.avif'  -o -iname '*.dng'  -o -iname '*.nef'  -o \
  -iname '*.cr2'   -o -iname '*.cr3'  -o -iname '*.arw'  -o \
  -iname '*.raf'   -o -iname '*.orf'  -o -iname '*.rw2'  -o \
  -iname '*.pef'   -o -iname '*.srw' \
\) -print0 > "$file_list"; then
  echo "Warning: find reported errors; continuing with discovered files." >&2
fi

sql_utf8_hex() {
  local hex
  hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
  printf 'CONVERT(0x%s USING utf8mb4)' "$hex"
}

printf 'START TRANSACTION;\n' > "$sql_file"

scanned=0
skipped_stat=0
flagged_old_file_time=0

while IFS= read -r -d '' file; do
  scanned=$((scanned + 1))

  # Birth time is 0 when unavailable; mtime is modification time.
  if ! stat_values="$(stat -c '%W %Y %s' -- "$file" 2>/dev/null)"; then
    echo "Skipping file whose stats could not be read: $file" >&2
    skipped_stat=$((skipped_stat + 1))
    continue
  fi

  read -r birth_epoch modified_epoch size_bytes <<< "$stat_values"

  if [[ ! "$modified_epoch" =~ ^[0-9]+$ || ! "$size_bytes" =~ ^[0-9]+$ ]]; then
    echo "Skipping file with invalid stat values: $file" >&2
    skipped_stat=$((skipped_stat + 1))
    continue
  fi

  if [[ ! "$birth_epoch" =~ ^[0-9]+$ ]]; then
    birth_epoch=0
  fi

  filename="${file##*/}"
  name_sql="$(sql_utf8_hex "$filename")"
  path_sql="$(sql_utf8_hex "$file")"

  if (( birth_epoch > 0 )); then
    created_sql="FROM_UNIXTIME(${birth_epoch})"
  else
    created_sql="NULL"
  fi

  review_sql="NULL"
  if (( modified_epoch < EARLIEST_TRUSTED_EPOCH )) ||
     (( birth_epoch > 0 && birth_epoch < EARLIEST_TRUSTED_EPOCH )); then
    review_sql="'unreliable_file_time'"
    flagged_old_file_time=$((flagged_old_file_time + 1))
  fi

  cat >> "$sql_file" <<SQL
INSERT INTO photos
  (status, review_reason, fileName, filePath, fileSize, fileCreated, fileUpdated)
SELECT
  'new',
  ${review_sql},
  ${name_sql},
  ${path_sql},
  ${size_bytes},
  ${created_sql},
  FROM_UNIXTIME(${modified_epoch})
;
SQL
done < "$file_list"

printf 'COMMIT;\n' >> "$sql_file"

if (( scanned == 0 )); then
  echo "No matching photo files found under $SOURCE_DIR"
  exit 0
fi

mariadb --defaults-extra-file="$DB_CONFIG" < "$sql_file"

echo "Discovery finished."
echo "Matching photo files scanned: $scanned"
echo "Files with a filesystem time before 2000 flagged: $flagged_old_file_time"
echo "Files skipped because stat failed: $skipped_stat"
echo "Existing paths were left unchanged."

