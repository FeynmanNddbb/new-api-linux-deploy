#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="/opt/new-api"
INSTALL_LOG="/var/log/new-api-installer.log"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  fi

  echo "This installer must run as root or through sudo." >&2
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_LOG")"
exec > >(tee -a "$INSTALL_LOG") 2>&1

trap 'echo "Installation failed at line ${LINENO}. Check ${INSTALL_LOG}." >&2' ERR

normalize_domain() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%.}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

DOMAIN="${1:-}"

while true; do
  if [ -z "$DOMAIN" ]; then
    read -r -p "Enter the domain for New API, for example api.example.com: " DOMAIN
  fi

  DOMAIN="$(normalize_domain "$DOMAIN")"

  if valid_domain "$DOMAIN"; then
    break
  fi

  echo "Invalid domain: $DOMAIN"
  DOMAIN=""
done

if [ ! -r /etc/os-release ]; then
  echo "Cannot identify Linux: /etc/os-release does not exist." >&2
  exit 1
fi

. /etc/os-release
OS_ID="${ID,,}"

echo "Detected system: ${PRETTY_NAME:-$OS_ID}"
echo "Target domain: $DOMAIN"

docker_ready() {
  command -v docker >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1
}

install_debian_packages() {
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y ca-certificates curl gnupg git logrotate

  if ! docker_ready; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="${VERSION_CODENAME:-}"

    if [ -z "$codename" ]; then
      echo "Cannot identify VERSION_CODENAME." >&2
      exit 1
    fi

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/setup.deb.sh | bash
    apt-get update
    apt-get install -y caddy
  fi
}

install_rpm_packages() {
  local pkg docker_dist

  if command -v dnf >/dev/null 2>&1; then
    pkg=dnf
  elif command -v yum >/dev/null 2>&1; then
    pkg=yum
  else
    echo "DNF or YUM is required on this system." >&2
    exit 1
  fi

  "$pkg" install -y ca-certificates curl git logrotate

  if ! docker_ready; then
    case "$OS_ID" in
      fedora) docker_dist=fedora ;;
      rhel) docker_dist=rhel ;;
      centos|rocky|almalinux) docker_dist=centos ;;
    esac

    curl -fsSL "https://download.docker.com/linux/${docker_dist}/docker-ce.repo" \
      > /etc/yum.repos.d/docker-ce.repo

    "$pkg" install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh | bash
    "$pkg" install -y caddy
  fi
}

case "$OS_ID" in
  debian|ubuntu)
    install_debian_packages
    ;;
  centos|rhel|rocky|almalinux|fedora)
    install_rpm_packages
    ;;
  *)
    echo "Unsupported distribution: ${PRETTY_NAME:-$OS_ID}" >&2
    echo "Supported: Debian, Ubuntu, CentOS, RHEL, Rocky Linux, AlmaLinux, Fedora." >&2
    exit 1
    ;;
esac

systemctl enable --now docker

echo "Docker version: $(docker --version)"
echo "Compose version: $(docker compose version --short)"
echo "Caddy version: $(caddy version)"

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing New API repository..."
  git -C "$INSTALL_DIR" pull --ff-only
elif [ -e "$INSTALL_DIR" ]; then
  if [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    echo "$INSTALL_DIR exists and is not a New API Git repository." >&2
    exit 1
  fi

  git clone --depth 1 https://github.com/QuantumNous/new-api.git "$INSTALL_DIR"
else
  git clone --depth 1 https://github.com/QuantumNous/new-api.git "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/logs"

cat > "$INSTALL_DIR/docker-compose.override.yml" <<'COMPOSE'
# Managed by install.sh
services:
  new-api:
    logging: &default-logging
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
  postgres:
    logging: *default-logging
  redis:
    logging: *default-logging
COMPOSE

cat > /etc/logrotate.d/new-api <<LOGROTATE
${INSTALL_DIR}/logs/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
LOGROTATE

cd "$INSTALL_DIR"
docker compose config >/dev/null
docker compose pull

DOCKER_BIN="$(command -v docker)"

cat > /etc/systemd/system/new-api-compose.service <<UNIT
[Unit]
Description=New API Docker Compose Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=${DOCKER_BIN} compose up -d --remove-orphans
ExecStop=${DOCKER_BIN} compose stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now new-api-compose.service

if [ -f /etc/caddy/Caddyfile ]; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
  reverse_proxy 127.0.0.1:3000
}
CADDY

caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

if command -v ufw >/dev/null 2>&1 \
  && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

echo "Waiting for New API to become ready..."
NEW_API_READY=0

for _ in {1..30}; do
  if curl -fsS --max-time 5 http://127.0.0.1:3000/api/status >/dev/null; then
    NEW_API_READY=1
    break
  fi

  sleep 2
done

DNS_READY=1
if command -v getent >/dev/null 2>&1 \
  && ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
  DNS_READY=0
fi

echo
echo "============================================================"
echo "New API installation completed"
echo "============================================================"
echo "Website:        https://${DOMAIN}"
echo "Project path:   ${INSTALL_DIR}"
echo "Install log:    ${INSTALL_LOG}"
echo "Container logs: 20 MB per file, 5 files"
echo "App logs:       daily rotation, 14 archives"
echo "Auto start:     Docker, Caddy, New API enabled"
echo

if [ "$NEW_API_READY" -eq 1 ]; then
  echo "New API local health check: passed"
else
  echo "New API local health check: not ready"
  echo "Check logs: cd ${INSTALL_DIR} && docker compose logs --tail=200"
fi

if [ "$DNS_READY" -eq 0 ]; then
  echo "DNS warning: ${DOMAIN} does not resolve yet."
  echo "Create an A record pointing the domain to this server."
fi

echo "Make sure cloud firewall/security groups allow TCP 80 and 443."
echo "The upstream default database and Redis password is 123456."
echo "Open https://${DOMAIN} after DNS propagation to initialize the administrator."
