#!/bin/bash
set -euo pipefail

# ============================================================
# Database CLI clients installer
# Supports: apt (Debian/Ubuntu), yum (CentOS/RHEL 7), dnf (RHEL 8+/Fedora)
# Usage:
#   sudo ./install-db-clients.sh              # install all
#   sudo ./install-db-clients.sh mysql redis   # install specific tools
#   sudo ./install-db-clients.sh --force       # force reinstall all
#   sudo ./install-db-clients.sh --force mysql # force reinstall specific
# ============================================================

# --- Version config ---
MONGOSH_VER="2.8.2"
MONGOTOOLS_VER="100.16.0"
MONGO_REPO_VERSION="7.0"  # 用于 mongosh 和 mongotools 的仓库版本

# --- All available tools ---
ALL_TOOLS="mysql psql redis mongosh mongotools clickhouse"

# --- Parse arguments ---
FORCE=false
SELECTED_TOOLS=""
for arg in "$@"; do
  if [ "$arg" = "--force" ] || [ "$arg" = "-f" ]; then
    FORCE=true
  else
    SELECTED_TOOLS="$SELECTED_TOOLS $arg"
  fi
done
SELECTED_TOOLS="${SELECTED_TOOLS:- $ALL_TOOLS}"

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: this script must be run as root (use sudo)"
  exit 1
fi

# --- Detect architecture ---
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  DEB_ARCH="x86_64"; RPM_ARCH="x86_64" ;;
  aarch64) DEB_ARCH="arm64"; RPM_ARCH="aarch64" ;;
  amd64)   DEB_ARCH="x86_64"; RPM_ARCH="x86_64" ;;  
  arm64)   DEB_ARCH="arm64"; RPM_ARCH="aarch64" ;;
  *) echo "Error: unsupported architecture: $ARCH"; exit 1 ;;
esac

# --- Detect package manager ---
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
else
  echo "Error: no supported package manager found (apt/yum/dnf)"
  exit 1
fi

# --- Detect OS version for mongo-tools URL ---
detect_os_tag() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      ubuntu)
        case "${VERSION_ID%%.*}" in
          24|25) echo "ubuntu2404" ;;
          22)    echo "ubuntu2204" ;;
          20)    echo "ubuntu2004" ;;
          *)     echo "ubuntu2204" ;;
        esac ;;
      debian)
        case "${VERSION_ID%%.*}" in
          12) echo "debian12" ;;
          11) echo "debian11" ;;
          *)  echo "debian12" ;;
        esac ;;
      centos|rhel|rocky|alma|fedora)
        case "${VERSION_ID%%.*}" in
          7)  echo "rhel70" ;;
          8)  echo "rhel80" ;;
          9|*) echo "rhel90" ;;
        esac ;;
      *) echo "ubuntu2204" ;;
    esac
  else
    echo "ubuntu2204"
  fi
}

export DEBIAN_FRONTEND=noninteractive

install_pkg() {
  case "$PKG_MGR" in
    apt) apt-get install -y -qq "$@" ;;
    yum) yum install -y -q "$@" ;;
    dnf) dnf install -y -q "$@" ;;
  esac
}

REPO_UPDATED=false
ensure_repo_updated() {
  if [ "$REPO_UPDATED" = false ]; then
    case "$PKG_MGR" in
      apt) apt-get update -qq ;;
      yum) yum makecache -q ;;
      dnf) dnf makecache -q ;;
    esac
    REPO_UPDATED=true
  fi
}

# Download helper with cleanup on failure
download() {
  local url="$1" dest="$2"
  if ! curl -fsSL "$url" -o "$dest"; then
    rm -f "$dest"
    echo "Error: failed to download $url"
    return 1
  fi
}

should_install() {
  echo "$SELECTED_TOOLS" | grep -qw "$1"
}

need_install() {
  local name="$1" check_cmd="$2" label="$3" step="$4"
  if ! should_install "$name"; then
    return 1
  fi
  if [ "$FORCE" = true ]; then
    echo "[$step] Installing $label (force)..."
    return 0
  fi
  if command -v "$check_cmd" &>/dev/null; then
    echo "[$step] $label ... already installed, skipping"
    return 1
  fi
  echo "[$step] Installing $label..."
  return 0
}

echo "=== Installing database CLI clients ==="
echo "Detected: $PKG_MGR ($ARCH)"
[ "$FORCE" = true ] && echo "Mode: force reinstall"
echo ""

# --- 1. MySQL client ---
if need_install "mysql" "mysql" "MySQL client" "1/6"; then
  ensure_repo_updated
  case "$PKG_MGR" in
    apt) install_pkg mysql-client ;;
    yum|dnf) install_pkg mysql ;;
  esac
fi

# --- 2. PostgreSQL client ---
if need_install "psql" "psql" "PostgreSQL client" "2/6"; then
  ensure_repo_updated
  case "$PKG_MGR" in
    apt) install_pkg postgresql-client ;;
    yum|dnf) install_pkg postgresql ;;
  esac
fi

# --- 3. Redis client ---
if need_install "redis" "redis-cli" "Redis client" "3/6"; then
  ensure_repo_updated
  case "$PKG_MGR" in
    apt) install_pkg redis-tools ;;
    yum|dnf) install_pkg redis ;;
  esac
  # redis-cli is the actual command, but we use "redis" as the selector name
fi

# --- 4. mongosh ---
if should_install "mongosh"; then
  if [ "$FORCE" = false ] && command -v mongosh &>/dev/null; then
    echo "[4/6] MongoDB client (mongosh) ... already installed, skipping"
  else
    echo "[4/6] Installing MongoDB client (mongosh)..."
    install_pkg curl
    # mongosh uses "amd64" in filename
    MONGOSH_DEB_ARCH="amd64"
    case "$PKG_MGR" in
      apt)
        download "https://downloads.mongodb.com/compass/mongodb-mongosh_${MONGOSH_VER}_${MONGOSH_DEB_ARCH}.deb" /tmp/mongosh.deb
        dpkg -i /tmp/mongosh.deb
        rm -f /tmp/mongosh.deb
        ;;
      yum|dnf)
        download "https://downloads.mongodb.com/compass/mongodb-mongosh-${MONGOSH_VER}.${RPM_ARCH}.rpm" /tmp/mongosh.rpm
        rpm -ivh /tmp/mongosh.rpm
        rm -f /tmp/mongosh.rpm
        ;;
    esac
  fi
fi

# --- 5. MongoDB database tools ---
if should_install "mongotools"; then
  if [ "$FORCE" = false ] && command -v mongodump &>/dev/null; then
    echo "[5/6] MongoDB database tools ... already installed, skipping"
  else
    echo "[5/6] Installing MongoDB database tools..."
    install_pkg curl
    OS_TAG=$(detect_os_tag)
    # mongotools uses "x86_64" in filename (not amd64)
    case "$PKG_MGR" in
      apt)
        download "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${OS_TAG}-${DEB_ARCH}-${MONGOTOOLS_VER}.deb" /tmp/mongo-tools.deb
        dpkg -i /tmp/mongo-tools.deb
        rm -f /tmp/mongo-tools.deb
        ;;
      yum|dnf)
        download "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${OS_TAG}-${RPM_ARCH}-${MONGOTOOLS_VER}.rpm" /tmp/mongo-tools.rpm
        rpm -ivh /tmp/mongo-tools.rpm
        rm -f /tmp/mongo-tools.rpm
        ;;
    esac
  fi
fi

# --- 6. ClickHouse client ---
if need_install "clickhouse" "clickhouse-client" "ClickHouse client" "6/6"; then
  case "$PKG_MGR" in
    apt)
      install_pkg apt-transport-https ca-certificates gnupg
      curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/clickhouse-keyring.gpg 2>/dev/null
      echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
        > /etc/apt/sources.list.d/clickhouse.list
      apt-get update -qq
      install_pkg clickhouse-client
      ;;
    yum|dnf)
      cat > /etc/yum.repos.d/clickhouse.repo <<'REPO'
[clickhouse-stable]
name=ClickHouse - Stable Repository
baseurl=https://packages.clickhouse.com/rpm/stable/
gpgcheck=0
enabled=1
REPO
      install_pkg clickhouse-client
      ;;
  esac
fi

echo ""
echo "=== Installed versions ==="
echo "mysql:      $(mysql --version 2>/dev/null || echo 'not found')"
echo "psql:       $(psql --version 2>/dev/null || echo 'not found')"
echo "redis-cli:  $(redis-cli --version 2>/dev/null || echo 'not found')"
echo "mongosh:    $(mongosh --version 2>/dev/null || echo 'not found')"
echo "mongodump:  $(mongodump --version 2>/dev/null | head -1 || echo 'not found')"
echo "clickhouse: $(clickhouse-client --version 2>/dev/null || echo 'not found')"
