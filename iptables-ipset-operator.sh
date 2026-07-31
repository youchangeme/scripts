#!/usr/bin/env bash
#################################################
# iptables-ipset-operator.sh
# 管理 iptables/ip6tables 防火墙规则，支持白名单/受限端口模式
# 支持 IPv4 + IPv6 双栈
#################################################

set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/iptables_ipset_config.conf}"
LOG_FILE="${LOG_FILE:-/var/log/iptables-ipset-operator.txt}"
MD5_FILE="${MD5_FILE:-$SCRIPT_DIR/.iptables-ipset-config.md5}"
LOCK_FILE="${LOCK_FILE:-/var/run/iptables-ipset-operator.lock}"

TABLE="mangle"
PARENT_CHAIN="PREROUTING"
MAX_PORTS=15
IPSET_V4="whitelist_ipset_v4"
IPSET_V6="whitelist_ipset_v6"
COMMENT_TAG="managed_by_iptables-ipset-operator"

MODE=""
ACTION=""
DRY_RUN=0
FORCE=0
VERBOSE=1

#################################################
# 工具函数
#################################################

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

vlog() { if [ "$VERBOSE" = 1 ]; then log "$1"; fi; }

die() { log "错误: $1"; exit 1; }

# dry-run 包装：所有会改动系统状态的命令都必须经由此函数执行
run() {
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] $*"
        return 0
    fi
    "$@"
}

show_usage() {
    cat <<EOF
用法: $0 -m [whitelist|restricted] -a [setup|delete|verify|status]

  -m, --mode     模式: whitelist(白名单) | restricted(受限端口)
  -a, --action   动作: setup(应用) | delete(删除) | verify(校验并自动修复) | status(查看状态)
  -n, --dry-run  只打印将要执行的命令，不实际改动
  -f, --force    跳过 SSH 锁定保护（危险）
  -q, --quiet    精简输出（仅记录关键事件）
  -h, --help     显示帮助
EOF
    exit 1
}

check_prerequisites() {
    local c
    for c in iptables ip6tables ipset; do
        command -v "$c" >/dev/null 2>&1 || die "$c 命令不存在"
    done
    [ -f "$CONFIG_FILE" ] || die "配置文件不存在: $CONFIG_FILE"
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限运行"
}

# 防止 cron 定时校验与手动执行并发改动规则
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$LOCK_FILE" 2>/dev/null || return 0
    if ! flock -n 9; then
        log "另一个实例正在运行，跳过本次执行"
        exit 0
    fi
}

config_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$CONFIG_FILE" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$CONFIG_FILE"
    else
        # 无可用哈希工具时退化为「总是判定已变化」，宁可多重建也不要漏更新
        printf 'no-hash-tool-%s\n' "$(date +%s)"
    fi
}

record_config_md5() {
    if [ "$DRY_RUN" = 1 ]; then return 0; fi
    config_md5 >"$MD5_FILE" 2>/dev/null || true
}

config_changed() {
    local cur old
    cur="$(config_md5)"
    old="$(cat "$MD5_FILE" 2>/dev/null || true)"
    [ "$cur" != "$old" ]
}

chain_for_mode() {
    case "$1" in
        whitelist)  printf 'whitelist\n' ;;
        restricted) printf 'restricted_ports\n' ;;
        *)          die "未知模式: $1" ;;
    esac
}

family_label() {
    if [ "$1" = ip6tables ]; then printf 'v6\n'; else printf 'v4\n'; fi
}

#################################################
# 规则规格
#
# rule_specs 是全脚本唯一的规则来源：应用(setup)与校验(verify)都从它生成，
# 因此两者不可能产生分歧。输出每行格式为:
#   family|action|match-args
#     family     4 / 6 / *   适用协议族
#     action     RETURN / DROP
#     match-args 传给 iptables 的匹配参数，空表示链默认规则
# 行的先后顺序即链内自上而下的实际顺序。
#################################################

# 按 multiport 上限把端口列表切成若干组，每组一行
group_ports() {
    local ports_str="${1:-}"
    local -a ports=()
    read -ra ports <<<"$ports_str"
    if [ ${#ports[@]} -eq 0 ]; then return 0; fi

    local i=0 j group
    while [ $i -lt ${#ports[@]} ]; do
        group=""
        for ((j = 0; j < MAX_PORTS && i < ${#ports[@]}; j++, i++)); do
            if [ -n "$group" ]; then group+=","; fi
            group+="${ports[i]}"
        done
        printf '%s\n' "$group"
    done
}

rule_specs() {
    local mode="$1" g
    if [ "$mode" = whitelist ]; then
        # 已建立连接放在最前：命中率最高，可让绝大多数包尽早跳出该链
        printf '%s\n' "*|RETURN|-m conntrack --ctstate RELATED,ESTABLISHED"
        printf '%s\n' "4|RETURN|-m set --match-set $IPSET_V4 src"
        printf '%s\n' "6|RETURN|-m set --match-set $IPSET_V6 src"
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            printf '%s\n' "*|RETURN|-p tcp -m multiport --dports $g"
            printf '%s\n' "*|RETURN|-p udp -m multiport --dports $g"
        done < <(group_ports "${whitelist_ports:-}")
        printf '%s\n' "*|DROP|"
    else
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            printf '%s\n' "*|DROP|-p tcp -m multiport --dports $g"
            printf '%s\n' "*|DROP|-p udp -m multiport --dports $g"
        done < <(group_ports "${restricted_ports:-}")
        printf '%s\n' "*|RETURN|"
    fi
}

spec_applies() {
    local family="$1" cmd="$2"
    case "$family" in
        '*') return 0 ;;
        4)   [ "$cmd" = iptables ] ;;
        6)   [ "$cmd" = ip6tables ] ;;
        *)   return 1 ;;
    esac
}

# 把一条规格展开成完整的 iptables 参数数组，结果放在全局 RULE_ARGS
RULE_ARGS=()
build_rule_args() {
    local action="$1" match="$2"
    RULE_ARGS=()
    if [ -n "$match" ]; then read -ra RULE_ARGS <<<"$match"; fi
    RULE_ARGS+=(-m comment --comment "$COMMENT_TAG" -j "$action")
}

# 幂等判断用 iptables -C 交给内核做语义比对。
# 旧版用 `iptables -S | grep -Fx` 拼串比对，而 -S 会给 comment 加双引号，
# 拼出来的串永远匹配不上 —— 规则会重复累积、verify 永远失败。
rule_exists() {
    local cmd="$1" chain="$2"
    shift 2
    "$cmd" -t "$TABLE" -C "$chain" "$@" >/dev/null 2>&1
}

#################################################
# ipset 管理
#################################################

# 用临时集装载 + ipset swap 完成原子替换。
# 旧版直接 destroy 再 create，而被 iptables 规则引用的集是删不掉的，
# 失败还被静默吞掉，导致配置里删掉的网段实际仍然留在白名单里。
build_ipsets() {
    local family name tmpname net
    local -a nets=()

    if [ -n "${ALLOWED_NETWORKS+x}" ]; then nets+=("${ALLOWED_NETWORKS[@]}"); fi
    if [ -n "${ALLOWED_NETWORKS_V6+x}" ]; then nets+=("${ALLOWED_NETWORKS_V6[@]}"); fi

    for family in inet inet6; do
        if [ "$family" = inet ]; then name="$IPSET_V4"; else name="$IPSET_V6"; fi
        tmpname="${name}_tmp"

        ipset destroy "$tmpname" 2>/dev/null || true
        run ipset create "$tmpname" hash:net family "$family" hashsize 1024 maxelem 65536
        run ipset create "$name" hash:net family "$family" hashsize 1024 maxelem 65536 -exist

        local added=0
        for net in ${nets[@]+"${nets[@]}"}; do
            [ -n "$net" ] || continue
            if [ "$net" = localhost ]; then
                if [ "$family" = inet ]; then net="127.0.0.1/32"; else net="::1/128"; fi
            fi
            # 按地址族分流，配置写错位置也不会出错
            if [ "$family" = inet ] && [[ "$net" == *:* ]]; then continue; fi
            if [ "$family" = inet6 ] && [[ "$net" != *:* ]]; then continue; fi

            if [ "$DRY_RUN" = 1 ]; then
                added=$((added + 1))
                continue
            fi
            if ipset add "$tmpname" "$net" -exist 2>/dev/null; then
                added=$((added + 1))
            else
                log "警告: 网段无法加入 ipset($name)，已跳过: $net"
            fi
        done

        run ipset swap "$tmpname" "$name"
        run ipset destroy "$tmpname"
        vlog "ipset $name 已就绪 ($added 条网段)"
    done
}

ipset_exists() { ipset list -n 2>/dev/null | grep -qx -- "$1"; }

ipset_count() {
    ipset save "$1" 2>/dev/null | grep -c "^add " || true
}

#################################################
# 链管理
#################################################

# 把一组规则按 rule_specs 的顺序追加进指定链
populate_chain() {
    local cmd="$1" chain="$2" mode="$3"
    local spec rest family action match
    while IFS= read -r spec; do
        family="${spec%%|*}"
        rest="${spec#*|}"
        action="${rest%%|*}"
        match="${rest#*|}"
        spec_applies "$family" "$cmd" || continue
        build_rule_args "$action" "$match"
        run "$cmd" -t "$TABLE" -A "$chain" "${RULE_ARGS[@]}"
    done < <(rule_specs "$mode")
}

# 检查现有链是否与期望完全一致（含顺序无关的存在性 + 条数一致性）
# 返回 0 表示一致；VERBOSE=1 时逐条输出差异
check_rules() {
    local mode="$1"
    local chain
    chain="$(chain_for_mode "$mode")"
    local problems=0
    local cmd ver spec rest family action match expected actual

    for cmd in iptables ip6tables; do
        ver="$(family_label "$cmd")"

        if ! "$cmd" -t "$TABLE" -L "$chain" -n >/dev/null 2>&1; then
            vlog "✗ $ver: $chain 链不存在"
            problems=$((problems + 1))
            continue
        fi
        vlog "✓ $ver: $chain 链存在"

        if "$cmd" -t "$TABLE" -C "$PARENT_CHAIN" -j "$chain" >/dev/null 2>&1; then
            vlog "✓ $ver: $chain 已挂载到 $PARENT_CHAIN"
        else
            vlog "✗ $ver: $chain 未挂载到 $PARENT_CHAIN"
            problems=$((problems + 1))
        fi

        expected=0
        while IFS= read -r spec; do
            family="${spec%%|*}"
            rest="${spec#*|}"
            action="${rest%%|*}"
            match="${rest#*|}"
            spec_applies "$family" "$cmd" || continue
            expected=$((expected + 1))
            build_rule_args "$action" "$match"
            if ! rule_exists "$cmd" "$chain" "${RULE_ARGS[@]}"; then
                vlog "✗ $ver: 缺失规则: ${match:-[默认]} -j $action"
                problems=$((problems + 1))
            fi
        done < <(rule_specs "$mode")

        actual="$("$cmd" -t "$TABLE" -S "$chain" 2>/dev/null | grep -c -- "^-A $chain " || true)"
        actual="${actual:-0}"
        if [ "$actual" -gt "$expected" ]; then
            vlog "✗ $ver: 存在 $((actual - expected)) 条多余规则（期望 $expected，实际 $actual）"
            problems=$((problems + 1))
        elif [ "$actual" -eq "$expected" ]; then
            vlog "✓ $ver: 规则数量匹配 ($expected 条)"
        fi
    done

    if [ "$mode" = whitelist ]; then
        local s
        for s in "$IPSET_V4" "$IPSET_V6"; do
            if ipset_exists "$s"; then
                vlog "✓ ipset $s 存在 ($(ipset_count "$s") 条网段)"
            else
                vlog "✗ ipset $s 不存在"
                problems=$((problems + 1))
            fi
        done
    fi

    return "$problems"
}

#################################################
# SSH 锁定保护
#################################################

detect_ssh_port() {
    if [ -n "${SSH_CONNECTION:-}" ]; then
        awk '{print $4}' <<<"$SSH_CONNECTION"
        return 0
    fi
    if [ -r /etc/ssh/sshd_config ]; then
        awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config
    fi
}

# whitelist 模式最后一条是 DROP，配置不当会把当前 SSH 会话一起挡在门外。
# 必须在 ipset 构建完成之后调用，才能用 ipset test 判断来源 IP 是否已放行。
guard_ssh_lockout() {
    # 非 SSH 会话（本地控制台 / cron）不需要保护
    if [ -z "${SSH_CONNECTION:-}" ]; then return 0; fi
    if [ "$FORCE" = 1 ]; then
        log "警告: 已指定 --force，跳过 SSH 锁定检查"
        return 0
    fi

    local ssh_port p client_ip setname
    ssh_port="$(detect_ssh_port || true)"

    if [ -n "$ssh_port" ]; then
        for p in ${whitelist_ports:-}; do
            if [ "$p" = "$ssh_port" ]; then return 0; fi
        done
    fi

    client_ip="${SSH_CLIENT:-}"
    client_ip="${client_ip%% *}"
    if [ -n "$client_ip" ]; then
        setname="$IPSET_V4"
        if [[ "$client_ip" == *:* ]]; then setname="$IPSET_V6"; fi
        if ipset test "$setname" "$client_ip" >/dev/null 2>&1; then return 0; fi
    fi

    log "SSH 端口 ${ssh_port:-未知} 不在 whitelist_ports (${whitelist_ports:-空})"
    log "来源 IP ${client_ip:-未知} 也不在白名单网段内"
    die "应用后当前 SSH 会话将被切断，已中止。请把端口加入 whitelist_ports 或把来源 IP 加入 ALLOWED_NETWORKS；确认可接受请加 --force"
}

#################################################
# 动作实现
#################################################

# 原子切换：先把装配好的新链挂到 PREROUTING 首位，再摘除旧链。
# 切换瞬间新旧链并存，包会先过新链——方向是「更严格」，
# 不会出现旧版 delete→setup 之间那段完全无规则的空窗。
setup_mode() {
    local mode="$1"
    local chain tmp cmd
    chain="$(chain_for_mode "$mode")"
    tmp="${chain}_tmp"

    if [ "$mode" = whitelist ]; then
        build_ipsets
        guard_ssh_lockout
    fi

    if check_rules "$mode" >/dev/null 2>&1 && ! config_changed; then
        log "规则已是最新，无需变更"
        return 0
    fi

    log "应用 $mode 规则（原子切换）..."
    for cmd in iptables ip6tables; do
        "$cmd" -t "$TABLE" -F "$tmp" 2>/dev/null || true
        "$cmd" -t "$TABLE" -X "$tmp" 2>/dev/null || true
        run "$cmd" -t "$TABLE" -N "$tmp"
        populate_chain "$cmd" "$tmp" "$mode"

        run "$cmd" -t "$TABLE" -I "$PARENT_CHAIN" 1 -j "$tmp"

        # 循环删除：顺带清掉旧版重复累积出来的多条同名跳转
        while "$cmd" -t "$TABLE" -C "$PARENT_CHAIN" -j "$chain" >/dev/null 2>&1; do
            run "$cmd" -t "$TABLE" -D "$PARENT_CHAIN" -j "$chain"
            if [ "$DRY_RUN" = 1 ]; then break; fi
        done
        "$cmd" -t "$TABLE" -F "$chain" 2>/dev/null || true
        "$cmd" -t "$TABLE" -X "$chain" 2>/dev/null || true

        run "$cmd" -t "$TABLE" -E "$tmp" "$chain"
        vlog "$(family_label "$cmd"): $chain 已切换"
    done

    record_config_md5
    log "$mode 规则应用完成 (IPv4+IPv6)"
}

delete_mode() {
    local mode="$1"
    local chain cmd c
    chain="$(chain_for_mode "$mode")"

    log "删除 $chain 链..."
    for cmd in iptables ip6tables; do
        for c in "$chain" "${chain}_tmp"; do
            while "$cmd" -t "$TABLE" -C "$PARENT_CHAIN" -j "$c" >/dev/null 2>&1; do
                run "$cmd" -t "$TABLE" -D "$PARENT_CHAIN" -j "$c"
                if [ "$DRY_RUN" = 1 ]; then break; fi
            done
            "$cmd" -t "$TABLE" -F "$c" 2>/dev/null || true
            "$cmd" -t "$TABLE" -X "$c" 2>/dev/null || true
        done
    done

    if [ "$mode" = whitelist ]; then
        local s
        for s in "$IPSET_V4" "$IPSET_V6" "${IPSET_V4}_tmp" "${IPSET_V6}_tmp"; do
            if ipset_exists "$s"; then
                run ipset destroy "$s" && vlog "销毁 ipset: $s"
            fi
        done
    fi

    rm -f "$MD5_FILE" 2>/dev/null || true
    log "$chain 链删除完成 (IPv4+IPv6)"
}

verify_mode() {
    local mode="$1"
    local problems=0

    log "校验 $mode 模式规则..."
    check_rules "$mode" || problems=$?

    if config_changed; then
        vlog "✗ 配置文件已变化，需要重新应用"
        problems=$((problems + 1))
    else
        vlog "✓ 配置文件未变化"
    fi

    if [ "$problems" -eq 0 ]; then
        log "校验通过: $mode 模式规则完整"
        return 0
    fi

    log "校验失败: 发现 $problems 个问题，自动重建..."
    setup_mode "$mode"
    log "$mode 模式已自动重建"
}

status_mode() {
    local mode="$1"
    local chain cmd
    chain="$(chain_for_mode "$mode")"

    for cmd in iptables ip6tables; do
        printf '\n===== %s (%s) =====\n' "$chain" "$(family_label "$cmd")"
        "$cmd" -t "$TABLE" -L "$chain" -n -v 2>/dev/null || printf '链不存在\n'
    done

    if [ "$mode" = whitelist ]; then
        local s
        for s in "$IPSET_V4" "$IPSET_V6"; do
            printf '\n===== ipset %s =====\n' "$s"
            if ipset_exists "$s"; then
                printf '%s 条网段\n' "$(ipset_count "$s")"
                ipset list "$s" 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2
            else
                printf '不存在\n'
            fi
        done
    fi
}

#################################################
# 主程序
#################################################

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mode)    [ $# -ge 2 ] || show_usage; MODE="$2"; shift 2 ;;
        -a|--action)  [ $# -ge 2 ] || show_usage; ACTION="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -f|--force)   FORCE=1; shift ;;
        -q|--quiet)   VERBOSE=0; shift ;;
        -h|--help)    show_usage ;;
        *)            printf '未知参数: %s\n' "$1" >&2; show_usage ;;
    esac
done

[[ "$MODE" =~ ^(whitelist|restricted)$ ]] || die "无效模式: ${MODE:-未指定}"
[[ "$ACTION" =~ ^(setup|delete|verify|status)$ ]] || die "无效动作: ${ACTION:-未指定}"

check_prerequisites
acquire_lock

# shellcheck source=/dev/null
. "$CONFIG_FILE"
vlog "已加载配置: $CONFIG_FILE"

case "$ACTION" in
    setup)  setup_mode  "$MODE" ;;
    delete) delete_mode "$MODE" ;;
    verify) verify_mode "$MODE" ;;
    status) status_mode "$MODE" ;;
esac

exit 0
