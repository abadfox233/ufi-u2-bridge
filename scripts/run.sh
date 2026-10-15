#!/system/bin/sh
# kano_bridge - FM_U20 wlan0+eth0 同网段桥接 (88.1/24)
# v1.4: + spinwatch (厂商 dns_tether dnsmasq 用户态自旋检测/击杀, 2026-10-13 耗电事故修复)
# v1.5: + monitor 自家 dnsmasq 自旋检测 kill -9 重拉; v6 前缀刷新 kill 硬化 TERM+KILL (防 REUSEPORT 双活→新实例自旋)
# v1.6: dnsmasq 存活检测改 cmdline 扫描(不依赖 pidfile) + 重拉失败 15s 自动重试 (修: 重拉失败→pidfile缺→永久无人重拉→RA停发v6黑洞)
# v1.7: + hotspot_guard 热点守护 (修: 蜂窝重拨拆 tethering 栈后热点永不复活, 2026-10-14 01:15 事故 8h 断网)
#       hostapd 消失 + 蜂窝在线 → 连续2轮确认 → HotspotCtl restart (UFI Tools 同款 dex, 框架保存配置原样生效)
# 用法: run.sh -s|-k|-r|-t|-m|-d  (start/stop/restart/status/monitor/daemon)
# 依赖: bin/dnsmasq (2.90 armv7 static, Android-patched), bin/hotspotctl.dex (UFI Tools 提取), /system/bin/ip, iptables
# 全部内存态, stop 或重启即还原出厂

MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DM="$MODDIR/bin/dnsmasq"
HS_DEX="$MODDIR/bin/hotspotctl.dex"
CONF="$MODDIR/dnsmasq.conf"
PIDF="$MODDIR/dnsmasq.pid"
LOG_DIR="$MODDIR/logs"
BR=br0
WAN=sipa_eth0
BR_IP=192.168.88.1
BR_NET=192.168.88.0/24
RULE_PREF=21000

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bridge.log"

log() {
    now="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    [ -n "$now" ] || now="unknown-time"
    printf '%s %s\n' "$now" "$*" >> "$LOG"
    printf '%s\n' "$*"
}

# 等热点起来 (wlan0 有 IPv4 且 hostapd 在跑), 最多 120s
wait_hotspot() {
    i=0
    while [ $i -lt 60 ]; do
        if [ -n "$(pidof hostapd)" ] && ip -4 addr show wlan0 2>/dev/null | grep -q "inet 192.168.88.1"; then
            return 0
        fi
        sleep 2
        i=$((i+1))
    done
    return 1
}

# ---------- v1.7 热点守护 ----------
# 背景事故: 蜂窝 modem 掉线重拨 → 厂商固件拆掉整个 tethering 栈(含 SoftAp/hostapd)
#          → 无任何组件负责复活热点 → 半夜断网到手动重启 (2026-10-14 01:15, 8h)
# 检测: hostapd 进程消失 且 蜂窝 sipa_eth0 有 IPv4 (有上联才值得拉热点)
# 确认: 连续 2 轮命中才动手 (15s×2≈30s), 防误杀"重启中"的热点 (厂商/用户主动重启也走 hostapd 消失)
# 恢复: HotspotCtl restart — UFI Tools App 内置同款 dex (assets/shell/hotspotctl.dex),
#       内部走框架 startTetheredHotspot → 框架保存的 SoftApConfiguration 原样生效 (SSID/密码/频段/隐藏/超时全一致)
# env : app_process 需要 BOOTCLASSPATH, dropbear SSH/boot.sh 环境没有 → 运行时从 system_server environ 提取 (不硬编码)
# 退避: 失败连续 3 次后退避到 5min 一次, 成功即复位; 状态记 hsguard.state
# 观察: HSGUARD_OBSERVE=1 时只记日志不执行 restart (排障期用)
hotspot_guard() {
    [ -f "$HS_DEX" ] || { log "hsguard: WARN hotspotctl.dex missing, guard disabled"; return 0; }
    [ -f "$MODDIR/hsguard.off" ] && return 0

    # 死亡判定 (hostapd 活着时不写盘 — 15s×5760次/天会磨 eMMC, 仅内容变化才写)
    if [ -n "$(pidof hostapd)" ]; then
        [ "$(cat "$MODDIR/hsguard.state" 2>/dev/null)" != "fails=0 lastts=0" ] && echo "fails=0 lastts=0" > "$MODDIR/hsguard.state"
        rm -f "$MODDIR/hsguard.hits" 2>/dev/null
        return 0
    fi
    # hostapd 不在: 蜂窝要有 IPv4 才动手 (飞行模式/无服务时拉热点无意义, 静默等)
    ip -4 addr show "$WAN" 2>/dev/null | grep -q "inet " || return 0

    # 退避检查: 上次尝试失败连续>=3次 → 5 分钟最多试一次
    eval "$(cat "$MODDIR/hsguard.state" 2>/dev/null)" 2>/dev/null
    FAILS=${fails:-0}
    LASTTS=${lastts:-0}
    NOW=$(date +%s)
    [ "$FAILS" -ge 3 ] && [ $((NOW - LASTTS)) -lt 300 ] && return 0

    # 连续命中计数
    HITS=$(cat "$MODDIR/hsguard.hits" 2>/dev/null || echo 0)
    case "$HITS" in ''|*[!0-9]*) HITS=0 ;; esac
    HITS=$((HITS+1))
    echo "$HITS" > "$MODDIR/hsguard.hits"
    if [ "$HITS" -lt 2 ]; then
        log "hsguard: hostapd gone, cellular up — round $HITS, waiting for confirm"
        return 0
    fi
    echo 0 > "$MODDIR/hsguard.hits"

    # 观察模式
    if [ -f "$MODDIR/hsguard.observe" ]; then
        log "hsguard: OBSERVE hostapd dead ${HITS}+ rounds, cellular up — would restart (observe mode)"
        echo 0 > "$MODDIR/hsguard.hits"
        return 0
    fi

    log "hsguard: hostapd dead (confirmed), restarting hotspot via HotspotCtl"
    BCP=$(tr "\0" "\n" < /proc/$(pidof system_server)/environ 2>/dev/null | grep "^BOOTCLASSPATH=" | head -1)
    [ -n "$BCP" ] || { log "hsguard: ERROR no BOOTCLASSPATH from system_server, try next round"; return 0; }
    export "$BCP" ANDROID_DATA=/data ANDROID_ROOT=/system \
        ANDROID_ART_ROOT=/apex/com.android.art ANDROID_I18N_ROOT=/apex/com.android.i18n \
        ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
    export CLASSPATH="$HS_DEX"
    OUT=$(timeout 30 app_process / HotspotCtl restart 2>&1)
    RC=$?
    echo "$OUT" | head -3 >> "$LOG"
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "restarted and enabled"; then
        echo "fails=0 lastts=$NOW" > "$MODDIR/hsguard.state"
        log "hsguard: hotspot restart OK — framework config intact, daemon will rebuild bridge"
    else
        NEWF=$((FAILS+1))
        echo "fails=$NEWF lastts=$NOW" > "$MODDIR/hsguard.state"
        log "hsguard: WARN restart rc=$RC (fails=$NEWF) — $OUT"
    fi
    return 0
}

start() {
    # 幂等: 已在跑则跳过
    ip link show $BR >/dev/null 2>&1 && { log "bridge $BR already up"; return 0; }

    if ! wait_hotspot; then
        log "hotspot not ready yet (boot early?) - daemon will retry"
        return 1
    fi

    log "creating bridge $BR"
    ip link add $BR type bridge || { log "ERROR: bridge create failed"; return 1; }

    # 锁桥 MAC = wlan0 MAC (关键: 防 eth0 入桥后桥 MAC 重选 → EthernetTracker 重置抖动)
    WMAC=$(cat /sys/class/net/wlan0/address)
    ip link set $BR address "$WMAC"
    ip link set $BR up

    # wlan0 入桥 + 挪 IP
    ip link set wlan0 master $BR
    ip addr del $BR_IP/24 dev wlan0 2>/dev/null
    ip addr add $BR_IP/24 dev $BR

    # eth0 入桥 (若存在/UP)
    ip link show eth0 >/dev/null 2>&1 && ip link set eth0 master $BR

    # DHCP: dnsmasq 专服 br0 (与框架失明 DHCP 共存); conf 含 DNS(53)+劫持
    if [ -x "$DM" ]; then
        [ -f "$MODDIR/dnsmasq.hosts.conf" ] || echo "# 域名劫持条目: address=/域名/IP" > "$MODDIR/dnsmasq.hosts.conf"
        "$DM" --conf-file="$CONF"
        log "dnsmasq started rc=$?"
        # DNS 劫持豁免: 发往 br0 IP 的 53 查询直达本机 dnsmasq(绕过 Clash 的 CLASH_DNS REDIRECT)
        iptables -t nat -C CLASH_DNS -d $BR_IP -p udp -m udp --dport 53 -j RETURN 2>/dev/null || \
            iptables -t nat -I CLASH_DNS 1 -d $BR_IP -p udp -m udp --dport 53 -j RETURN
        iptables -t nat -C CLASH_DNS -d $BR_IP -p tcp -m tcp --dport 53 -j RETURN 2>/dev/null || \
            iptables -t nat -I CLASH_DNS 1 -d $BR_IP -p tcp -m tcp --dport 53 -j RETURN
    else
        log "WARN: $DM missing, no DHCP"
    fi

    # 路由/转发
    ip rule add pref $RULE_PREF iif $BR lookup $WAN 2>/dev/null
    iptables -I tetherctrl_FORWARD 1 -i $BR -o $WAN -j ACCEPT
    iptables -I tetherctrl_FORWARD 1 -i $WAN -o $BR -m state --state RELATED,ESTABLISHED -j ACCEPT
    # 关键: 修 local_network 表黑洞 (框架残留 wlan0 静态路由)
    ip route replace $BR_NET dev $BR table local_network
    # eth0 随机段路由也指回 br0 (框架把它配在 eth0 上, 桥内无害但表项要一致)
    ETNET=$(ip -4 addr show eth0 2>/dev/null | grep -oE "inet 192\.168\.[0-9]+\." | head -1 | cut -d" " -f2)
    [ -n "$ETNET" ] && ip route replace ${ETNET}0/24 dev $BR table local_network 2>/dev/null

    # IPv6: 蜂窝 /64 挂 br0 + RA (dnsmasq conf 已有 enable-ra/constructor:br0)
    # 先关闭桥从属口 v6 栈: 框架 RouterAdvertisementDaemon 从 wlan0 LL 发冲突 RA
    # (br0 与 wlan0 同 LL → 手机判定路由器抖动拒绝 SLAAC), 关掉后 br0 成为唯一 RA 源
    echo 1 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null
    echo 1 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6 2>/dev/null
    V6P=$(ip -6 addr show $WAN 2>/dev/null | grep -m1 "scope global dynamic" | awk '{print $2}' | cut -d: -f1-4)
    if [ -n "$V6P" ]; then
        V6P="${V6P}::"
        ip addr add ${V6P}1/64 dev $BR 2>/dev/null
        # 刷新 dnsmasq 使 RA 拾取新前缀 (TERM+KILL 双发, 防 REUSEPORT 双活竞态)
        [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null; kill -9 "$(cat "$PIDF")" 2>/dev/null; sleep 1; }
        "$DM" --conf-file="$CONF" 2>>"$LOG"
        ip -6 rule add pref $RULE_PREF iif $BR lookup $WAN 2>/dev/null
        ip6tables -I FORWARD 1 -i $BR -o $WAN -j ACCEPT
        ip6tables -I FORWARD 1 -i $WAN -o $BR -m state --state RELATED,ESTABLISHED -j ACCEPT
        # 关键: sipa_eth0 表的 v6 /64 静态路由会把回程甩回蜂窝口(手机v6 TCP卡SYN_RECV), 指向 br0
        ip -6 route replace ${V6P}/64 dev $BR table $WAN 2>/dev/null
        # 删 sipa 表的 kernel 连接路由(同段双挂的副产物): 它 metric 256 抢道, NS 从蜂窝口发出永远无解
        # — F50 无此问题的原因是它的固件只在 br0 配 /64(ZTE 定制), 我们双挂必须删
        ip -6 route del ${V6P}/64 dev $WAN proto kernel table $WAN 2>/dev/null
        # main 表也要有 (回程路由查找)
        ip -6 route replace ${V6P}/64 dev $BR 2>/dev/null
        # 回程三表补全: iif sipa_eth0 的回程包按 rule 18000/19000/20000 查 legacy_system/legacy_network/local_network
        # 框架拆 wlan0 v6 时会清空这些表的 v6 → 回程 Network unreachable 全黑洞 (最终真凶)
        for T in local_network legacy_system legacy_network; do
            ip -6 route replace ${V6P}/64 dev $BR table $T 2>/dev/null
        done
        # proxy NDP: 手机 SLAAC 地址在蜂窝 /64 内但不在蜂窝链路上, 运营商 NS 无人应答 → 回程黑洞
        # (IPv6 版 ARP 代理, F50 固件内置, 手工复刻) — 把 br0 上学到的该前缀邻居全部代理到蜂窝口
        echo 1 > /proc/sys/net/ipv6/conf/$WAN/proxy_ndp 2>/dev/null
        for A in $(ip -6 neigh show dev $BR 2>/dev/null | grep -oE "^${V6P//[!0-9a-f]/}[0-9a-f:]*"); do
            ip -6 neigh replace proxy $A dev $WAN 2>/dev/null
        done
        # WG_ROUTE mangle 链绑 -i wlan0, 桥后 iif=br0 绕过 → 补 br0 入口(kano_wireguard 内网分流)
        iptables -t mangle -C PREROUTING -i $BR -j WG_ROUTE_wg0 2>/dev/null || \
            iptables -t mangle -I PREROUTING 1 -i $BR -j WG_ROUTE_wg0
        log "ipv6 up: ${V6P}1/64 on $BR, RA enabled"
    else
        log "WARN: no cellular v6 prefix found, skip v6"
    fi

    log "bridge up: $BR=$BR_IP wlan0+eth0 members, DHCP=88.50-150"
    return 0
}

stop() {
    # 杀 dnsmasq (精确 pid, 绝不 pkill -f)
    if [ -f "$PIDF" ]; then
        kill "$(cat "$PIDF")" 2>/dev/null
        rm -f "$PIDF"
    fi
    # 清 DNS 劫持豁免规则
    iptables -t nat -D CLASH_DNS -d $BR_IP -p udp -m udp --dport 53 -j RETURN 2>/dev/null
    iptables -t nat -D CLASH_DNS -d $BR_IP -p tcp -m tcp --dport 53 -j RETURN 2>/dev/null
    # 杀守护
    [ -f "$MODDIR/daemon.pid" ] && { kill "$(cat "$MODDIR/daemon.pid")" 2>/dev/null; rm -f "$MODDIR/daemon.pid"; }
    # 还原从属口 v6
    echo 0 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null
    echo 0 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6 2>/dev/null
    # 清 v6
    ip -6 rule del pref $RULE_PREF iif $BR lookup $WAN 2>/dev/null
    ip6tables -D FORWARD -i $BR -o $WAN -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $WAN -o $BR -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    # 拆桥还原
    ip link set wlan0 nomaster 2>/dev/null
    ip link set eth0 nomaster 2>/dev/null
    ip link del $BR 2>/dev/null
    # 还 88.1 给框架
    ip -4 addr show wlan0 | grep -q "inet $BR_IP" || ip addr add $BR_IP/24 dev wlan0 2>/dev/null
    # 清规则
    ip rule del pref $RULE_PREF iif $BR lookup $WAN 2>/dev/null
    iptables -D tetherctrl_FORWARD -i $BR -o $WAN -j ACCEPT 2>/dev/null
    iptables -D tetherctrl_FORWARD -i $WAN -o $BR -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    log "bridge removed, restored to stock"
}

status() {
    echo "== bridge =="
    ip -d link show $BR 2>/dev/null | head -2 || echo "$BR not exists"
    ip -4 addr show $BR 2>/dev/null | grep inet
    echo "wlan0 master: $(ip -d link show wlan0 | grep -oE 'master [a-z0-9]+' || echo none)"
    echo "eth0 master: $(ip -d link show eth0 | grep -oE 'master [a-z0-9]+' || echo none)"
    echo "== dhcp =="
    [ -f "$MODDIR/leases" ] && cat "$MODDIR/leases" || echo "(no leases file)"
    echo "== forward counters =="
    iptables -L tetherctrl_FORWARD -v -n 2>/dev/null | head -4
    echo "== clients (neigh) =="
    ip neigh show dev $BR 2>/dev/null | head -6
    echo "== hotspot =="
    if [ -n "$(pidof hostapd)" ]; then echo "hostapd running (pid $(pidof hostapd))"; else echo "hostapd DOWN"; fi
    [ -f "$MODDIR/hsguard.state" ] && { echo "hsguard: $(cat "$MODDIR/hsguard.state")"; }
}

# 健康自检+自愈 (供 cron/常驻调用): 桥没了重建, MAC 被抢修回
monitor() {
    # v1.7: 热点守护最优先 — 热点死了一切白搭
    hotspot_guard
    if ! ip link show $BR >/dev/null 2>&1; then
        log "monitor: bridge lost, restarting"
        stop 2>/dev/null
        start
        return
    fi
    # MAC 校验
    WMAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
    BRMAC=$(cat /sys/class/net/$BR/address 2>/dev/null)
    if [ -n "$WMAC" ] && [ -n "$BRMAC" ] && [ "$WMAC" != "$BRMAC" ]; then
        log "monitor: br MAC drifted ($BRMAC != $WMAC), fixing"
        ip link set $BR address "$WMAC"
    fi
    # DHCP 进程存活 — 按 cmdline 扫描而非 pidfile (v1.6 事故: 重拉失败时 dnsmasq 未写 pidfile 即退出
    # → pidfile 缺失 → 旧的 [ -f pidfile ]&&!kill-0 判据永远为假 → 永久无人重拉 → RA 停发 v6 黑洞)
    # 任何一轮发现没有活着的自家 dnsmasq 就重拉; 重拉失败(如旧实例端口未释放的 EADDRINUSE 瞬态)
    # 记 WARN, 下一轮(15s)自动重试 — 自愈闭环不依赖单次成功
    if ! ps -A -o ARGS 2>/dev/null | grep -v grep | grep -q "conf-file=$CONF"; then
        rm -f "$PIDF"
        if "$DM" --conf-file="$CONF" 2>>"$LOG"; then
            log "monitor: dnsmasq respawned (scan-based)"
        else
            log "monitor: WARN dnsmasq start failed, will retry next round"
        fi
    fi
    # 自家 dnsmasq 自旋检测+重拉 (2026-10-13 二次事故: v6前缀变更重拉的实例进入用户态自旋 103%)
    # 签名: 5s 内 CPU≥400 ticks 且 volΔ=0 且 syscrΔ=0 → 用户态死循环 (健康 dnsmasq 的 poll() 主循环
    # 周期唤醒必有 vol 增量, 任何真实 DNS 业务必有 syscr 增量; 空闲时 CPU≈0 不满足第一条).
    # 对自家进程单轮确认即 kill -9 (SIGTERM 对自旋进程无效 — 它不回 poll 也就不处理信号) + 重拉.
    # 新实例若再自旋, 下一轮 monitor (≈20s 后) 再杀再拉, 自愈循环.
    if [ -f "$PIDF" ]; then
        MPID=$(cat "$PIDF" 2>/dev/null)
        if [ -n "$MPID" ] && kill -0 "$MPID" 2>/dev/null; then
            MT1=$(awk '{print $14+$15}' /proc/$MPID/stat 2>/dev/null)
            MV1=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$MPID/status 2>/dev/null)
            MR1=$(awk '/^syscr/ {print $2}' /proc/$MPID/io 2>/dev/null)
            sleep 5
            MT2=$(awk '{print $14+$15}' /proc/$MPID/stat 2>/dev/null)
            MV2=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$MPID/status 2>/dev/null)
            MR2=$(awk '/^syscr/ {print $2}' /proc/$MPID/io 2>/dev/null)
            if [ -n "$MT1" ] && [ -n "$MT2" ] && [ -n "$MV1" ] && [ -n "$MV2" ] && [ -n "$MR1" ] && [ -n "$MR2" ] \
               && [ "$((MT2-MT1))" -ge 400 ] \
               && [ "$((MV2-MV1))" -eq 0 ] && [ "$((MR2-MR1))" -eq 0 ]; then
                log "monitor: own dnsmasq pid=$MPID userland spin detected, kill -9 + respawn"
                kill -9 "$MPID" 2>/dev/null
                rm -f "$PIDF"
                sleep 1
                "$DM" --conf-file="$CONF" 2>>"$LOG"
            fi
        fi
    fi
    # local_network 表黑洞复发检查
    ip route show table local_network 2>/dev/null | grep -q "$BR_NET dev wlan0" && {
        ip route replace $BR_NET dev $BR table local_network
        log "monitor: local_network route fixed"
    }
    # v6 前缀变化检测 (蜂窝重拨后前缀会变)
    V6P=$(ip -6 addr show $WAN 2>/dev/null | grep -m1 "scope global dynamic" | awk '{print $2}' | cut -d: -f1-4)
    V6BR=$(ip -6 addr show $BR 2>/dev/null | grep -m1 "scope global" | awk '{print $2}' | cut -d: -f1-4)
    if [ -n "$V6P" ] && [ "$V6P" != "$V6BR" ]; then
        log "monitor: v6 prefix changed ($V6BR -> $V6P), refreshing"
        [ -n "$V6BR" ] && ip addr del ${V6BR}::1/64 dev $BR 2>/dev/null
        ip addr add ${V6P}::1/64 dev $BR 2>/dev/null
        # TERM+KILL 双发: 纯 TERM 杀不死自旋实例(不处理信号), 旧实例不死与新实例同抢 REUSEPORT
        # — 2026-10-13 事故疑似触发路径 (重拉出的新实例进用户态自旋)
        [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null; kill -9 "$(cat "$PIDF")" 2>/dev/null; sleep 1; }
        "$DM" --conf-file="$CONF" 2>>"$LOG"
    fi
    # 框架 v6 复活清理: 客户端重连会触发 IPv6TetheringCoordinator 把蜂窝 /64 挂回 wlan0
    # (同 LL 源双 RA → 手机判定路由器抖动拒绝 SLAAC); disable_ipv6 兜底: 若框架重开 v6 再关
    W6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" | awk '{print $2}')
    if [ -n "$W6" ] || [ "$(cat /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null)" != "1" ]; then
        [ "$(cat /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null)" != "1" ] && {
            echo 1 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null
            echo 1 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6 2>/dev/null
            log "monitor: slave v6 re-disabled"
        }
        [ -n "$W6" ] && {
            log "monitor: framework v6 resurrected on wlan0 ($W6), removing"
            ip -6 addr del "$W6" dev wlan0 2>/dev/null
            P6=$(echo "$W6" | cut -d: -f1-4)
            ip -6 route del ${P6}::/64 dev wlan0 table 1032 2>/dev/null
            ip -6 route replace ${P6}::/64 dev $BR table local_network 2>/dev/null
        }
    fi
    # proxy NDP 跟随: 客户端新 SLAAC 地址自动代理(前缀内 br0 邻居 → sipa proxy)
    echo 1 > /proc/sys/net/ipv6/conf/$WAN/proxy_ndp 2>/dev/null
    V6P2=$(ip -6 addr show $BR 2>/dev/null | grep -m1 "scope global" | grep -m1 -v "fcfd" | awk '{print $2}' | cut -d: -f1-4)
    if [ -n "$V6P2" ]; then
        # 来源1: br0 邻居表(已解析的)
        for A in $(ip -6 neigh show dev $BR 2>/dev/null | grep -oE "^2408:[0-9a-f:]+"); do
            case "$A" in
                ${V6P2}*) ip -6 neigh show proxy dev $WAN 2>/dev/null | grep -q "$A" || ip -6 neigh replace proxy $A dev $WAN 2>/dev/null ;;
            esac
        done
        # 来源2: conntrack 流的 src(隐私地址发包先于邻居解析 — 主动补, 消除黑洞窗口)
        for A in $(grep "^ipv6" /proc/net/nf_conntrack 2>/dev/null | grep -oE "src=2408:[0-9a-f:]+" | cut -d= -f2); do
            case "$A" in
                ${V6P2}*) ip -6 neigh show proxy dev $WAN 2>/dev/null | grep -q "$A" || { ip -6 neigh replace proxy $A dev $WAN 2>/dev/null; log "monitor: proxy NDP +$A (from conntrack)"; } ;;
            esac
        done
    fi
    # sipa 表 kernel 连接路由复发压制(同段双挂副产物, 会抢道使 NS 发错口)
    ip -6 route show table $WAN 2>/dev/null | grep -q "${V6P:-2408}/64 dev $WAN proto kernel" && {
        ip -6 route del ${V6P}/64 dev $WAN proto kernel table $WAN 2>/dev/null
        log "monitor: sipa kernel v6 route re-suppressed"
    }
    # 回程三表 v6 路由复发(框架动作会清空)
    V6P3=$(ip -6 addr show $BR 2>/dev/null | grep -m1 "scope global" | grep -m1 -v "fcfd" | awk '{print $2}' | cut -d: -f1-4)
    if [ -n "$V6P3" ]; then
        for T in local_network legacy_system legacy_network; do
            ip -6 route show table $T 2>/dev/null | grep -q "dev $BR" || {
                ip -6 route replace ${V6P3}::/64 dev $BR table $T 2>/dev/null
                log "monitor: reply table $T v6 refilled"
            }
        done
    fi
    # local_network v6 指向 wlan0 的复发
    P6W=$(ip -6 route show table local_network 2>/dev/null | grep -oE "^2408:[0-9a-f:]*:[0-9a-f]*:" | head -1)
    [ -n "$P6W" ] && ip -6 route show table local_network | grep -q "dev wlan0" && {
        ip -6 route replace ${P6W}:/64 dev $BR table local_network 2>/dev/null
        log "monitor: local_network v6 route fixed"
    }
}

# 厂商 dns_tether dnsmasq 自旋防护 (2026-10-13 耗电事故)
# 现象: 厂商 dnsmasq 2.51 (dns_tether 用户, netd 子进程) 开机竞态下进入纯用户态死循环,
#       ~100% 单核空转 (syscall=running, 读syscall=0, UDP收发=0), 桥设备的耗电主因.
# 判定: 5s 采样, CPU 高占用 (delta≥400 ticks) 且 本进程 voluntary_ctxt_switches 增量=0
#       且 本进程读syscall(syscr)增量=0 → 唯一解释 = 用户态死循环.
#       正常 dnsmasq 主循环是 poll(): 无论闲忙每请求必产生 voluntary 切换, DNS 洪峰也不例外.
#       (v1 初版用"全局UDP增量=0"作证据 — 背景UDP杂音(ssh/系统)必破坏判定, 永远杀不掉真目标, 已废弃)
#       注: 无 CPU delta 上限 — 实测自旋 delta=500~503(含调度抖动), 写上限必漏杀; 防误杀靠 voluntary/syscr=0 + cmdline 复验
# 动作: 连续 2 轮命中 (间隔 15s) 才 kill, 精确 pid, kill 前再验 cmdline 仍是 dnsmasq (防 PID 处用误杀).
#       绝不 pkill, 绝不碰自家 dnsmasq (root 用户, conf-file=kano_bridge).
# 状态: spin.state 记连续命中轮数, 任一轮未命中即清零
spinwatch() {
    # 扫描候选: dns_tether 用户的 dnsmasq — 跳过僵尸 (netd 不回收的僵尸永远排首, 不跳则永久失明)
    SPIN_PID=""
    for P in $(ps -A -o USER:12,PID,ARGS 2>/dev/null | awk '$1=="dns_tether" && /dnsm/ && !/awk/ {print $2}'); do
        [ "$(awk '{print $3}' /proc/$P/stat 2>/dev/null)" = "Z" ] && continue
        SPIN_PID=$P
        break
    done
    if [ -z "$SPIN_PID" ]; then
        rm -f "$MODDIR/spin.state"
        return 0
    fi
    T1=$(awk '{print $14+$15}' /proc/$SPIN_PID/stat 2>/dev/null)
    V1=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$SPIN_PID/status 2>/dev/null)
    R1=$(awk '/^syscr/ {print $2}' /proc/$SPIN_PID/io 2>/dev/null)
    sleep 5
    T2=$(awk '{print $14+$15}' /proc/$SPIN_PID/stat 2>/dev/null)
    V2=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$SPIN_PID/status 2>/dev/null)
    R2=$(awk '/^syscr/ {print $2}' /proc/$SPIN_PID/io 2>/dev/null)
    if [ -n "$T1" ] && [ -n "$T2" ] && [ -n "$V1" ] && [ -n "$V2" ] && [ -n "$R1" ] && [ -n "$R2" ] \
       && [ "$((T2-T1))" -ge 400 ] \
       && [ "$((V2-V1))" -eq 0 ] && [ "$((R2-R1))" -eq 0 ]; then
        SPIN_COUNT=$(cat "$MODDIR/spin.state" 2>/dev/null || echo 0)
        case "$SPIN_COUNT" in ''|*[!0-9]*) SPIN_COUNT=0 ;; esac
        SPIN_COUNT=$((SPIN_COUNT+1))
        echo "$SPIN_COUNT" > "$MODDIR/spin.state"
        if [ "$SPIN_COUNT" -ge 2 ]; then
            if grep -q "dnsmasq" /proc/$SPIN_PID/cmdline 2>/dev/null; then
                kill "$SPIN_PID" 2>/dev/null \
                    && log "spinwatch: killed dns_tether dnsmasq pid=$SPIN_PID (userland spin, round $SPIN_COUNT)"
            fi
            rm -f "$MODDIR/spin.state"
        else
            log "spinwatch: dns_tether dnsmasq pid=$SPIN_PID spinning (round 1, kill on next confirm)"
        fi
    else
        rm -f "$MODDIR/spin.state"
    fi
    return 0
}

# 守护模式: 后台循环自愈 (桥丢失→重建, 开机早期热点未就绪→等待热点出现后自动建桥)
daemon() {
    echo $$ > "$MODDIR/daemon.pid"
    log "daemon started (pid $$)"
    while true; do
        monitor >/dev/null 2>&1
        # 厂商 dns_tether dnsmasq 自旋检测 (含开机早期桥未建阶段, 自旋从开机 +35s 就开始)
        spinwatch >/dev/null 2>&1
        # 桥还没建且热点已就绪 → 立即补建 (开机早期 -s 失败的自愈路径)
        if ! ip link show $BR >/dev/null 2>&1; then
            if [ -n "$(pidof hostapd)" ] && ip -4 addr show wlan0 2>/dev/null | grep -q "inet 192.168.88.1"; then
                log "daemon: hotspot now ready, building bridge"
                start >/dev/null 2>&1
            fi
        fi
        # v1.7: 桥在但 wlan0 已逃逸 (hsguard/框架重建热点会重新创建 wlan0, 新口不再是桥成员;
        # 不重建则双接口各挂 88.1 路由混乱). 复验 3s 排除热点启停瞬态.
        if ip link show $BR >/dev/null 2>&1; then
            if [ -n "$(pidof hostapd)" ] && ! ip -d link show wlan0 2>/dev/null | grep -q "master $BR"; then
                sleep 3
                if [ -n "$(pidof hostapd)" ] && ! ip -d link show wlan0 2>/dev/null | grep -q "master $BR"; then
                    log "daemon: wlan0 escaped bridge (hotspot recreated), rebuilding"
                    stop >/dev/null 2>&1
                    sleep 2
                    start >/dev/null 2>&1
                fi
            fi
        fi
        sleep 15
    done
}

case "$1" in
    -s|start) start ;;
    -k|stop) stop ;;
    -r|restart) stop; sleep 1; start ;;
    -t|status) status ;;
    -m|monitor) monitor ;;
    -d|daemon) daemon ;;
    *) echo "usage: $0 -s|-k|-r|-t|-m|-d"; exit 1 ;;
esac
