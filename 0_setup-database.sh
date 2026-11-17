#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo "Run this as your normal Linux user, without sudo." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
CONFIG_DIR="${HOME}/.config/organizer"
CONFIG_FILE="${CONFIG_DIR}/client.cnf"

for command in mariadb sudo openssl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    echo "Run the dependency installer first." >&2
    exit 1
  fi
done

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

if [[ -e "$CONFIG_FILE" ]]; then
  echo "Config already exists: $CONFIG_FILE" >&2
  echo "Refusing to replace it. Back it up or remove it before rerunning." >&2
  exit 1
fi

DB_PASSWORD="$(openssl rand -hex 32)"
DB_USER="organizer_app"
DB_NAME="organizer"

echo "Creating database and local application user..."
sudo mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
  IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER '${DB_USER}'@'localhost'
  IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.*
  TO '${DB_USER}'@'localhost';
SQL

echo "Applying schema..."
sudo mariadb "$DB_NAME" < "$SCHEMA_FILE"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
umask 077

cat > "$CONFIG_FILE" <<EOF
[client]
user=${DB_USER}
password=${DB_PASSWORD}
host=localhost
database=${DB_NAME}
EOF

chmod 600 "$CONFIG_FILE"

echo
echo "Database setup complete."
echo "Database:       ${DB_NAME}"
echo "Application DB user: ${DB_USER}"
echo "Client config:  ${CONFIG_FILE}"
echo
echo "Test the connection with:"
echo "mariadb --defaults-extra-file='${CONFIG_FILE}' -e 'SHOW TABLES;'"

