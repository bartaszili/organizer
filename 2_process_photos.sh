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

sql_utf8_hex() {
    local hex
    hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
    printf 'CONVERT(0x%s USING utf8mb4)' "$hex"
}

exif_value() {
    local tag="$1"

    jq -r --arg tag "$tag" '
        [
            .[0] | to_entries[]
            | select(.key | test("^EXIF:" + $tag + "[0-9]*$"))
            | .value
            | strings
            | select(length > 0)
        ][0] // empty
    ' "$json_file"
}

# Store the EXIF wall-clock reading as a DATETIME, without timezone conversion.
exif_datetime_sql() {
    local tag="$1"
    local raw

    raw="$(exif_value "$tag")"

    if [[ "$raw" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
        printf "STR_TO_DATE('%s:%s:%s %s:%s:%s','%%Y:%%m:%%d %%H:%%i:%%s')" \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
            "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    else
        printf 'NULL'
    fi
}

# Recover records left in processing by an interrupted earlier run.
mariadb --defaults-extra-file="$DB_CONFIG" \
    -e "UPDATE photos SET status='new' WHERE status='processing';"

# Failed IDs remain new for a future run, but are excluded from this run
# to avoid repeatedly selecting the same files.
failed_ids=""
total_selected=0
total_processed=0
total_failed=0
total_missing_exif=0

while true; do
    exclude_clause=""
    if [[ -n "$failed_ids" ]]; then
        exclude_clause=" AND id NOT IN (${failed_ids})"
    fi

    rows="$(
        mariadb --defaults-extra-file="$DB_CONFIG" \
            --batch --raw --skip-column-names \
            -e "SELECT id, REPLACE(TO_BASE64(filePath), CHAR(10), '')
                FROM photos
                WHERE status='new'${exclude_clause}
                ORDER BY id
                LIMIT ${BATCH_SIZE};"
    )"

    if [[ -z "$rows" ]]; then
        break
    fi

    ids=""
    batch_selected=0

    while IFS=$'\t' read -r id _encoded_path; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        ids+="${ids:+,}${id}"
        batch_selected=$((batch_selected + 1))
    done <<< "$rows"

    if [[ -z "$ids" ]]; then
        echo "No valid photo records were selected; stopping." >&2
        exit 1
    fi

    total_selected=$((total_selected + batch_selected))

    mariadb --defaults-extra-file="$DB_CONFIG" \
        -e "UPDATE photos
            SET status='processing'
            WHERE status='new' AND id IN (${ids});"

    updates="$tmp_dir/updates.sql"
    printf 'START TRANSACTION;\n' > "$updates"

    batch_failed=0

    while IFS=$'\t' read -r id encoded_path; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue

        path="$(printf '%s' "$encoded_path" | base64 --decode)"

        if [[ ! -f "$path" || ! -r "$path" ]]; then
            printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), NULLIF(notes,''), 'File missing or unreadable during processing') WHERE id=%s;\n" \
                "$id" >> "$updates"
            echo "Missing or unreadable file for photo id $id" >&2
            failed_ids+="${failed_ids:+,}${id}"
            batch_failed=$((batch_failed + 1))
            continue
        fi

        if ! checksum_output="$(md5sum -- "$path" 2>/dev/null)"; then
            printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), NULLIF(notes,''), 'MD5 calculation failed') WHERE id=%s;\n" \
                "$id" >> "$updates"
            echo "MD5 failed for photo id $id" >&2
            failed_ids+="${failed_ids:+,}${id}"
            batch_failed=$((batch_failed + 1))
            continue
        fi

        md5="${checksum_output%% *}"

        if [[ ! "$md5" =~ ^[0-9a-fA-F]{32}$ ]]; then
            printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), NULLIF(notes,''), 'Invalid MD5 result') WHERE id=%s;\n" \
                "$id" >> "$updates"
            echo "Invalid MD5 result for photo id $id" >&2
            failed_ids+="${failed_ids:+,}${id}"
            batch_failed=$((batch_failed + 1))
            continue
        fi

        json_file="$tmp_dir/exif-${id}.json"

        if ! exiftool -json -G0 -a -s -- "$path" \
            > "$json_file" 2>"$tmp_dir/exif-${id}.err"; then
            printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), NULLIF(notes,''), 'ExifTool metadata extraction failed') WHERE id=%s;\n" \
                "$id" >> "$updates"
            echo "ExifTool failed for photo id $id" >&2
            failed_ids+="${failed_ids:+,}${id}"
            batch_failed=$((batch_failed + 1))
            continue
        fi

        if ! jq -e 'type == "array" and length > 0' "$json_file" >/dev/null; then
            printf "UPDATE photos SET status='new', notes=CONCAT_WS(CHAR(10), NULLIF(notes,''), 'ExifTool returned invalid JSON') WHERE id=%s;\n" \
                "$id" >> "$updates"
            echo "ExifTool returned invalid JSON for photo id $id" >&2
            failed_ids+="${failed_ids:+,}${id}"
            batch_failed=$((batch_failed + 1))
            continue
        fi

        json="$(<"$json_file")"
        json_sql="$(sql_utf8_hex "$json")"

        # -G0 uses the broad EXIF group name. -G1 uses IFD names such as
        # IFD0 and ExifIFD, which caused the old check to miss EXIF metadata.
        has_exif=false
        if jq -e '.[0] | keys | any(startswith("EXIF:"))' "$json_file" >/dev/null; then
            has_exif=true
        fi

        # ExifTool names the EXIF date tags ModifyDate, CreateDate,
        # and DateTimeOriginal. These are stored as local clock readings.
        exif_datetime_expr="$(exif_datetime_sql ModifyDate)"
        exif_digitized_expr="$(exif_datetime_sql CreateDate)"
        exif_original_expr="$(exif_datetime_sql DateTimeOriginal)"

        if [[ "$has_exif" == true ]]; then
            cat >> "$updates" <<SQL
UPDATE photos
SET md5='${md5}',
    exifDateTime=${exif_datetime_expr},
    exifDigitized=${exif_digitized_expr},
    exifOriginal=${exif_original_expr},
    metaData=${json_sql},
    review_reason=CASE
        WHEN review_reason IS NULL THEN NULL
        WHEN FIND_IN_SET('missing_exif_metadata', REPLACE(review_reason, ' ', ''))=0
        THEN review_reason
        ELSE NULLIF(
            TRIM(BOTH ',' FROM REPLACE(
                CONCAT(',', REPLACE(review_reason, ' ', ''), ','),
                ',missing_exif_metadata,',
                ','
            )),
            ''
        )
    END,
    status='ready'
WHERE id=${id} AND status='processing';
SQL
        else
            cat >> "$updates" <<SQL
UPDATE photos
SET md5='${md5}',
    exifDateTime=${exif_datetime_expr},
    exifDigitized=${exif_digitized_expr},
    exifOriginal=${exif_original_expr},
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
            total_missing_exif=$((total_missing_exif + 1))
        fi

        total_processed=$((total_processed + 1))
    done <<< "$rows"

    printf 'COMMIT;\n' >> "$updates"
    mariadb --defaults-extra-file="$DB_CONFIG" < "$updates"

    total_failed=$((total_failed + batch_failed))

    echo "Batch complete: selected $batch_selected, failed $batch_failed."
done

echo "Processing run finished."
echo "Selected: $total_selected"
echo "Processed and marked ready: $total_processed"
echo "Without EXIF metadata: $total_missing_exif"
echo "Failed and left as new for a later retry: $total_failed"
