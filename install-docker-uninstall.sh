#!/usr/bin/env bash
#
# Docker 静态二进制安装/卸载脚本
# 支持 Linux amd64/arm64，使用 systemd 管理 Docker 服务。
#
# 官方说明：静态二进制更适合测试、离线或受控环境；生产环境优先使用
# 发行版的软件包管理器，以便及时获取安全更新。
# https://docs.docker.com/engine/install/binaries/

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# 可通过同名环境变量覆盖。
DOCKER_VERSION="${DOCKER_VERSION:-29.6.2}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v5.3.1}"
BUILDX_VERSION="${BUILDX_VERSION:-v0.36.0}"
# Docker 静态下载站没有随包提供 checksum 文件；如有可信哈希可在此固定。
DOCKER_SHA256="${DOCKER_SHA256:-}"
DOWNLOAD_REGION="${DOWNLOAD_REGION:-${REGISTRY_MIRROR:-GLOBAL}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/var/cache/docker-static-installer}"
INSTALL_DIR="${INSTALL_DIR:-/opt/docker/bin}"
PLUGIN_DIR="${PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}"
DOCKER_LINK="${DOCKER_LINK:-/usr/bin/docker}"
DATA_ROOT="${DATA_ROOT:-/data/docker}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"

# 逗号分隔；默认不添加第三方镜像或不安全仓库。
DOCKER_REGISTRY_MIRRORS="${DOCKER_REGISTRY_MIRRORS:-}"
INSECURE_REGISTRIES="${INSECURE_REGISTRIES:-}"
# 按用户要求恢复旧版行为；设为 0 可分别关闭。
DISABLE_SELINUX="${DISABLE_SELINUX:-1}"
ALLOW_FORWARD_ALL="${ALLOW_FORWARD_ALL:-1}"
LIVE_RESTORE="${LIVE_RESTORE:-1}"
AUTO_INSTALL_DEPENDENCIES="${AUTO_INSTALL_DEPENDENCIES:-1}"

readonly STATE_DIR="/var/lib/docker-static-installer"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly SERVICE_FILE="/etc/systemd/system/docker.service"
readonly DAEMON_CONFIG="/etc/docker/daemon.json"
readonly COMPLETION_FILE="/etc/bash_completion.d/docker"

FORCE=0
ASSUME_YES=0
ACTION=""
WORK_DIR=""
HAD_STATE=0
PRIOR_MANAGED=0
PLATFORM_ARCH=""
COMPOSE_ARCH=""
BUILDX_ARCH=""
DOCKER_ARCHIVE_NAME=""
COMPOSE_ASSET=""
BUILDX_ASSET=""

C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_RESET=""
C_BOLD=""

init_colors() {
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[36m'
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
  fi
}

log() {
  local level="$1"
  shift
  local color="$C_BLUE"

  case "$level" in
    INFO)  color="$C_GREEN" ;;
    WARN)  color="$C_YELLOW" ;;
    ERROR) color="$C_RED" ;;
  esac

  printf '%b[%s]%b %s\n' "$color" "$level" "$C_RESET" "$*" >&2
}

die() {
  log ERROR "$*"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_number="$2"
  log ERROR "第 ${line_number} 行执行失败（退出码 ${exit_code}）"
  exit "$exit_code"
}

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

ensure_work_dir() {
  if [[ -z "${WORK_DIR:-}" || ! -d "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d /tmp/docker-static-installer.XXXXXX)"
  fi
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup EXIT

show_help() {
  printf '%bDocker 静态二进制安装/卸载脚本%b\n' "$C_BOLD" "$C_RESET"
  cat <<EOF
用法:
  ${0##*/} <操作> [选项]

操作:
  --download     下载并校验 Docker、Compose 和 Buildx
  --install      安装已下载的组件
  --all          下载并安装
  --upgrade      查询官方最新稳定版并原地升级
  --uninstall    卸载本脚本管理的文件（保留 Docker 数据）
  --help         显示帮助

选项:
  --force        允许覆盖冲突安装；下载时强制刷新缓存
  --yes, -y      跳过确认

常用环境变量:
  DOCKER_VERSION               默认: ${DOCKER_VERSION}
  COMPOSE_VERSION              默认: ${COMPOSE_VERSION}
  BUILDX_VERSION               默认: ${BUILDX_VERSION}
  DOCKER_SHA256                可选：固定 Docker 压缩包的 SHA-256
  DOWNLOAD_REGION              GLOBAL 或 CN，默认: ${DOWNLOAD_REGION}
  DOWNLOAD_DIR                 默认: ${DOWNLOAD_DIR}
  INSTALL_DIR                  默认: ${INSTALL_DIR}
  DATA_ROOT                    默认: ${DATA_ROOT}
  TARGET_USER                  加入 docker 组的用户，默认取 SUDO_USER
  DOCKER_REGISTRY_MIRRORS      逗号分隔的镜像地址
  INSECURE_REGISTRIES          逗号分隔的不安全仓库地址
  DISABLE_SELINUX              1=关闭 SELinux，默认: ${DISABLE_SELINUX}
  ALLOW_FORWARD_ALL            1=全局放行 IPv4 FORWARD，默认: ${ALLOW_FORWARD_ALL}
  LIVE_RESTORE                 1=升级时保持容器运行，默认: ${LIVE_RESTORE}
  AUTO_INSTALL_DEPENDENCIES    1=自动安装 iptables/git，默认: ${AUTO_INSTALL_DEPENDENCIES}

示例:
  sudo ./${0##*/} --all
  sudo TARGET_USER=alice DATA_ROOT=/data/docker ./${0##*/} --install
  sudo DOWNLOAD_REGION=CN ./${0##*/} --download --force
  sudo ./${0##*/} --upgrade
  sudo ./${0##*/} --uninstall

注意:
  静态二进制不会随系统自动获得安全更新，生产环境优先使用发行版包管理器。
  默认关闭 SELinux 并全局放行 IPv4 FORWARD；这会降低主机安全隔离能力。
  Live Restore 仅保证补丁版本升级，跨大版本仍应预留维护窗口。
EOF
}

parse_args() {
  if (( $# == 0 )); then
    show_help
    exit 0
  fi

  while (( $# > 0 )); do
    case "$1" in
      --download|--install|--all|--upgrade|--uninstall)
        [[ -z "$ACTION" ]] || die "一次只能指定一个操作"
        ACTION="$1"
        ;;
      --force)
        FORCE=1
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        die "未知参数: $1（使用 --help 查看帮助）"
        ;;
    esac
    shift
  done

  [[ -n "$ACTION" ]] || die "缺少操作参数（使用 --help 查看帮助）"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

require_root() {
  (( EUID == 0 )) || die "此操作需要 root 权限，请使用 sudo 运行"
}

validate_absolute_path() {
  local name="$1"
  local path="$2"

  [[ "$path" == /* ]] || die "${name} 必须是绝对路径: ${path}"
  [[ "$path" != "/" ]] || die "${name} 不能是根目录"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] ||
    die "${name} 不能包含换行符"
}

normalize_versions() {
  COMPOSE_VERSION="${COMPOSE_VERSION#v}"
  BUILDX_VERSION="${BUILDX_VERSION#v}"

  [[ "$DOCKER_VERSION" =~ ^[0-9][0-9A-Za-z.-]*$ ]] ||
    die "DOCKER_VERSION 格式不合法: ${DOCKER_VERSION}"
  [[ "$COMPOSE_VERSION" =~ ^[0-9][0-9A-Za-z.-]*$ ]] ||
    die "COMPOSE_VERSION 格式不合法: ${COMPOSE_VERSION}"
  [[ "$BUILDX_VERSION" =~ ^[0-9][0-9A-Za-z.-]*$ ]] ||
    die "BUILDX_VERSION 格式不合法: ${BUILDX_VERSION}"
  [[ -z "$DOCKER_SHA256" || "$DOCKER_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "DOCKER_SHA256 必须是 64 位十六进制字符串"
  [[ "$DISABLE_SELINUX" =~ ^[01]$ ]] ||
    die "DISABLE_SELINUX 只能是 0 或 1"
  [[ "$ALLOW_FORWARD_ALL" =~ ^[01]$ ]] ||
    die "ALLOW_FORWARD_ALL 只能是 0 或 1"
  [[ "$LIVE_RESTORE" =~ ^[01]$ ]] ||
    die "LIVE_RESTORE 只能是 0 或 1"
  [[ "$AUTO_INSTALL_DEPENDENCIES" =~ ^[01]$ ]] ||
    die "AUTO_INSTALL_DEPENDENCIES 只能是 0 或 1"

  COMPOSE_VERSION="v${COMPOSE_VERSION}"
  BUILDX_VERSION="v${BUILDX_VERSION}"
}

validate_settings() {
  validate_absolute_path "DOWNLOAD_DIR" "$DOWNLOAD_DIR"
  validate_absolute_path "INSTALL_DIR" "$INSTALL_DIR"
  validate_absolute_path "PLUGIN_DIR" "$PLUGIN_DIR"
  validate_absolute_path "DOCKER_LINK" "$DOCKER_LINK"
  validate_absolute_path "DATA_ROOT" "$DATA_ROOT"

  local path
  for path in \
    "$DOWNLOAD_DIR" "$INSTALL_DIR" "$PLUGIN_DIR" "$DOCKER_LINK" "$DATA_ROOT"; do
    case "${path}/" in
      */../*|*/./*) die "路径不能包含 . 或 .. 段: ${path}" ;;
    esac
  done

  case "$INSTALL_DIR" in
    /opt|/usr|/usr/*|/bin|/sbin|/etc|/etc/*|/boot|/boot/*|/dev|/dev/*|\
    /proc|/proc/*|/sys|/sys/*|/run|/run/*)
      die "INSTALL_DIR 必须是独立且非系统关键的目录: ${INSTALL_DIR}"
      ;;
  esac
  case "$DOCKER_LINK" in
    /bin|/sbin|/usr/bin|/usr/sbin|/usr/local/bin|/usr/local/sbin)
      die "DOCKER_LINK 必须指向具体文件，不能是命令目录: ${DOCKER_LINK}"
      ;;
  esac
  if [[ -d "$DOCKER_LINK" && ! -L "$DOCKER_LINK" ]]; then
    die "DOCKER_LINK 已是目录，必须改为具体文件路径: ${DOCKER_LINK}"
  fi
  case "$DATA_ROOT" in
    /bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/etc|/etc/*|/boot|/boot/*|\
    /dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*)
      die "DATA_ROOT 不能位于系统关键目录: ${DATA_ROOT}"
      ;;
  esac

  case "$DOWNLOAD_REGION" in
    GLOBAL|global|US|us|CN|cn) ;;
    *) die "DOWNLOAD_REGION 仅支持 GLOBAL 或 CN: ${DOWNLOAD_REGION}" ;;
  esac
}

detect_platform() {
  local kernel
  local machine

  kernel="$(uname -s)"
  machine="$(uname -m)"
  [[ "$kernel" == "Linux" ]] || die "仅支持 Linux，当前系统: ${kernel}"

  case "$machine" in
    x86_64|amd64)
      PLATFORM_ARCH="x86_64"
      COMPOSE_ARCH="x86_64"
      BUILDX_ARCH="amd64"
      ;;
    aarch64|arm64)
      PLATFORM_ARCH="aarch64"
      COMPOSE_ARCH="aarch64"
      BUILDX_ARCH="arm64"
      ;;
    *)
      die "不支持的 CPU 架构: ${machine}"
      ;;
  esac

  DOCKER_ARCHIVE_NAME="docker-${DOCKER_VERSION}.tgz"
  COMPOSE_ASSET="docker-compose-linux-${COMPOSE_ARCH}"
  BUILDX_ASSET="buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}"
}

load_installed_settings() {
  local settings_file="${STATE_DIR}/versions"
  local key
  local value

  [[ -f "$settings_file" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      DOCKER_VERSION) DOCKER_VERSION="$value" ;;
      COMPOSE_VERSION) COMPOSE_VERSION="$value" ;;
      BUILDX_VERSION) BUILDX_VERSION="$value" ;;
      DOWNLOAD_DIR) DOWNLOAD_DIR="$value" ;;
      INSTALL_DIR) INSTALL_DIR="$value" ;;
      PLUGIN_DIR) PLUGIN_DIR="$value" ;;
      DOCKER_LINK) DOCKER_LINK="$value" ;;
      DATA_ROOT) DATA_ROOT="$value" ;;
      DISABLE_SELINUX) DISABLE_SELINUX="$value" ;;
      ALLOW_FORWARD_ALL) ALLOW_FORWARD_ALL="$value" ;;
      LIVE_RESTORE) LIVE_RESTORE="$value" ;;
      AUTO_INSTALL_DEPENDENCIES) AUTO_INSTALL_DEPENDENCIES="$value" ;;
    esac
  done <"$settings_file"
}

check_common_requirements() {
  require_root
  require_command uname
  require_command tar
  require_command sha256sum
  require_command awk
  require_command grep
  require_command sed
}

check_download_requirements() {
  check_common_requirements
  if ! command -v curl >/dev/null 2>&1 &&
     ! command -v wget >/dev/null 2>&1; then
    die "需要 curl 或 wget 才能下载文件"
  fi
}

check_upgrade_requirements() {
  require_command sort
  require_command tail
  [[ "$(printf '1.9\n1.10\n' | sort -V | tail -n 1)" == "1.10" ]] ||
    die "当前 sort 不支持版本排序（sort -V），无法自动发现最新版"
}

install_system_package() {
  local package="$1"

  if command -v apt-get >/dev/null 2>&1; then
    if ! env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y "$package"; then
      apt-get update
      env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$package"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$package"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "$package"
  elif command -v apk >/dev/null 2>&1; then
    apk add "$package"
  elif command -v pacman >/dev/null 2>&1; then
    if [[ "$package" == "iptables" ]]; then
      package="iptables-nft"
    fi
    pacman -Sy --noconfirm "$package"
  else
    die "无法识别系统包管理器，请手动安装 ${package}"
  fi
}

ensure_runtime_dependencies() {
  if ! command -v iptables >/dev/null 2>&1; then
    (( AUTO_INSTALL_DEPENDENCIES == 1 )) ||
      die "Docker 桥接网络需要 iptables；请先安装，或启用 AUTO_INSTALL_DEPENDENCIES=1"
    log INFO "未检测到 iptables，尝试使用系统包管理器自动安装"
    install_system_package iptables
  fi

  command -v iptables >/dev/null 2>&1 ||
    die "iptables 安装完成后仍不可用，请检查 PATH 或软件包状态"
  log INFO "iptables 安装完成: $(command -v iptables)"

  if ! command -v git >/dev/null 2>&1; then
    if (( AUTO_INSTALL_DEPENDENCIES == 1 )); then
      log INFO "未检测到 git，自动安装以支持 Git 构建上下文"
      install_system_package git
    else
      log WARN "未检测到 git，Docker 的 Git 构建上下文不可用"
    fi
  fi
}

check_install_requirements() {
  local install_mode="${1:-1}"

  check_common_requirements
  require_command systemctl
  require_command install
  require_command getent
  require_command groupadd
  require_command usermod
  require_command readlink

  [[ -d /run/systemd/system ]] ||
    die "当前系统未运行 systemd，无法安装 docker.service"

  if (( install_mode == 1 )); then
    ensure_runtime_dependencies
    if ! iptables -w 5 -L FORWARD -n >/dev/null 2>&1; then
      log WARN "iptables 已安装，但当前无法读取 FORWARD 链；dockerd 启动时将再次检查"
    fi
  fi
}

confirm() {
  local prompt="$1"

  (( ASSUME_YES == 1 )) && return 0
  [[ -r /dev/tty ]] || die "非交互环境请添加 --yes"

  local reply
  read -r -p "${prompt} [y/N] " reply </dev/tty
  [[ "$reply" =~ ^[Yy]$ ]] || die "操作已取消"
}

download_file() {
  local output="$1"
  local display_name="$2"
  shift 2
  local temp_file="${output}.part.$$"
  local url

  if [[ -s "$output" && "$FORCE" -eq 0 ]]; then
    log INFO "复用已下载的 ${display_name}"
    return 0
  fi

  rm -f -- "$temp_file"
  for url in "$@"; do
    log INFO "下载 ${display_name}: ${url}"
    if command -v curl >/dev/null 2>&1; then
      if curl --fail --location --retry 3 --connect-timeout 20 \
        --proto '=https' --tlsv1.2 --progress-bar \
        --output "$temp_file" "$url"; then
        mv -f -- "$temp_file" "$output"
        return 0
      fi
    elif wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
      -O "$temp_file" "$url"; then
      mv -f -- "$temp_file" "$output"
      return 0
    fi
    rm -f -- "$temp_file"
    log WARN "下载源不可用，尝试下一个地址"
  done

  die "${display_name} 下载失败"
}

fetch_text() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --retry 3 \
      --connect-timeout 20 --proto '=https' --tlsv1.2 "$url"
  else
    wget --quiet --timeout=30 --tries=3 -O - "$url"
  fi
}

discover_latest_versions() {
  local docker_index
  local compose_release
  local buildx_release
  local latest_docker
  local latest_compose
  local latest_buildx

  log INFO "查询官方最新稳定版本"
  docker_index="$(
    fetch_text \
      "https://download.docker.com/linux/static/stable/${PLATFORM_ARCH}/"
  )"
  latest_docker="$(
    grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' <<<"$docker_index" |
      sed -E 's/^docker-//; s/\.tgz$//' |
      sort -Vu |
      tail -n 1
  )"

  compose_release="$(
    fetch_text "https://api.github.com/repos/docker/compose/releases/latest"
  )"
  latest_compose="$(
    awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }' \
      <<<"$compose_release"
  )"

  buildx_release="$(
    fetch_text "https://api.github.com/repos/docker/buildx/releases/latest"
  )"
  latest_buildx="$(
    awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }' \
      <<<"$buildx_release"
  )"

  [[ "$latest_docker" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "无法从 Docker 官方下载目录解析最新版本"
  [[ "$latest_compose" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]] ||
    die "无法从 Compose 官方 Release 解析最新版本"
  [[ "$latest_buildx" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]] ||
    die "无法从 Buildx 官方 Release 解析最新版本"

  DOCKER_VERSION="$latest_docker"
  COMPOSE_VERSION="$latest_compose"
  BUILDX_VERSION="$latest_buildx"
  normalize_versions
  detect_platform
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_checksum() {
  local file="$1"
  local manifest="$2"
  local asset_name="$3"
  local expected
  local actual

  expected="$(
    awk -v target="$asset_name" '
      {
        name = $2
        sub(/^\*/, "", name)
        if (name == target) {
          print $1
          exit
        }
      }
    ' "$manifest"
  )"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "校验清单中找不到 ${asset_name}"

  actual="$(sha256_file "$file")"
  [[ "${actual,,}" == "${expected,,}" ]] ||
    die "${asset_name} SHA-256 校验失败，请使用 --force 重新下载"

  log INFO "${asset_name} SHA-256 校验通过"
}

validate_docker_archive() {
  local archive="$1"
  local entry
  local verbose_entry
  local found_docker=0
  local found_dockerd=0

  while IFS= read -r entry; do
    case "$entry" in
      docker|docker/|docker/*) ;;
      *) return 1 ;;
    esac
    case "/${entry}/" in
      */../*) return 1 ;;
    esac
    [[ "$entry" == "docker/docker" ]] && found_docker=1
    [[ "$entry" == "docker/dockerd" ]] && found_dockerd=1
  done < <(tar -tzf "$archive")

  while IFS= read -r verbose_entry; do
    case "${verbose_entry:0:1}" in
      -|d) ;;
      *) return 1 ;;
    esac
  done < <(tar -tvzf "$archive")

  (( found_docker == 1 && found_dockerd == 1 ))
}

verify_downloads() {
  local docker_archive="${DOWNLOAD_DIR}/${DOCKER_ARCHIVE_NAME}"
  local compose_file="${DOWNLOAD_DIR}/${COMPOSE_ASSET}-${COMPOSE_VERSION}"
  local buildx_file="${DOWNLOAD_DIR}/${BUILDX_ASSET}"
  local compose_manifest="${DOWNLOAD_DIR}/compose-checksums-${COMPOSE_VERSION}.txt"
  local buildx_manifest="${DOWNLOAD_DIR}/buildx-checksums-${BUILDX_VERSION}.txt"

  [[ -s "$docker_archive" ]] || die "缺少 Docker 包: ${docker_archive}"
  [[ -s "$compose_file" ]] || die "缺少 Compose: ${compose_file}"
  [[ -s "$buildx_file" ]] || die "缺少 Buildx: ${buildx_file}"
  [[ -s "$compose_manifest" ]] || die "缺少 Compose 校验清单"
  [[ -s "$buildx_manifest" ]] || die "缺少 Buildx 校验清单"

  validate_docker_archive "$docker_archive" ||
    die "Docker 压缩包损坏或包含异常路径，请使用 --force 重新下载"
  if [[ -n "$DOCKER_SHA256" ]]; then
    [[ "${DOCKER_SHA256,,}" == "$(sha256_file "$docker_archive")" ]] ||
      die "Docker 压缩包 SHA-256 校验失败，请使用 --force 重新下载"
    log INFO "${DOCKER_ARCHIVE_NAME} SHA-256 校验通过"
  else
    log WARN "未设置 DOCKER_SHA256；Docker 压缩包仅完成结构校验"
  fi
  verify_checksum "$compose_file" "$compose_manifest" "$COMPOSE_ASSET"
  verify_checksum "$buildx_file" "$buildx_manifest" "$BUILDX_ASSET"
}

download_components() {
  local docker_base="https://download.docker.com/linux/static/stable/${PLATFORM_ARCH}"
  local docker_mirror="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/${PLATFORM_ARCH}"
  local compose_release="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"
  local buildx_release="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}"
  local github_proxy="https://ghfast.top/"
  local docker_archive="${DOWNLOAD_DIR}/${DOCKER_ARCHIVE_NAME}"
  local compose_file="${DOWNLOAD_DIR}/${COMPOSE_ASSET}-${COMPOSE_VERSION}"
  local buildx_file="${DOWNLOAD_DIR}/${BUILDX_ASSET}"
  local compose_manifest="${DOWNLOAD_DIR}/compose-checksums-${COMPOSE_VERSION}.txt"
  local buildx_manifest="${DOWNLOAD_DIR}/buildx-checksums-${BUILDX_VERSION}.txt"

  install -d -m 0755 "$DOWNLOAD_DIR"
  log INFO "下载目录: ${DOWNLOAD_DIR}"

  if [[ "$DOWNLOAD_REGION" =~ ^(CN|cn)$ ]]; then
    download_file "$docker_archive" "Docker ${DOCKER_VERSION}" \
      "${docker_mirror}/${DOCKER_ARCHIVE_NAME}" \
      "${docker_base}/${DOCKER_ARCHIVE_NAME}"
    download_file "$compose_file" "Docker Compose ${COMPOSE_VERSION}" \
      "${github_proxy}${compose_release}/${COMPOSE_ASSET}" \
      "${compose_release}/${COMPOSE_ASSET}"
    download_file "$buildx_file" "Docker Buildx ${BUILDX_VERSION}" \
      "${github_proxy}${buildx_release}/${BUILDX_ASSET}" \
      "${buildx_release}/${BUILDX_ASSET}"
    download_file "$compose_manifest" "Compose 校验清单" \
      "${github_proxy}${compose_release}/checksums.txt" \
      "${compose_release}/checksums.txt"
    download_file "$buildx_manifest" "Buildx 校验清单" \
      "${github_proxy}${buildx_release}/checksums.txt" \
      "${buildx_release}/checksums.txt"
  else
    download_file "$docker_archive" "Docker ${DOCKER_VERSION}" \
      "${docker_base}/${DOCKER_ARCHIVE_NAME}"
    download_file "$compose_file" "Docker Compose ${COMPOSE_VERSION}" \
      "${compose_release}/${COMPOSE_ASSET}"
    download_file "$buildx_file" "Docker Buildx ${BUILDX_VERSION}" \
      "${buildx_release}/${BUILDX_ASSET}"
    download_file "$compose_manifest" "Compose 校验清单" \
      "${compose_release}/checksums.txt"
    download_file "$buildx_manifest" "Buildx 校验清单" \
      "${buildx_release}/checksums.txt"
  fi

  verify_downloads
  log INFO "Docker 组件下载并校验完成"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

is_link_to() {
  local link="$1"
  local target="$2"
  [[ -L "$link" ]] || return 1
  [[ "$(readlink -f -- "$link")" == "$(readlink -f -- "$target")" ]]
}

is_managed_service() {
  [[ -f "$SERVICE_FILE" ]] &&
    grep -Fq "ExecStart=${INSTALL_DIR}/dockerd" "$SERVICE_FILE"
}

find_install_conflicts() {
  local conflicts=()
  local existing_dockerd=""

  if is_managed_service ||
     [[ -f "${INSTALL_DIR}/.docker-static-installer" ]]; then
    PRIOR_MANAGED=1
  fi

  if command -v dockerd >/dev/null 2>&1; then
    existing_dockerd="$(readlink -f -- "$(command -v dockerd)")"
    [[ "$existing_dockerd" == "${INSTALL_DIR}/dockerd" ||
       "$PRIOR_MANAGED" -eq 1 ]] ||
      conflicts+=("已有 dockerd: ${existing_dockerd}")
  fi

  if path_exists "$DOCKER_LINK" &&
     ! is_link_to "$DOCKER_LINK" "${INSTALL_DIR}/docker" &&
     [[ "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 Docker 命令: ${DOCKER_LINK}")
  fi
  if path_exists "${PLUGIN_DIR}/docker-compose" &&
     ! is_link_to "${PLUGIN_DIR}/docker-compose" \
       "${INSTALL_DIR}/cli-plugins/docker-compose" &&
     [[ "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 Compose 插件: ${PLUGIN_DIR}/docker-compose")
  fi
  if path_exists "${PLUGIN_DIR}/docker-buildx" &&
     ! is_link_to "${PLUGIN_DIR}/docker-buildx" \
       "${INSTALL_DIR}/cli-plugins/docker-buildx" &&
     [[ "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 Buildx 插件: ${PLUGIN_DIR}/docker-buildx")
  fi
  if [[ -f "$SERVICE_FILE" && "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 systemd 服务: ${SERVICE_FILE}")
  fi
  if [[ -f "$DAEMON_CONFIG" && "$HAD_STATE" -eq 0 ]] &&
     [[ "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 Docker 配置: ${DAEMON_CONFIG}")
  fi
  if path_exists "$INSTALL_DIR" && [[ "$PRIOR_MANAGED" -eq 0 ]]; then
    die "INSTALL_DIR 已存在且不属于本脚本，请改用空的独立目录: ${INSTALL_DIR}"
  fi
  if path_exists "$COMPLETION_FILE" &&
     [[ "$HAD_STATE" -eq 0 && "$PRIOR_MANAGED" -eq 0 ]]; then
    conflicts+=("已有 Bash 补全文件: ${COMPLETION_FILE}")
  fi

  if (( ${#conflicts[@]} > 0 )); then
    log WARN "检测到可能由其他方式管理的 Docker 文件："
    printf '  - %s\n' "${conflicts[@]}" >&2
    (( FORCE == 1 )) ||
      die "为避免覆盖现有安装，已停止；确认后可使用 --force"
    confirm "备份上述文件并继续安装？"
  fi
}

backup_once() {
  local destination="$1"
  local name="$2"
  local backup="${BACKUP_DIR}/${name}"

  path_exists "$destination" || return 0
  if path_exists "$backup"; then
    die "备份已存在，无法安全覆盖: ${backup}"
  fi

  mv -- "$destination" "$backup"
  log INFO "已备份 ${destination} -> ${backup}"
}

snapshot_modified() {
  local destination="$1"
  local name="$2"
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"
  cp -a -- "$destination" "${BACKUP_DIR}/${name}.modified-${timestamp}"
  log WARN "已保留用户修改: ${BACKUP_DIR}/${name}.modified-${timestamp}"
}

record_hash() {
  local name="$1"
  local file="$2"
  sha256_file "$file" >"${STATE_DIR}/${name}.sha256"
}

managed_file_matches() {
  local name="$1"
  local file="$2"
  local hash_file="${STATE_DIR}/${name}.sha256"
  local expected

  [[ -f "$file" && -f "$hash_file" ]] || return 1
  expected="$(<"$hash_file")"
  [[ "$(sha256_file "$file")" == "$expected" ]]
}

prepare_managed_file() {
  local destination="$1"
  local name="$2"
  local legacy_owned="${3:-0}"

  path_exists "$destination" || return 0
  if (( HAD_STATE == 1 )); then
    if managed_file_matches "$name" "$destination"; then
      rm -f -- "$destination"
    else
      (( FORCE == 1 )) ||
        die "${destination} 在安装后被修改；检查内容或使用 --force 保留副本后覆盖"
      snapshot_modified "$destination" "$name"
      rm -f -- "$destination"
    fi
  elif (( PRIOR_MANAGED == 1 && legacy_owned == 1 )); then
    rm -f -- "$destination"
  else
    backup_once "$destination" "$name"
  fi
}

install_managed_file() {
  local source="$1"
  local destination="$2"
  local name="$3"
  local mode="${4:-0644}"
  local legacy_owned="${5:-0}"

  prepare_managed_file "$destination" "$name" "$legacy_owned"
  install -D -m "$mode" "$source" "$destination"
  record_hash "$name" "$destination"
}

install_managed_link() {
  local target="$1"
  local destination="$2"
  local name="$3"

  if is_link_to "$destination" "$target"; then
    return 0
  fi

  if path_exists "$destination"; then
    if (( HAD_STATE == 1 )); then
      (( FORCE == 1 )) ||
        die "${destination} 在安装后被修改；检查内容或使用 --force"
      snapshot_modified "$destination" "$name"
      rm -f -- "$destination"
    elif (( PRIOR_MANAGED == 1 )); then
      rm -f -- "$destination"
    else
      backup_once "$destination" "$name"
    fi
  fi

  ln -s -- "$target" "$destination"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

write_json_array() {
  local key="$1"
  local raw_values="$2"
  local values=()
  local value
  local index

  IFS=',' read -r -a values <<<"$raw_values"
  printf ',\n  "%s": [' "$key"
  for index in "${!values[@]}"; do
    value="$(trim_space "${values[$index]}")"
    [[ -n "$value" ]] || die "${key} 中包含空值"
    (( index == 0 )) || printf ','
    printf '\n    "%s"' "$(json_escape "$value")"
  done
  printf '\n  ]'
}

create_daemon_config() {
  local output="$1"

  {
    printf '{\n'
    printf '  "data-root": "%s",\n' "$(json_escape "$DATA_ROOT")"
    if (( LIVE_RESTORE == 1 )); then
      printf '  "live-restore": true,\n'
    else
      printf '  "live-restore": false,\n'
    fi
    printf '  "exec-opts": ["native.cgroupdriver=systemd"],\n'
    printf '  "userland-proxy": true,\n'
    printf '  "userland-proxy-path": "%s",\n' \
      "$(json_escape "${INSTALL_DIR}/docker-proxy")"
    printf '  "max-concurrent-downloads": 10,\n'
    printf '  "log-driver": "json-file",\n'
    printf '  "log-level": "warn",\n'
    printf '  "log-opts": {\n'
    printf '    "max-size": "10m",\n'
    printf '    "max-file": "3"\n'
    printf '  }'
    if [[ -n "$DOCKER_REGISTRY_MIRRORS" ]]; then
      write_json_array "registry-mirrors" "$DOCKER_REGISTRY_MIRRORS"
    fi
    if [[ -n "$INSECURE_REGISTRIES" ]]; then
      write_json_array "insecure-registries" "$INSECURE_REGISTRIES"
    fi
    printf '\n}\n'
  } >"$output"
}

create_service_file() {
  local output="$1"
  local forward_rule=""

  if (( ALLOW_FORWARD_ALL == 1 )); then
    forward_rule="ExecStartPost=/bin/bash -c 'if command -v iptables >/dev/null 2>&1 && ! iptables -w 5 -C FORWARD -s 0.0.0.0/0 -j ACCEPT 2>/dev/null; then if iptables -w 5 -I FORWARD -s 0.0.0.0/0 -j ACCEPT; then touch ${STATE_DIR}/forward-rule-added; else echo \"[WARN] 无法添加全局 FORWARD ACCEPT 规则\" >&2; fi; fi; exit 0'"
  fi

  cat >"$output" <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target
Wants=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=notify
Environment="PATH=${INSTALL_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${INSTALL_DIR}/dockerd
${forward_rule}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutStartSec=0
Restart=always
RestartSec=2
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
}

configure_selinux() {
  local selinux_config="/etc/selinux/config"
  local backup="${BACKUP_DIR}/selinux-config"

  (( DISABLE_SELINUX == 1 )) || return 0
  [[ -f "$selinux_config" ]] || {
    log INFO "未检测到 SELinux 配置，跳过"
    return 0
  }

  if grep -Eq '^[[:space:]]*SELINUX=disabled([[:space:]]|$)' \
    "$selinux_config"; then
    log INFO "SELinux 已处于 disabled 配置"
  else
    if ! path_exists "$backup"; then
      cp -a -- "$selinux_config" "$backup"
    fi
    sed -i \
      's/^[[:space:]]*SELINUX=.*/SELINUX=disabled/' \
      "$selinux_config"
    if ! grep -Eq '^[[:space:]]*SELINUX=disabled([[:space:]]|$)' \
      "$selinux_config"; then
      printf '\nSELINUX=disabled\n' >>"$selinux_config"
    fi
    record_hash "selinux-config" "$selinux_config"
    : >"${STATE_DIR}/selinux-config-changed"
    log WARN "已将 SELinux 永久配置为 disabled，重启后完全生效"
  fi

  if command -v setenforce >/dev/null 2>&1; then
    setenforce 0 2>/dev/null || true
    log WARN "已尝试将当前 SELinux 模式切换为 Permissive"
  fi
}

apply_running_live_restore() {
  local desired="$1"
  local config_temp

  systemctl is-active --quiet docker.service || return 0
  if ! managed_file_matches "daemon-config" "$DAEMON_CONFIG"; then
    log WARN "daemon.json 已被修改，无法安全地在线切换 Live Restore"
    return 1
  fi
  if grep -Eq \
    "\"live-restore\"[[:space:]]*:[[:space:]]*${desired}" \
    "$DAEMON_CONFIG"; then
    return 0
  fi

  ensure_work_dir
  config_temp="${WORK_DIR}/live-restore-${desired}.json"
  if grep -Eq '"live-restore"[[:space:]]*:' "$DAEMON_CONFIG"; then
    sed -E \
      "s/(\"live-restore\"[[:space:]]*:[[:space:]]*)(true|false)/\\1${desired}/" \
      "$DAEMON_CONFIG" >"$config_temp"
  else
    sed "1a\\  \"live-restore\": ${desired}," \
      "$DAEMON_CONFIG" >"$config_temp"
  fi

  "${INSTALL_DIR}/dockerd" --validate \
    --config-file "$config_temp" >/dev/null
  install -m 0644 "$config_temp" "$DAEMON_CONFIG"
  record_hash "daemon-config" "$DAEMON_CONFIG"
  if systemctl reload docker.service; then
    log INFO "已在线切换 Live Restore: ${desired}"
    return 0
  fi

  log WARN "Docker 拒绝在线切换 Live Restore"
  return 1
}

prepare_running_daemon_for_live_restore() {
  local service_temp
  local prepared=1
  local reported=""

  (( LIVE_RESTORE == 1 && HAD_STATE == 1 )) || return 0
  systemctl is-active --quiet docker.service || return 0
  ensure_work_dir

  if managed_file_matches "docker-service" "$SERVICE_FILE"; then
    service_temp="${WORK_DIR}/docker-live-restore.service"
    create_service_file "$service_temp"
    install_managed_file "$service_temp" "$SERVICE_FILE" \
      "docker-service" 0644 1
    systemctl daemon-reload
  else
    log WARN "docker.service 已被修改，无法安全地预配置 KillMode=process"
    prepared=0
  fi

  apply_running_live_restore true || prepared=0
  if reported="$("${INSTALL_DIR}/docker" info \
    --format '{{.LiveRestoreEnabled}}' 2>/dev/null)" &&
    [[ "$reported" == "true" ]]; then
    log INFO "运行中的 Docker 已启用 Live Restore"
  else
    prepared=0
  fi

  if (( prepared == 0 )); then
    log WARN "本次服务重启仍可能中断容器；后续升级将使用 Live Restore"
  fi
}

prepare_daemon_for_full_shutdown() {
  local containers=()
  local container_output=""

  (( LIVE_RESTORE == 1 )) || return 0
  systemctl is-active --quiet docker.service || return 0
  if apply_running_live_restore false; then
    return 0
  fi

  log WARN "无法关闭 Live Restore，将先主动停止运行中的容器"
  container_output="$("${INSTALL_DIR}/docker" ps -q)" ||
    die "无法列出运行中的容器，已取消卸载"
  if [[ -n "$container_output" ]]; then
    mapfile -t containers <<<"$container_output"
    "${INSTALL_DIR}/docker" stop "${containers[@]}"
  fi
}

install_binaries() {
  local docker_archive="${DOWNLOAD_DIR}/${DOCKER_ARCHIVE_NAME}"
  local compose_file="${DOWNLOAD_DIR}/${COMPOSE_ASSET}-${COMPOSE_VERSION}"
  local buildx_file="${DOWNLOAD_DIR}/${BUILDX_ASSET}"
  local binary

  ensure_work_dir
  tar -xzf "$docker_archive" -C "$WORK_DIR"
  [[ -x "${WORK_DIR}/docker/docker" ]] || die "压缩包中缺少 docker"
  [[ -x "${WORK_DIR}/docker/dockerd" ]] || die "压缩包中缺少 dockerd"
  [[ -x "${WORK_DIR}/docker/docker-proxy" ]] ||
    die "压缩包中缺少 docker-proxy"

  install -d -m 0755 "$INSTALL_DIR" "${INSTALL_DIR}/cli-plugins"
  for binary in "${WORK_DIR}"/docker/*; do
    [[ -f "$binary" ]] || continue
    install -m 0755 "$binary" "${INSTALL_DIR}/${binary##*/}"
  done
  install -m 0755 "$compose_file" \
    "${INSTALL_DIR}/cli-plugins/docker-compose"
  install -m 0755 "$buildx_file" \
    "${INSTALL_DIR}/cli-plugins/docker-buildx"

  cat >"${INSTALL_DIR}/.docker-static-installer" <<EOF
docker=${DOCKER_VERSION}
compose=${COMPOSE_VERSION}
buildx=${BUILDX_VERSION}
EOF
}

configure_target_user() {
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    log WARN "未指定普通用户，跳过加入 docker 组；可设置 TARGET_USER"
    return 0
  fi

  getent passwd "$TARGET_USER" >/dev/null ||
    die "TARGET_USER 不存在: ${TARGET_USER}"
  getent group docker >/dev/null || groupadd --system docker
  usermod -aG docker "$TARGET_USER"
  log INFO "已将 ${TARGET_USER} 加入 docker 组"
}

install_docker() {
  local daemon_temp
  local service_temp
  local completion_temp
  local was_active=0
  local was_enabled=0

  verify_downloads
  [[ -f "${STATE_DIR}/owner" ]] && HAD_STATE=1
  find_install_conflicts

  if systemctl is-active --quiet docker.service; then
    was_active=1
  fi
  if systemctl is-enabled --quiet docker.service 2>/dev/null; then
    was_enabled=1
  fi

  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  if (( HAD_STATE == 0 )); then
    printf '%s\n' "docker-static-installer" >"${STATE_DIR}/owner"
    if (( PRIOR_MANAGED == 0 )); then
      (( was_active == 1 )) && : >"${STATE_DIR}/previous-service-active"
      (( was_enabled == 1 )) && : >"${STATE_DIR}/previous-service-enabled"
    fi
  fi

  if (( was_active == 1 )); then
    prepare_running_daemon_for_live_restore
    log INFO "停止现有 Docker 服务"
    systemctl stop docker.service
  fi

  log INFO "安装 Docker ${DOCKER_VERSION}"
  install_binaries
  install -d -m 0755 "$PLUGIN_DIR" "$(dirname "$DOCKER_LINK")"
  install_managed_link "${INSTALL_DIR}/docker" "$DOCKER_LINK" "docker-link"
  install_managed_link "${INSTALL_DIR}/cli-plugins/docker-compose" \
    "${PLUGIN_DIR}/docker-compose" "docker-compose"
  install_managed_link "${INSTALL_DIR}/cli-plugins/docker-buildx" \
    "${PLUGIN_DIR}/docker-buildx" "docker-buildx"

  install -d -m 0711 "$DATA_ROOT"
  install -d -m 0755 /etc/docker

  daemon_temp="${WORK_DIR}/daemon.json"
  service_temp="${WORK_DIR}/docker.service"
  completion_temp="${WORK_DIR}/docker-completion.bash"
  create_daemon_config "$daemon_temp"
  "${INSTALL_DIR}/dockerd" --validate --config-file "$daemon_temp" >/dev/null
  create_service_file "$service_temp"

  # 旧版脚本无法证明 daemon.json 未被用户修改，因此首次迁移时仍先备份。
  install_managed_file "$daemon_temp" "$DAEMON_CONFIG" \
    "daemon-config" 0644 0
  install_managed_file "$service_temp" "$SERVICE_FILE" \
    "docker-service" 0644 1

  if "${INSTALL_DIR}/docker" completion bash >"$completion_temp"; then
    install_managed_file "$completion_temp" "$COMPLETION_FILE" \
      "docker-completion" 0644
  else
    log WARN "无法生成 Bash 补全文件，已跳过"
  fi

  configure_selinux
  configure_target_user

  cat >"${STATE_DIR}/versions" <<EOF
DOCKER_VERSION=${DOCKER_VERSION}
COMPOSE_VERSION=${COMPOSE_VERSION}
BUILDX_VERSION=${BUILDX_VERSION}
DOWNLOAD_DIR=${DOWNLOAD_DIR}
INSTALL_DIR=${INSTALL_DIR}
PLUGIN_DIR=${PLUGIN_DIR}
DOCKER_LINK=${DOCKER_LINK}
DATA_ROOT=${DATA_ROOT}
DISABLE_SELINUX=${DISABLE_SELINUX}
ALLOW_FORWARD_ALL=${ALLOW_FORWARD_ALL}
LIVE_RESTORE=${LIVE_RESTORE}
AUTO_INSTALL_DEPENDENCIES=${AUTO_INSTALL_DEPENDENCIES}
EOF

  systemctl daemon-reload
  systemctl enable docker.service
  systemctl reset-failed docker.service 2>/dev/null || true
  if ! systemctl restart docker.service; then
    log ERROR "Docker 服务启动命令失败，服务状态如下："
    systemctl status docker.service --no-pager --full >&2 || true
    log ERROR "Docker 服务最近 100 行日志如下："
    journalctl -u docker.service --no-pager -n 100 >&2 || true
    die "Docker 启动失败，请查看上方日志中的第一条 dockerd 错误"
  fi

  local attempt
  for attempt in {1..10}; do
    systemctl is-active --quiet docker.service && break
    log INFO "等待 Docker 启动 (${attempt}/10)"
    sleep 1
  done

  if ! systemctl is-active --quiet docker.service; then
    log ERROR "Docker 启动失败，最近日志如下："
    systemctl status docker.service --no-pager --full >&2 || true
    journalctl -u docker.service --no-pager -n 100 >&2 || true
    die "请根据日志修复后重试"
  fi

  if (( ALLOW_FORWARD_ALL == 1 )) &&
     command -v iptables >/dev/null 2>&1 &&
     ! iptables -w 5 -C FORWARD -s 0.0.0.0/0 -j ACCEPT 2>/dev/null; then
    log WARN "Docker 已启动，但全局 FORWARD ACCEPT 规则添加失败"
  fi

  log INFO "Docker 安装成功"
  log INFO "$("${INSTALL_DIR}/docker" --version)"
  log INFO "$("${INSTALL_DIR}/docker" compose version)"
  log INFO "$("${INSTALL_DIR}/docker" buildx version)"
  log INFO "数据目录: ${DATA_ROOT}"
  if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    log INFO "重新登录后，${TARGET_USER} 的 docker 组权限才会生效"
  fi
}

upgrade_docker() {
  if [[ ! -f "${STATE_DIR}/owner" ]] &&
     [[ ! -f "${INSTALL_DIR}/.docker-static-installer" ]] &&
     ! is_managed_service; then
    die "未检测到本脚本安装的 Docker；首次安装请使用 --all"
  fi

  discover_latest_versions
  log INFO "最新稳定版: Docker ${DOCKER_VERSION}, Compose ${COMPOSE_VERSION}, Buildx ${BUILDX_VERSION}"
  if (( LIVE_RESTORE == 1 )); then
    log WARN "Live Restore 可降低停机，但跨主版本或次版本升级仍可能中断容器"
  fi
  confirm "停止 Docker 服务并升级到上述版本？"
  download_components
  install_docker
}

remove_managed_file() {
  local destination="$1"
  local name="$2"

  path_exists "$destination" || return 0
  if managed_file_matches "$name" "$destination"; then
    rm -f -- "$destination"
    return 0
  fi

  log WARN "${destination} 已被修改，为避免丢失内容而保留"
  return 1
}

remove_managed_link() {
  local destination="$1"
  local target="$2"

  path_exists "$destination" || return 0
  if is_link_to "$destination" "$target"; then
    rm -f -- "$destination"
    return 0
  fi

  log WARN "${destination} 不是本脚本创建的链接，已保留"
  return 1
}

restore_backup() {
  local destination="$1"
  local name="$2"
  local backup="${BACKUP_DIR}/${name}"

  path_exists "$backup" || return 0
  if path_exists "$destination"; then
    log WARN "无法恢复 ${backup}：目标 ${destination} 已存在"
    return 1
  fi

  install -d -m 0755 "$(dirname "$destination")"
  mv -- "$backup" "$destination"
  log INFO "已恢复原文件: ${destination}"
}

remove_installed_binaries() {
  local legacy_managed="$1"
  local binary

  if [[ -f "${INSTALL_DIR}/.docker-static-installer" ||
        "$legacy_managed" -eq 1 ]]; then
    for binary in \
      containerd containerd-shim-runc-v2 ctr docker docker-init \
      docker-proxy dockerd runc; do
      rm -f -- "${INSTALL_DIR}/${binary}"
    done
    rm -f -- \
      "${INSTALL_DIR}/cli-plugins/docker-compose" \
      "${INSTALL_DIR}/cli-plugins/docker-buildx" \
      "${INSTALL_DIR}/.docker-static-installer"
    rmdir "${INSTALL_DIR}/cli-plugins" 2>/dev/null || true
    rmdir "$INSTALL_DIR" 2>/dev/null || true
  fi
}

cleanup_state() {
  if [[ -d "$BACKUP_DIR" ]] &&
     [[ -n "$(find "$BACKUP_DIR" -mindepth 1 -print -quit)" ]]; then
    log WARN "仍有未恢复的备份，安装状态已保留在 ${STATE_DIR}"
    return 0
  fi

  rm -f -- \
    "${STATE_DIR}/owner" \
    "${STATE_DIR}/versions" \
    "${STATE_DIR}/previous-service-active" \
    "${STATE_DIR}/previous-service-enabled" \
    "${STATE_DIR}/forward-rule-added" \
    "${STATE_DIR}/selinux-config-changed" \
    "${STATE_DIR}/daemon-config.sha256" \
    "${STATE_DIR}/docker-service.sha256" \
    "${STATE_DIR}/docker-completion.sha256" \
    "${STATE_DIR}/selinux-config.sha256"

  rmdir "$BACKUP_DIR" 2>/dev/null || true
  rmdir "$STATE_DIR" 2>/dev/null || true
}

uninstall_docker() {
  local legacy_managed=0
  local service_safe_to_remove_binaries=1
  local restart_previous=0
  local enable_previous=0
  local preserved_managed_file=0

  is_managed_service && legacy_managed=1
  [[ -f "${STATE_DIR}/previous-service-active" ]] && restart_previous=1
  [[ -f "${STATE_DIR}/previous-service-enabled" ]] && enable_previous=1

  if [[ ! -f "${STATE_DIR}/owner" && "$legacy_managed" -eq 0 &&
        ! -f "${INSTALL_DIR}/.docker-static-installer" ]]; then
    log WARN "未检测到由本脚本管理的 Docker 安装"
    return 0
  fi

  confirm "卸载本脚本安装的 Docker？数据目录将保留"

  if is_managed_service &&
     systemctl is-active --quiet docker.service; then
    prepare_daemon_for_full_shutdown
    log INFO "停止 Docker 服务"
    systemctl stop docker.service
  fi
  if is_managed_service; then
    systemctl disable docker.service 2>/dev/null || true
  fi

  if [[ -f "${STATE_DIR}/docker-service.sha256" ]]; then
    remove_managed_file "$SERVICE_FILE" "docker-service" ||
      service_safe_to_remove_binaries=0
  elif is_managed_service; then
    rm -f -- "$SERVICE_FILE"
  fi

  if (( service_safe_to_remove_binaries == 1 )); then
    if [[ ! -f "${STATE_DIR}/owner" && "$legacy_managed" -eq 1 ]]; then
      rm -f -- \
        "${PLUGIN_DIR}/docker-compose" \
        "${PLUGIN_DIR}/docker-buildx"
    fi
    remove_managed_link "$DOCKER_LINK" "${INSTALL_DIR}/docker" || true
    remove_managed_link "${PLUGIN_DIR}/docker-compose" \
      "${INSTALL_DIR}/cli-plugins/docker-compose" || true
    remove_managed_link "${PLUGIN_DIR}/docker-buildx" \
      "${INSTALL_DIR}/cli-plugins/docker-buildx" || true
    remove_installed_binaries "$legacy_managed"
  else
    log WARN "服务文件仍可能引用 ${INSTALL_DIR}，因此保留二进制文件"
  fi

  if [[ -f "${STATE_DIR}/daemon-config.sha256" ]]; then
    remove_managed_file "$DAEMON_CONFIG" "daemon-config" ||
      preserved_managed_file=1
  fi
  if [[ -f "${STATE_DIR}/docker-completion.sha256" ]]; then
    remove_managed_file "$COMPLETION_FILE" "docker-completion" ||
      preserved_managed_file=1
  fi
  if [[ -f "${STATE_DIR}/selinux-config-changed" ]]; then
    if remove_managed_file /etc/selinux/config "selinux-config"; then
      restore_backup /etc/selinux/config "selinux-config" || true
      log WARN "已恢复原 SELinux 配置，重启后生效"
    else
      preserved_managed_file=1
    fi
  fi

  if [[ -f "${STATE_DIR}/forward-rule-added" ]]; then
    if command -v iptables >/dev/null 2>&1; then
      iptables -D FORWARD -s 0.0.0.0/0 -j ACCEPT 2>/dev/null || true
    fi
    rm -f -- "${STATE_DIR}/forward-rule-added"
  fi

  # 清理由旧版脚本创建且内容未改动的补全文件。
  if [[ -f /etc/profile.d/docker-completion.sh ]] &&
     grep -Fxq 'source <(docker completion bash)' \
       /etc/profile.d/docker-completion.sh; then
    rm -f -- /etc/profile.d/docker-completion.sh
  fi

  restore_backup "$DOCKER_LINK" "docker-link" || true
  restore_backup "${PLUGIN_DIR}/docker-compose" "docker-compose" || true
  restore_backup "${PLUGIN_DIR}/docker-buildx" "docker-buildx" || true
  restore_backup "$DAEMON_CONFIG" "daemon-config" || true
  restore_backup "$COMPLETION_FILE" "docker-completion" || true
  restore_backup "$SERVICE_FILE" "docker-service" || true

  systemctl daemon-reload
  if (( enable_previous == 1 )); then
    systemctl enable docker.service
  fi
  if (( restart_previous == 1 )); then
    systemctl start docker.service
  fi

  if (( service_safe_to_remove_binaries == 1 &&
        preserved_managed_file == 0 )); then
    cleanup_state
  else
    log WARN "仍有被修改的托管文件，安装状态已保留在 ${STATE_DIR}"
  fi
  log INFO "Docker 卸载完成"
  log WARN "数据目录未删除: ${DATA_ROOT}"
  log INFO "下载缓存未删除: ${DOWNLOAD_DIR}"
  log INFO "docker 组及用户组成员关系未修改"
}

main() {
  init_colors
  parse_args "$@"
  if [[ "$ACTION" == "--uninstall" || "$ACTION" == "--upgrade" ]]; then
    load_installed_settings
  fi
  normalize_versions
  validate_settings
  detect_platform

  case "$ACTION" in
    --download)
      check_download_requirements
      download_components
      ;;
    --install)
      check_install_requirements
      install_docker
      ;;
    --all)
      check_download_requirements
      check_install_requirements
      download_components
      install_docker
      ;;
    --upgrade)
      check_download_requirements
      check_install_requirements
      check_upgrade_requirements
      upgrade_docker
      ;;
    --uninstall)
      check_install_requirements 0
      uninstall_docker
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
