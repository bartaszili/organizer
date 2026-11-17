#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script with sudo: sudo $0" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this Linux distribution (/etc/os-release missing)." >&2
  exit 1
fi

# Mint is Ubuntu/Debian based. Require apt rather than guessing on other systems.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer requires apt-get (Linux Mint/Ubuntu/Debian)." >&2
  exit 1
fi

. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  linuxmint:*|*:ubuntu*|*:debian*|ubuntu:*|debian:*)
    ;;
  *)
    echo "This does not appear to be Linux Mint, Ubuntu, or Debian." >&2
    echo "Detected: ID=${ID:-unknown}, ID_LIKE=${ID_LIKE:-unknown}" >&2
    exit 1
    ;;
esac

packages=(
  bash
  coreutils       # md5sum
  findutils       # find
  util-linux      # flock
  mariadb-server
  mariadb-client
  libimage-exiftool-perl
  jq              # convenient for parsing ExifTool JSON output
)

echo "Updating package lists..."
apt-get update

echo "Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

echo "Enabling and starting MariaDB..."
systemctl enable --now mariadb

echo
echo "Installed tool versions:"
bash --version | head -n 1
mariadb --version
exiftool -ver
md5sum --version | head -n 1
jq --version
flock --version | head -n 1

echo
echo "MariaDB service:"
systemctl --no-pager --full status mariadb | sed -n '1,8p'

echo
echo "Dependencies installed. The database and application user have not been created."

