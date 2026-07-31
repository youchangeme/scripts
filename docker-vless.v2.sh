#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Xray (VLESS + REALITY) 一键安装脚本  v2
# 自动完成：环境预检、BBR 加速、生成密钥、部署 Docker 容器
#
# 内置保护：
#   - 失败自动回滚（配置还原 + 拉起原服务），重跑出错不会把你的代理搞下线
#   - 阻断 BitTorrent 出站，避免因 BT 流量被 VPS 服务商销号
#
# 用法:
#   ./docker-vless.v2.sh                 # 安装（已安装则复用原有凭据）
#   ./docker-vless.v2.sh --regenerate    # 强制重新生成 UUID / 密钥（旧客户端全部失效）
#   ./docker-vless.v2.sh --port 8443     # 自定义监听端口
#   ./docker-vless.v2.sh --dest www.apple.com
#   ./docker-vless.v2.sh --name 香港01   # 客户端里显示的节点名
#   ./docker-vless.v2.sh --allow-cidr "192.168.192.0/24,10.21.0.0/16"
#                                        # 自定义放行直连的内网段（内网穿透，见下）
#   ./docker-vless.v2.sh --allow-cidr "" # 不放行任何内网段，恢复全阻断
#   ./docker-vless.v2.sh --update        # 升级 Xray 内核（自测不过自动回滚旧版本）
#   ./docker-vless.v2.sh --no-selftest   # 跳过部署后的连通性自测
#   ./docker-vless.v2.sh --uninstall     # 卸载（删容器 + 删工作目录，需确认）
#   ./docker-vless.v2.sh --uninstall -y  # 非交互卸载
#
# 镜像版本策略：首次安装时把 digest 锁进 state.env，之后重跑一律沿用同一版本，
# 只有 --update / --image 才会变更。避免"改个节点名顺带把内核换了"。
#
# 内网穿透（ZeroTier 跳板机模式）：
#   Xray 默认阻断发往私网地址的代理流量（geoip:private，防 SSRF），但会对
#   PRIVATE_ALLOW_CIDRS 里列出的网段放行直连。让本机加入 ZeroTier 后，
#   手机/电脑只开一个代理客户端就能经本机访问内网 —— 尤其 iOS 同时只允许
#   一个 VPN，Shadowrocket 和 ZeroTier 无法共存，用本机当跳板即可绕开。
#   流量路径: 客户端 →(VLESS)→ 本机 →(ZeroTier 路由)→ 内网设备
#
#   服务器侧一次性准备（本脚本不代劳，避免误碰你的 ZeroTier 账户）:
#     curl -s https://install.zerotier.com | sudo bash
#     sudo zerotier-cli join <网络ID>    # 然后到 ZeroTier 控制台授权本节点
#   客户端侧配置（含 Shadowrocket 配置片段）会随部署写入 client-info.txt。
#   
# 代理局域网设备

#
# sysctl -w net.ipv4.ip_forward=1

# PHY_IFACE=eth0; 
# ZT_IFACE=zt7nnig26
#

# 执行 iptables 规则
# sudo iptables -t nat -A POSTROUTING -o $PHY_IFACE -j MASQUERADE
# sudo iptables -A FORWARD -i $PHY_IFACE -o $ZT_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
# sudo iptables -A FORWARD -i $ZT_IFACE -o $PHY_IFACE -j ACCEPT

# 产物（均为 600 权限，含完整凭据，注意分发方式）:
#   $WORKDIR/client-info.txt        人读的参数汇总
#   $WORKDIR/subscribe/links.txt    明文 vless:// 链接
#   $WORKDIR/subscribe/v2ray.txt    base64 订阅文件（v2rayN / v2rayNG / Shadowrocket 等）
#
# 可用环境变量: WORKDIR / XRAY_IMAGE / DEST_SITE / DEST_PORT / LISTEN_PORT / NODE_NAME
#              / PRIVATE_ALLOW_CIDRS
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()  { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

WORKDIR="${WORKDIR:-$HOME/.xray-reality}"
DEST_SITE="${DEST_SITE:-learn.microsoft.com}"
DEST_PORT="${DEST_PORT:-443}"
LISTEN_PORT="${LISTEN_PORT:-443}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
CONTAINER_NAME="xray_official"
SELFTEST_NAME="xray_selftest"
NODE_NAME="${NODE_NAME:-}"
# 内网穿透放行的网段（空格或逗号分隔）。默认值对应本部署的 ZeroTier 环境；
# 用 ${VAR-default} 而不是 :- ，让显式置空（PRIVATE_ALLOW_CIDRS=""）能表达"全阻断"
PRIVATE_ALLOW_CIDRS="${PRIVATE_ALLOW_CIDRS-192.168.192.0/24 10.21.0.0/16 192.168.20.0/24}"
FORCE_REGEN=0
DO_UNINSTALL=0
DO_SELFTEST=1
DO_UPDATE=0
IMAGE_OVERRIDE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --regenerate)  FORCE_REGEN=1; shift ;;
        --uninstall)   DO_UNINSTALL=1; shift ;;
        --update)      DO_UPDATE=1; shift ;;
        --no-selftest) DO_SELFTEST=0; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        --port)        LISTEN_PORT="${2:?--port 需要参数}"; shift 2 ;;
        --dest)        DEST_SITE="${2:?--dest 需要参数}"; shift 2 ;;
        --image)       XRAY_IMAGE="${2:?--image 需要参数}"; IMAGE_OVERRIDE=1; shift 2 ;;
        --name)        NODE_NAME="${2:?--name 需要参数}"; shift 2 ;;
        --allow-cidr)  PRIVATE_ALLOW_CIDRS="${2?--allow-cidr 需要参数}"; shift 2 ;;
        # 打印头部两条分隔线之间的说明，不再写死行号（header 变长也不会漏）
        -h|--help)     awk '/^# =+$/{n++} {if(n)print} n==2{exit}' "$0"; exit 0 ;;
        *)             err "未知参数: $1（--help 查看用法）" ;;
    esac
done

# --allow-cidr / PRIVATE_ALLOW_CIDRS 尽早校验：这里报错不会碰到正在运行的服务
PRIVATE_ALLOW_CIDRS=$(printf '%s' "$PRIVATE_ALLOW_CIDRS" | tr ',' ' ')
for c in $PRIVATE_ALLOW_CIDRS; do
    printf '%s' "$c" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
        || err "无效的内网段 CIDR: $c（来自 --allow-cidr 或 PRIVATE_ALLOW_CIDRS）"
done

# -----------------------------------------------------------
# 并发保护：两个实例同时跑会互相踩快照和 state，可能把凭据搞坏
# （典型场景：cron 定时重跑撞上手动执行）
# -----------------------------------------------------------
if command -v flock > /dev/null 2>&1; then
    # 按 WORKDIR 取锁，不同部署互不阻塞；cksum 是 POSIX，busybox/GNU/BSD 都有
    LOCK_FILE="/tmp/.xray-reality-$(printf '%s' "$WORKDIR" | cksum | cut -d' ' -f1).lock"
    exec 9> "$LOCK_FILE" || err "无法创建锁文件 $LOCK_FILE"
    flock -n 9 || err "另一个实例正在操作 $WORKDIR，请等它结束（锁文件: $LOCK_FILE）"
else
    warn "未找到 flock，跳过并发保护；请勿同时运行多个实例"
fi

# 破坏性操作前确认；非交互环境下拒绝盲目执行，必须显式 --yes
confirm() {
    local ans
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ ! -t 0 ]; then
        err "该操作需要确认，但当前不是交互终端。确认无误请加 --yes"
    fi
    printf '%s [y/N] ' "$1" >&2
    read -r ans
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# 节点名要进分享链接的 fragment，非 ASCII（比如中文）必须逐字节百分号编码。
# 这里刻意不用 "'$c" 取字符值：bash 在 UTF-8 locale 下返回的是宽字符码点而非字节，
# 会把 香 编成 %DFE9%DFA6%DF99 这种垃圾（LC_ALL=C 也救不回来，字符串早已解析完毕）。
# 走 od 逐字节读是唯一可靠的做法。
urlencode() {
    printf '%s' "$1" | od -An -tx1 -v | tr -s ' ' '\n' | sed '/^$/d' | tr 'a-f' 'A-F' \
    | while read -r h; do
        case "$h" in
            # RFC 3986 unreserved: A-Z a-z 0-9 - . _ ~ 原样保留，其余转义
            2D|2E|5F|7E|3[0-9]|4[1-9]|4[A-F]|5[0-9]|5A|6[1-9]|6[A-F]|7[0-9]|7A)
                printf '%b' "\\x$h" ;;
            *) printf '%%%s' "$h" ;;
        esac
    done
}

# -----------------------------------------------------------
# 0. 环境预检
# -----------------------------------------------------------
log "检查运行环境..."

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo > /dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""
    warn "当前非 root 且未安装 sudo，内核参数调优将跳过"
fi

command -v docker > /dev/null 2>&1 || err "未检测到 Docker，请先安装 Docker"
docker info > /dev/null 2>&1 || err "Docker 守护进程未运行或当前用户无权限（尝试将用户加入 docker 组）"

if docker compose version > /dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose > /dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    err "未检测到 Docker Compose，请先安装"
fi

COMPOSE_FILE="$WORKDIR/docker-compose.yaml"
compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-directory "$WORKDIR" "$@"; }

# -----------------------------------------------------------
# 卸载（必须在回滚机制之前处理：卸载本身不需要也不应该注册回滚）
# -----------------------------------------------------------
# rm -rf 一个来自环境变量的路径风险太大，先确认它确实是本脚本建的目录
safe_workdir() {
    [ -n "$WORKDIR" ] && [ "$WORKDIR" != "/" ] && [ "$WORKDIR" != "$HOME" ] && [ -d "$WORKDIR" ] || return 1
    [ -f "$WORKDIR/state.env" ] || [ -f "$COMPOSE_FILE" ] || [ -f "$WORKDIR/config/config.json" ]
}

if [ "$DO_UNINSTALL" -eq 1 ]; then
    if [ ! -d "$WORKDIR" ] && ! docker ps -aq -f "name=^${CONTAINER_NAME}$" | grep -q .; then
        log "未检测到已安装的部署（$WORKDIR 不存在，也没有 $CONTAINER_NAME 容器）"
        exit 0
    fi

    echo "  即将执行:" >&2
    echo "    1) 停止并删除容器 $CONTAINER_NAME" >&2
    echo "    2) 删除目录 $WORKDIR" >&2
    echo "  会被保留:" >&2
    echo "    - BBR 内核参数 /etc/sysctl.d/99-bbr.conf（系统级优化，一般无需回退）" >&2
    echo "    - Docker 镜像 $XRAY_IMAGE" >&2
    if [ -f "$WORKDIR/client-info.txt" ]; then
        warn "REALITY 私钥 / UUID / 订阅文件将被永久删除且无法恢复"
        warn "需要留档的话先备份: $WORKDIR/client-info.txt"
    fi

    confirm "确认卸载？" || { log "已取消，未做任何改动"; exit 0; }

    [ -f "$COMPOSE_FILE" ] && compose down --remove-orphans > /dev/null 2>&1
    docker rm -f "$CONTAINER_NAME" "$SELFTEST_NAME" > /dev/null 2>&1 || true
    log "容器已停止并删除"

    if safe_workdir; then
        rm -rf "$WORKDIR"
        log "已删除 $WORKDIR"
    else
        warn "$WORKDIR 看起来不是本脚本创建的目录，出于安全未删除，请自行确认"
    fi

    log "卸载完成"
    echo "  如需一并回退 BBR: sudo rm -f /etc/sysctl.d/99-bbr.conf && sudo sysctl --system" >&2
    echo "  如需删除镜像:     docker image rm $XRAY_IMAGE" >&2
    exit 0
fi

# -----------------------------------------------------------
# 失败回滚保护
#   执行顺序是「停服务 → 覆写配置 → 校验 → 启动」，中间任何一步失败，
#   如果不做保护，结果就是服务已停 + 配置已被覆盖 + 脚本直接退出，不会自恢复。
#   所以在动任何文件之前先快照，并用 EXIT trap 在异常退出时还原 + 拉起原服务。
# -----------------------------------------------------------
umask 077
mkdir -p "$WORKDIR/config"
chmod 700 "$WORKDIR" "$WORKDIR/config"

STATE_FILE="$WORKDIR/state.env"
ROLLBACK_DIR="$WORKDIR/.rollback"
HAVE_SNAPSHOT=0
DEPLOY_OK=0
HAD_PREVIOUS=0
WAS_RUNNING=0
[ -f "$WORKDIR/config/config.json" ] && HAD_PREVIOUS=1
docker ps -q -f "name=^${CONTAINER_NAME}$" | grep -q . && WAS_RUNNING=1

snapshot() {
    rm -rf "$ROLLBACK_DIR"
    mkdir -p "$ROLLBACK_DIR"
    chmod 700 "$ROLLBACK_DIR"
    local f
    for f in "$STATE_FILE" "$COMPOSE_FILE" "$WORKDIR/config/config.json"; do
        if [ -f "$f" ]; then cp -p "$f" "$ROLLBACK_DIR/"; fi
    done
    HAVE_SNAPSHOT=1
}

rollback() {
    local rc=$?
    trap - EXIT
    [ "$DEPLOY_OK" -eq 1 ] && exit "$rc"
    [ "$HAVE_SNAPSHOT" -eq 1 ] || exit "$rc"

    if [ "$HAD_PREVIOUS" -eq 0 ]; then
        warn "全新安装失败，没有可回滚的旧版本；本次生成的文件保留在 $WORKDIR 供排查"
        exit "$rc"
    fi

    docker rm -f "$SELFTEST_NAME" > /dev/null 2>&1 || true
    warn "部署失败，正在回滚到上一版配置..."
    if [ -f "$ROLLBACK_DIR/state.env" ]; then
        cp -p "$ROLLBACK_DIR/state.env" "$STATE_FILE" || true
    fi
    if [ -f "$ROLLBACK_DIR/docker-compose.yaml" ]; then
        cp -p "$ROLLBACK_DIR/docker-compose.yaml" "$COMPOSE_FILE" || true
    fi
    if [ -f "$ROLLBACK_DIR/config.json" ]; then
        cp -p "$ROLLBACK_DIR/config.json" "$WORKDIR/config/config.json" || true
    fi
    log "配置已还原"

    # 只在原本就在运行时才拉起：否则可能是端口被别的服务占了，硬起会撞车
    if [ "$WAS_RUNNING" -eq 1 ]; then
        if compose up -d > /dev/null 2>&1; then
            log "原服务已重新拉起 ✓ 本次改动未生效"
        else
            warn "回滚后拉起失败，请手动检查: $WORKDIR"
        fi
    else
        log "原服务本就未运行，仅还原配置文件"
    fi
    exit "$rc"
}
trap rollback EXIT
snapshot

# 提前读入 state：镜像 digest 锁定信息在拉镜像之前就要用到
PINNED_IMAGE=""; PINNED_VERSION=""
UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""; SHORT_ID2=""
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
fi
PREV_PINNED="$PINNED_IMAGE"
PREV_VERSION="$PINNED_VERSION"
if [ "$FORCE_REGEN" -eq 1 ]; then
    [ -f "$STATE_FILE" ] && warn "--regenerate：将生成全新凭据，所有现有客户端配置都会失效"
    UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""; SHORT_ID2=""
fi

# 已有部署先停掉，既保证幂等，也把端口让出来给后面的占用检查
if [ -f "$COMPOSE_FILE" ] && docker ps -aq -f "name=^${CONTAINER_NAME}$" | grep -q .; then
    log "检测到已有部署，先停止旧容器..."
    compose down --remove-orphans > /dev/null 2>&1 || true
fi

# 端口占用检查：REALITY 用 host 网络，端口被 nginx/caddy 占住会导致容器反复重启
if command -v ss > /dev/null 2>&1 || command -v netstat > /dev/null 2>&1; then
    HAVE_PORT_TOOL=1
else
    HAVE_PORT_TOOL=0
    warn "未找到 ss / netstat，跳过端口占用检查（建议安装 iproute2）"
fi
port_holder() {
    [ "$HAVE_PORT_TOOL" -eq 1 ] || return 0
    if command -v ss > /dev/null 2>&1; then
        ss -lntH "sport = :$1" 2>/dev/null | head -1
    else
        netstat -lnt 2>/dev/null | awk -v p="[:.]$1\$" '$4 ~ p { print; exit }'
    fi
}
if [ -n "$(port_holder "$LISTEN_PORT")" ]; then
    warn "端口 $LISTEN_PORT 已被占用："
    warn "  $(port_holder "$LISTEN_PORT")"
    err "请先停止占用该端口的服务，或用 --port 指定其它端口"
fi

if [ "$LISTEN_PORT" != "443" ]; then
    warn "REALITY 监听非 443 端口存在被 GFW 主动探测识别的风险，建议使用 443"
fi

# REALITY 回落目标预检：必须支持 TLS 1.3 + HTTP/2，否则握手会以很隐晦的方式失败
if command -v openssl > /dev/null 2>&1; then
    log "检查 REALITY 目标站点 $DEST_SITE:$DEST_PORT ..."
    DEST_CHECK=$(echo | timeout 10 openssl s_client -connect "$DEST_SITE:$DEST_PORT" \
        -servername "$DEST_SITE" -tls1_3 -alpn h2 2>/dev/null || true)
    if echo "$DEST_CHECK" | grep -q "ALPN protocol: h2"; then
        log "目标站点支持 TLS1.3 + h2 ✓"
    else
        warn "目标站点未通过 TLS1.3 + h2 检查，REALITY 可能无法正常工作"
        warn "建议换一个支持 TLS1.3/h2 且未被墙的境外站点（--dest）"
    fi
else
    warn "未安装 openssl，跳过 REALITY 目标站点检查"
fi

# -----------------------------------------------------------
# 1. 开启 BBR 加速
# -----------------------------------------------------------
log "正在配置 BBR 加速..."

cc_now()   { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true; }
qdisc_now(){ sysctl -n net.core.default_qdisc 2>/dev/null || true; }

if [ "$(cc_now)" = "bbr" ] && [ "$(qdisc_now)" = "fq" ]; then
    log "BBR + fq 已开启，跳过"
elif [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    warn "无权限修改内核参数，跳过 BBR 配置"
else
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
        | $SUDO tee /etc/sysctl.d/99-bbr.conf > /dev/null
    $SUDO sysctl --system > /dev/null 2>&1 || warn "sysctl --system 执行失败（容器化 VPS 常见）"

    if [ "$(cc_now)" = "bbr" ]; then log "BBR ✓"; else warn "BBR 开启失败，检查内核 (需要 4.9+)"; fi
    if [ "$(qdisc_now)" = "fq" ]; then log "fq  ✓"; else warn "fq  开启失败"; fi
fi

# -----------------------------------------------------------
# 2. 拉取镜像并锁定 digest
#    :latest 会随上游滚动，配合 restart 策略可能在你不知情时换掉版本
# -----------------------------------------------------------
resolve_digest() {
    local ref
    ref=$(docker image inspect "$1" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null || true)
    [ -n "$ref" ] || ref="$1"
    printf '%s' "$ref"
}

if [ "$IMAGE_OVERRIDE" -eq 1 ]; then
    log "使用指定镜像 $XRAY_IMAGE ..."
    docker pull "$XRAY_IMAGE" > /dev/null || err "镜像拉取失败"
    IMAGE_REF=$(resolve_digest "$XRAY_IMAGE")
elif [ "$DO_UPDATE" -eq 1 ]; then
    log "检查上游最新版本 ..."
    docker pull "$XRAY_IMAGE" > /dev/null || err "镜像拉取失败"
    IMAGE_REF=$(resolve_digest "$XRAY_IMAGE")
elif [ -n "$PINNED_IMAGE" ]; then
    IMAGE_REF="$PINNED_IMAGE"
    if ! docker image inspect "$IMAGE_REF" > /dev/null 2>&1; then
        log "本地缺少已锁定的镜像，正在拉取 ..."
        docker pull "$IMAGE_REF" > /dev/null || err "已锁定的镜像拉取失败: $IMAGE_REF"
    fi
    log "沿用已锁定的镜像版本（--update 可升级到最新）"
else
    log "拉取镜像 $XRAY_IMAGE ..."
    docker pull "$XRAY_IMAGE" > /dev/null || err "镜像拉取失败"
    IMAGE_REF=$(resolve_digest "$XRAY_IMAGE")
fi

XRAY_VERSION=$(docker run --rm "$IMAGE_REF" version 2>/dev/null | head -1 || echo "unknown")
XRAY_VERSION=${XRAY_VERSION//\'/}   # 之后要写进单引号包裹的 state.env
log "版本: $XRAY_VERSION"

if [ "$DO_UPDATE" -eq 1 ] && [ -n "$PREV_PINNED" ]; then
    if [ "$PREV_PINNED" = "$IMAGE_REF" ]; then
        log "已是最新版本，无需升级"
        DO_UPDATE=0
    else
        log "升级: ${PREV_VERSION:-未知} → $XRAY_VERSION"
        if [ "$DO_SELFTEST" -eq 0 ]; then
            warn "已用 --no-selftest 关闭自测，升级将失去「不通就回滚」的保护"
        fi
    fi
fi

# -----------------------------------------------------------
# 3. 生成或复用凭据（state 已在前面读入，工作目录与快照也已就绪）
# -----------------------------------------------------------
if [ -n "$UUID" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ]; then
    log "复用已有凭据（如需重新生成请加 --regenerate）"
else
    [ -f "$STATE_FILE" ] && [ "$FORCE_REGEN" -eq 0 ] && warn "已有凭据不完整，将重新生成"

    log "正在生成 UUID 与 REALITY 密钥对..."
    UUID=$(docker run --rm "$IMAGE_REF" uuid) || err "UUID 生成失败"

    KEYS=$(docker run --rm "$IMAGE_REF" x25519 2>&1) || err "REALITY 密钥生成失败"
    # 兼容新旧输出格式：新版为 "PrivateKey:" / "Password (PublicKey):"，旧版为 "Private key:" / "Public key:"
    PRIVATE_KEY=$(printf '%s\n' "$KEYS" | sed -n -E 's/^[Pp]rivate ?[Kk]ey:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -1)
    PUBLIC_KEY=$(printf '%s\n' "$KEYS" | sed -n -E 's/^(Password \([Pp]ublic[Kk]ey\)|Public ?[Kk]ey|Password):[[:space:]]*([A-Za-z0-9_-]+).*/\2/p' | head -1)

    # 不做校验的话，上游改了输出格式会直接写出一份 privateKey 为空的配置
    if [ "${#PRIVATE_KEY}" -ne 43 ] || [ "${#PUBLIC_KEY}" -ne 43 ]; then
        warn "x25519 原始输出："
        printf '%s\n' "$KEYS" >&2
        err "密钥解析失败（上游输出格式可能已变更），请检查上面的原始输出"
    fi

fi

# shortId 单独处理：长短各一个便于灰度轮换（客户端用其中任意一个都能连），
# 且老版本 state.env 里没有 SHORT_ID2，这里顺带补上，不影响已分发的客户端
[ -n "$SHORT_ID" ]  || SHORT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')    # 不依赖 openssl
[ -n "$SHORT_ID2" ] || SHORT_ID2=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')

cat > "$STATE_FILE" <<EOF
UUID='$UUID'
PRIVATE_KEY='$PRIVATE_KEY'
PUBLIC_KEY='$PUBLIC_KEY'
SHORT_ID='$SHORT_ID'
SHORT_ID2='$SHORT_ID2'
PINNED_IMAGE='$IMAGE_REF'
PINNED_VERSION='$XRAY_VERSION'
EOF
chmod 600 "$STATE_FILE"

# 私钥不回显到终端：终端记录 / scrollback / CI 日志都会留痕
log "UUID:      $UUID"
log "PublicKey: $PUBLIC_KEY"
log "ShortId:   $SHORT_ID"

# -----------------------------------------------------------
# 4. 生成配置文件
# -----------------------------------------------------------
log "正在写入配置: $WORKDIR"

# 监听地址：:: 在 Linux 下是双栈（v4 也能进）。但如果内核禁用了 IPv6
# （ipv6.disable=1），bind :: 会直接失败，所以必须探测后再决定，不能写死。
if [ -f /proc/net/if_inet6 ]; then
    LISTEN_ADDR="::"
else
    LISTEN_ADDR="0.0.0.0"
    log "系统未启用 IPv6，入站仅监听 IPv4"
fi

# 内网穿透：给 PRIVATE_ALLOW_CIDRS 网段生成直连例外规则（原理与客户端配置见文件头）。
# 默认网段对应本部署的 ZeroTier 环境：
#   192.168.192.0/24  ZeroTier 虚拟网段
#   10.21.0.0/16      经网关 192.168.192.141 的物理内网（managed route）
#   192.168.20.0/24   经网关 192.168.192.170 的物理内网（managed route）
# 例外只精确到确实要访问的网段，其余私网地址仍被 geoip:private 阻断（防 SSRF）
ALLOW_IP_JSON=""
for c in $PRIVATE_ALLOW_CIDRS; do
    ALLOW_IP_JSON="${ALLOW_IP_JSON:+$ALLOW_IP_JSON, }\"$c\""
done
if [ -n "$ALLOW_IP_JSON" ]; then
    ALLOW_RULE="{ \"type\": \"field\", \"ip\": [$ALLOW_IP_JSON], \"outboundTag\": \"direct\" },"
else
    # 列表为空则整条规则不生成，避免写出 "ip": [""] 这种校验不过的配置
    ALLOW_RULE=""
fi

cat > "$WORKDIR/config/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": ["localhost", "1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4v6"
  },
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $LISTEN_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST_SITE:$DEST_PORT",
          "xver": 0,
          "serverNames": ["$DEST_SITE"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID", "$SHORT_ID2"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      $ALLOW_RULE
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
chmod 600 "$WORKDIR/config/config.json"

cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: $IMAGE_REF
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    network_mode: "host"
    # host 网络下无法用 sysctl 放开非特权端口，且镜像内二进制未设 file capability，
    # 故仍以 root 启动，但把权限收敛到只剩 NET_BIND_SERVICE
    user: "root:root"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    read_only: true
    volumes:
      - ./config:/usr/local/etc/xray:ro
    command: ["-c", "/usr/local/etc/xray/config.json"]
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# -----------------------------------------------------------
# 5. 启动前校验配置（避免容器起来后反复重启才发现问题）
# -----------------------------------------------------------
log "校验配置文件..."
if ! VALIDATE_OUT=$(docker run --rm --user 0:0 -v "$WORKDIR/config:/etc/xray-test:ro" \
        "$IMAGE_REF" run -test -c /etc/xray-test/config.json 2>&1); then
    printf '%s\n' "$VALIDATE_OUT" >&2
    err "配置校验未通过"
fi
log "配置校验通过 ✓"

# -----------------------------------------------------------
# 6. 启动并确认真的起来了
# -----------------------------------------------------------
log "正在启动 Xray..."
compose up -d

# 判定依据是「容器在跑 + 没重启过 + 内核打印了 started」，
# 端口探测只作为补充条件，缺少 ss/netstat 时不能因此判失败
HEALTHY=0
for _ in $(seq 1 15); do
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
    RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)
    if [ "$STATUS" = "running" ] && [ "$RESTARTS" -eq 0 ] \
       && docker logs "$CONTAINER_NAME" 2>&1 | grep -q "core: Xray .* started"; then
        HEALTHY=1
        break
    fi
    sleep 1
done

if [ "$HEALTHY" -eq 1 ] && [ "$HAVE_PORT_TOOL" -eq 1 ] && [ -z "$(port_holder "$LISTEN_PORT")" ]; then
    warn "Xray 已启动，但未探测到 $LISTEN_PORT 端口监听，请确认后自行核实"
fi

if [ "$HEALTHY" -eq 1 ]; then
    log "Xray 已成功运行 ✓"
else
    warn "容器状态异常 (status=${STATUS:-unknown}, restarts=${RESTARTS:-0})，最近日志："
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /' >&2 || true
    err "启动失败，请根据上面的日志排查"
fi

# 防火墙提示（只提示，不擅自改动规则）
if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw status 2>/dev/null | grep -q "$LISTEN_PORT" || \
        warn "ufw 已启用但似乎未放行 $LISTEN_PORT： sudo ufw allow $LISTEN_PORT/tcp"
fi
if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
    firewall-cmd --list-ports 2>/dev/null | grep -q "$LISTEN_PORT/tcp" || \
        warn "firewalld 已启用但似乎未放行 $LISTEN_PORT： sudo firewall-cmd --permanent --add-port=$LISTEN_PORT/tcp && sudo firewall-cmd --reload"
fi

# -----------------------------------------------------------
# 7. 连通性自测
#   起一个临时 Xray 客户端，用刚生成的凭据回连本机入站，再经它的 SOCKS 出口访问外网。
#   能验证：公私钥配对、shortId/SNI 匹配、REALITY 握手、vision 流控、服务端出站路由。
#   ⚠ 走的是回环，证明不了「公网可达」—— 那取决于防火墙/安全组，见上面的放行提示。
# -----------------------------------------------------------
selftest() {
    local port cfgdir code clientlog started=0 url
    command -v curl > /dev/null 2>&1 || { warn "未安装 curl，跳过连通性自测"; return 0; }

    port=0
    for _ in 1 2 3; do
        port=$((20000 + RANDOM % 30000))
        [ -z "$(port_holder "$port")" ] && break
    done

    cfgdir="$WORKDIR/.selftest"
    rm -rf "$cfgdir"; mkdir -p "$cfgdir"; chmod 700 "$cfgdir"
    cat > "$cfgdir/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": $port, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false } }
  ],
  "outbounds": [
    { "protocol": "vless", "tag": "proxy",
      "settings": { "vnext": [ { "address": "127.0.0.1", "port": $LISTEN_PORT,
        "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$DEST_SITE", "fingerprint": "chrome",
          "publicKey": "$PUBLIC_KEY", "shortId": "$SHORT_ID" } } }
  ]
}
EOF
    chmod 600 "$cfgdir/config.json"

    docker rm -f "$SELFTEST_NAME" > /dev/null 2>&1 || true
    if ! docker run -d --name "$SELFTEST_NAME" --network host --user 0:0 \
            --cap-drop ALL --security-opt no-new-privileges:true --read-only \
            -v "$cfgdir:/usr/local/etc/xray:ro" "$IMAGE_REF" \
            -c /usr/local/etc/xray/config.json > /dev/null 2>&1; then
        warn "自测客户端启动失败，跳过连通性自测"
        rm -rf "$cfgdir"
        return 0
    fi

    for _ in $(seq 1 10); do
        if docker logs "$SELFTEST_NAME" 2>&1 | grep -q "core: Xray .* started"; then started=1; break; fi
        sleep 1
    done

    code="000"
    if [ "$started" -eq 1 ]; then
        for url in "https://www.gstatic.com/generate_204" "https://cp.cloudflare.com/generate_204"; do
            # curl 失败时 -w 本身就会输出 000，不能再 `|| echo 000`，否则拼成 000000
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
                   --socks5-hostname "127.0.0.1:$port" "$url" 2>/dev/null) || true
            [ -n "$code" ] || code="000"
            [ "$code" = "204" ] && break
        done
    fi

    clientlog=$(docker logs --tail 8 "$SELFTEST_NAME" 2>&1 || true)
    docker rm -f "$SELFTEST_NAME" > /dev/null 2>&1 || true
    rm -rf "$cfgdir"

    if [ "$code" = "204" ]; then
        log "连通性自测通过 ✓（REALITY 握手 + 代理转发均正常）"
        return 0
    fi

    warn "连通性自测未通过 (HTTP=$code)，临时客户端日志："
    printf '%s\n' "$clientlog" | sed 's/^/    /' >&2
    warn "服务本身在运行，但经代理访问外网失败；常见原因：服务器出站受限 / DNS 异常 / 目标站点不可达"
    warn "自测有误判可能，因此保留当前部署未回滚。可用 --no-selftest 跳过本步骤"
    return 1
}

if [ "$DO_SELFTEST" -eq 1 ]; then
    log "正在做连通性自测..."
    # 普通部署：自测失败不回滚。误判会毁掉一个可用部署，代价高于漏判。
    # --update：自测失败则回滚。此时唯一的变量就是镜像版本，且回退代价很低
    #           （无非是停在旧版本），远低于让一个坏版本继续跑。
    if ! selftest && [ "$DO_UPDATE" -eq 1 ]; then
        err "升级后连通性自测未通过，回滚到升级前的版本"
    fi
fi

# -----------------------------------------------------------
# 8. 输出客户端连接信息
# -----------------------------------------------------------
get_server_ip() {
    local ip
    for u in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb"; do
        ip=$(curl -fsS4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || continue
        case "$ip" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s' "$ip"; return 0 ;;
        esac
    done
    return 1
}
SERVER_IP=$(get_server_ip || echo "")
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    warn "公网 IP 获取失败，请手动替换下面的 YOUR_SERVER_IP"
fi

[ -n "$NODE_NAME" ] || NODE_NAME="reality-${SERVER_IP}"
SHARE_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#$(urlencode "$NODE_NAME")"

# -----------------------------------------------------------
# 生成订阅文件
#   通用格式 = 「每行一条 vless:// 链接」整体做一次标准 base64，且必须单行不折行
#   多节点时只需往 links.txt 里多加几行再重新编码即可
# -----------------------------------------------------------
mkdir -p "$WORKDIR/subscribe"
chmod 700 "$WORKDIR/subscribe"

printf '%s\n' "$SHARE_LINK" > "$WORKDIR/subscribe/links.txt"
chmod 600 "$WORKDIR/subscribe/links.txt"

# base64 -w0 是 GNU coreutils 专有，改用 tr 删换行以兼容 busybox / BSD
base64 < "$WORKDIR/subscribe/links.txt" | tr -d '\r\n' > "$WORKDIR/subscribe/v2ray.txt"
chmod 600 "$WORKDIR/subscribe/v2ray.txt"

# 自校验：解回来必须和原链接一致，否则客户端导入会静默失败
# GNU/busybox 用 -d，BSD 用 -D
b64decode() { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }
if [ "$(b64decode < "$WORKDIR/subscribe/v2ray.txt")" = "$SHARE_LINK" ]; then
    log "订阅文件已生成并校验通过 ✓"
else
    warn "订阅文件 base64 自校验未通过，请手动检查 $WORKDIR/subscribe/"
fi

# 内网穿透使用说明：跟着实际放行的网段动态生成，随 client-info.txt 存档
if [ -n "$PRIVATE_ALLOW_CIDRS" ]; then
    SR_INCLUDED=$(printf '%s' "$PRIVATE_ALLOW_CIDRS" | tr ' ' ',')
    SR_RULES=""
    for c in $PRIVATE_ALLOW_CIDRS; do
        SR_RULES="${SR_RULES}         IP-CIDR,${c},PROXY,no-resolve"$'\n'
    done
    INTRANET_INFO=$(cat <<EOT

  内网穿透（客户端只开代理即可经本机访问以下网段）:
    放行网段: $PRIVATE_ALLOW_CIDRS
    前置条件: 本机已加入 ZeroTier 并被授权（zerotier-cli listnetworks 显示 OK）；
              managed route 后面的物理网段还要求对应网关在线
    Shadowrocket 要点（iOS 只能开一个 VPN，手机端无需装 ZeroTier）:
      1. [General] 保持默认 tun-excluded-routes 不动，加一行精确打洞
         （iOS 按最长前缀匹配，更精确的 included 会覆盖更宽的 excluded）:
         tun-included-routes = $SR_INCLUDED
      2. [General] skip-proxy 里覆盖上述网段的条目（如 10.0.0.0/8）要删掉
      3. [Rule] 以下规则置顶，必须排在所有 LAN/DIRECT 规则之前:
$SR_RULES    电脑端替代: ssh -J $(id -un)@$SERVER_IP <用户>@<内网IP>，或 ssh -D 1080 做 SOCKS5
    排查顺序: 先在本机 ping 内网 IP，再用手机经代理访问；不通先查 ZeroTier 授权与网关在线
EOT
)
else
    INTRANET_INFO="
  内网穿透: 未启用（全部私网地址阻断；--allow-cidr 可开启，见脚本头部说明）"
fi

INFO=$(cat <<EOF
============================================
  Xray (VLESS + REALITY) 部署完成
  部署时间: $(date '+%Y-%m-%d %H:%M:%S')
  内核版本: $XRAY_VERSION
============================================

  节点名:      $NODE_NAME
  协议:        vless
  地址:        $SERVER_IP
  端口:        $LISTEN_PORT
  流控:        xtls-rprx-vision
  传输:        tcp
  安全:        reality
  UUID:        $UUID
  公钥:        $PUBLIC_KEY
  ShortId:     $SHORT_ID
  SNI:         $DEST_SITE
  Fingerprint: chrome

  监听地址:    $LISTEN_ADDR $([ "$LISTEN_ADDR" = "::" ] && echo "(双栈)" || echo "(仅 IPv4)")
  备用 ShortId: $SHORT_ID2

  已启用的出站策略:
    - 内网地址 (geoip:private) 阻断${PRIVATE_ALLOW_CIDRS:+（例外直连放行: $PRIVATE_ALLOW_CIDRS）}
    - BitTorrent 阻断（防止因 BT 流量被服务商销号）
    - 出站优先 IPv4、失败回落 IPv6（规避 VPS 的 IPv6 半可用，同时不放弃 v6-only 目标）
    - 访问日志已关闭（不记录用户流量）
$INTRANET_INFO

  分享链接 (VLESS):
$SHARE_LINK

  订阅文件 (base64，v2rayN / v2rayNG / Shadowrocket 等通用):
    $WORKDIR/subscribe/v2ray.txt
  取回方式（在本地机器上执行）:
    scp $(id -un)@${SERVER_IP}:$WORKDIR/subscribe/v2ray.txt ./
  提示: 该文件含完整凭据，托管时务必走 HTTPS 并使用不可猜测的路径

  管理命令:
    cd $WORKDIR
    ${COMPOSE[*]} logs -f     # 查看日志
    ${COMPOSE[*]} restart     # 重启
    ${COMPOSE[*]} down        # 停止并移除
============================================
EOF
)

echo ""
echo "$INFO"

printf '%s\n' "$INFO" > "$WORKDIR/client-info.txt"
chmod 600 "$WORKDIR/client-info.txt"
log "客户端信息已保存到: $WORKDIR/client-info.txt"

# 走到这里才算部署成功，EXIT trap 据此决定是否回滚
DEPLOY_OK=1
rm -rf "$ROLLBACK_DIR"
