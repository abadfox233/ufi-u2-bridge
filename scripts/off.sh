#!/system/bin/sh
# off.sh - 一键还原出厂网络状态 (拆桥+还IP+清规则)
BR=br0
BR_IP=192.168.88.1
WAN=sipa_eth0
RULE_PREF=21000

if [ -f /data/kano_bridge/dnsmasq.pid ]; then
    kill "$(cat /data/kano_bridge/dnsmasq.pid)" 2>/dev/null
    rm -f /data/kano_bridge/dnsmasq.pid
fi
ip link set wlan0 nomaster 2>/dev/null
ip link set eth0 nomaster 2>/dev/null
ip link del $BR 2>/dev/null
ip -4 addr show wlan0 | grep -q "inet $BR_IP" || ip addr add $BR_IP/24 dev wlan0 2>/dev/null
ip rule del pref $RULE_PREF iif $BR lookup $WAN 2>/dev/null
iptables -D tetherctrl_FORWARD -i $BR -o $WAN -j ACCEPT 2>/dev/null
iptables -D tetherctrl_FORWARD -i $WAN -o $BR -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
echo "restored to stock. reboot also works."
