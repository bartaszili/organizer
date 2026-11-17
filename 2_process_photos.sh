#!/usr/bin/env bash
set -Eeuo pipefail

DB_CONFIG="${HOME}/.config/organizer/client.cnf"
LOCK_DIR="${HOME}/.cache/organizer"
LOCK_FILE="${LOCK_DIR}/process-photos.lock"
BATCH_SIZE="${1:-100}"

if [[ ! "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 [positive-batch-size]" >&2
  exit 2
fi

for command in mariadb md5sum exiftool jq base64 od tr flock; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ ! -r "$DB_CONFIG" ]]; then
  echo "MariaDB config not found or not readable: $DB_CONFIG" >&2
  exit 1
fi

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another photo-processing run is already active." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Convert text to a UTF-8 SQL hex expression, safely handling quotes.
sql_utf8_hex() {
  local hex
  hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
  printf 'CONVERT(0x%s USING utf8mb4)' "$hex"
}

# This is a manual-run workflow. Recover records left processing by an
# interrupted earlier run; they will be selected again if still eligible.
mariadb --defaults-extra-file="$DB_CONFIG" \
  -e "UPDATE photos SET status='new' WHERE status='processing';"

rows="$(
  mariadb --defaults-extra-file="$DB_CONFIG" \
    --batch --raw --skip-column-names \
    -e "SELECT id, REPLACE(TO_BASE64(filePath), CHAR(10), '')
        FROM photos
        WHERE status='new'
        ORDER BY id
        LIMIT ${BATCH_SIZE};"
)"

if [[ -z "$rows" ]]; then
  echo "No new photos to process."
  exit 0
fi

# The selected IDs are database integers, not user-supplied SQL.
ids=""
while IFS=$'\t' read -r id _encoded_path; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  ids+="${ids:+,}${id}"
done <<< "$rows"

if [[ -z "$ids" ]]; then
  echo "No valid photo records were selected." >&2
  exit 1
fi

mariadb --defaults-extra-file="$DB_CONFIG" \
  -e "UPDATE photos SET status='processing'
      WHERE status='new' AND id IN (${ids});"

updates="$tmp_dir/updates.sql"
printf 'START TRANSACTION;\n' > "$updates"

processed=0
failed=0
missing_exif=0

while IFS=$'\t' read -r id encoded_path; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue

  path="$(printf '%s' "$encoded_path" | base64 --decode)"
  if [[ ! -f "$path" || ! -r "$path" ]]; then
    printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), notes, 'File missing or unreadable during processing') WHERE id=%s;\n" \
      "$id" >> "$updates"
    echo "Missing or unreadable file for photo id $id" >&2
    failed=$((failed + 1))
    continue
  fi

  if ! checksum_output="$(md5sum -- "$path" 2>/dev/null)"; then
    printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), notes, 'MD5 calculation failed') WHERE id=%s;\n" \
      "$id" >> "$updates"
    echo "MD5 failed for photo id $id" >&2
    failed=$((failed + 1))
    continue
  fi

  md5="${checksum_output%% *}"
  if [[ ! "$md5" =~ ^[0-9a-fA-F]{32}$ ]]; then
    printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), notes, 'Invalid MD5 result') WHERE id=%s;\n" \
      "$id" >> "$updates"
    echo "Invalid MD5 result for photo id $id" >&2
    failed=$((failed + 1))
    continue
  fi

  json_file="$tmp_dir/exif-${id}.json"
  if ! exiftool -json -G1 -a -s -- "$path" > "$json_file" 2>"$tmp_dir/exif-${id}.err"; then
    printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), notes, 'ExifTool metadata extraction failed') WHERE id=%s;\n" \
      "$id" >> "$updates"
    echo "ExifTool failed for photo id $id" >&2
    failed=$((failed + 1))
    continue
  fi

  if ! jq -e 'type == "array" and length > 0' "$json_file" >/dev/null; then
    printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), notes, 'ExifTool returned invalid JSON') WHERE id=%s;\n" \
      "$id" >> "$updates"
    echo "ExifTool returned invalid JSON for photo id $id" >&2
    failed=$((failed + 1))
    continue
  fi

  json="$(<"$json_file")"
  json_sql="$(sql_utf8_hex "$json")"

  # Check for any EXIF-group tags. Existing review reasons are preserved.
  has_exif=false
  if jq -e '.[0] | keys | any(startswith("EXIF:"))' "$json_file" >/dev/null; then
    has_exif=true
  fi

  if [[ "$has_exif" == true ]]; then
    cat >> "$updates" <<SQL
UPDATE photos
SET md5='${md5}',
    metaData=${json_sql},
    status='ready'
WHERE id=${id} AND status='processing';
SQL
  else
    cat >> "$updates" <<SQL
UPDATE photos
SET md5='${md5}',
    metaData=${json_sql},
    review_reason=CASE
      WHEN review_reason IS NULL OR TRIM(review_reason)=''
        THEN 'missing_exif_metadata'
      WHEN FIND_IN_SET('missing_exif_metadata', REPLACE(review_reason, ' ', ''))=0
        THEN CONCAT(review_reason, ',missing_exif_metadata')
      ELSE review_reason
    END,
    status='ready'
WHERE id=${id} AND status='processing';
SQL
    missing_exif=$((missing_exif + 1))
  fi

  processed=$((processed + 1))
done <<< "$rows"

printf 'COMMIT;\n' >> "$updates"
mariadb --defaults-extra-file="$DB_CONFIG" < "$updates"

echo "Batch finished."
echo "Selected: $((processed + failed))"
echo "Processed and marked ready: $processed"
echo "Without EXIF-group metadata: $missing_exif"
echo "Failed and returned to new: $failed"

