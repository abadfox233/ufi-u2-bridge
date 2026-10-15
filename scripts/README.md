# kano_bridge v7 — FM_U20 同网段桥接方案全记录
> 2026-10-10 全链路验证通过: 统一网段 88.0/24 + v4/v6 双栈 + Clash 透明代理, 三者同时在线
> 参考 F50(ZTE 固件级桥接)机制, 在不动固件的前提下手工复刻

## 一、拓扑总览
```
                    ┌─ wlan0 (热点AP, 入桥)
br0 = 192.168.88.1/24 ─┤
+ 蜂窝/64 ::1 (v6)   └─ eth0  (USB有线网卡, 入桥)
    │
    ├─ dnsmasq 2.90 (自编armv7静态): br0 上发 DHCPv4(88.50-150) + RA/DHCPv6
    ├─ NAT: 复用框架 tetherctrl_nat_POSTROUTING (-o sipa_eth0 MASQUERADE)
    └─ 上游: sipa_eth0 蜂窝 (10.x/8 v4 + 蜂窝/64 v6 SLAAC 保留)
```

## 二、每一步的作用(按 run.sh -s 执行顺序)

### v4 部分
| # | 操作 | 作用 | 不做的后果 |
|---|------|------|-----------|
| 1 | `ip link add br0 type bridge` + **锁MAC=wlan0的MAC** | 建二层桥; 锁MAC防止 eth0(00:e0 Realtek,数值最小)入桥后桥MAC被重选 | 桥MAC变化→框架EthernetTracker认为eth0身份变化→反复重置eth0→有线"IP时有时无" |
| 2 | wlan0/eth0 `master br0`; 88.1 从 wlan0 挪到 br0 | 所有客户端二层同网段; 热点IP消失不影响(框架DHCP失明,由dnsmasq接管) | — |
| 3 | dnsmasq (port=0/interface=br0/bind-dynamic) | br0 上唯一的 DHCPv4 服务器(SO_BINDTODEVICE 与框架两个失明DHCP共存) | 客户端拿不到88段地址 |
| 4 | `ip rule pref 21000 iif br0 lookup sipa_eth0` | 客户端上行包查 sipa_eth0 表→走蜂窝默认路由出网 | 上行找不到路由 |
| 5 | `iptables -I tetherctrl_FORWARD -i br0 -o sipa_eth0 ACCEPT` + 回程 ESTABLISHED | 桥内流量放行转发(框架原规则只匹配wlan0/eth0的iif,br0流量不命中) | FORWARD 被框架DROP |
| 6 | `ip route replace 192.168.88.0/24 dev br0 table local_network` | **v4黑洞修复**: 框架在local_network表残留`88.0/24 dev wlan0`,ip rule 16000/17000/20000命中后包被丢(conntrack有流但FORWARD计数0,客户端TCP全SYN_SENT) | "连上热点没网" |
| 7 | eth0随机段(如47.0/24)同表 replace 到 br0 | 同上,框架给eth0配的随机段同样残留 | 同上 |

### v6 部分(五步填五个黑洞)
| # | 操作 | 作用 | 不做的后果 |
|---|------|------|-----------|
| 8 | 从属口 disable_ipv6=1 (wlan0/eth0) | 掐掉框架在wlan0上的幽灵RA(与br0同链路本地源,参数矛盾→客户端判定"路由器抖动"拒绝SLAAC) | 重连拿不到v6 |
| 9 | 蜂窝/64 双挂 br0(`::1`) + sipa_eth0 保留SLAAC | br0获得前缀可发RA; sipa的SLAAC是设备自身v6出网的源地址(删了设备v6断网) | 客户端无v6 / 设备断v6 |
| 10 | dnsmasq enable-ra + dhcp-range=::,constructor:br0,ra-stateless + ra-param(br0,mtu:1500,120,600) | br0 上唯一RA源,客户端SLAAC拿真蜂窝前缀v6 | 无v6下发 |
| 11 | `ip -6 rule pref 21000 iif br0 lookup sipa_eth0` + ip6tables FORWARD 双向 | v6 上行/回程转发放行 | v6 流量不出 |
| 12 | **四张表**都放 `前缀/64 dev br0`: main / sipa_eth0 / local_network / legacy_system / legacy_network | ①main: NS从br0发出直达客户端(替代proxy NDP) ②sipa表: 上行 ③**后三张是回程终极黑洞**(回程包iif sipa_eth0按rule 18000/19000/20000查它们,框架清空后→Network unreachable,回包全堆设备出不去) | v6"获得地址但完全不通"(Mac ping 619个回包堆积) |
| 13 | **删 sipa 表 kernel 连接路由**(`前缀/64 dev sipa_eth0 proto kernel`) | 同段双挂的副产物,metric 256会抢道→NS从蜂窝口发出→运营商无应答→Mac隐私地址解析失败卡SYN_RECV; 内核会重加,守护循环压制 | Mac v6 时通时不通(隐私地址黑洞) |
| 14 | proxy_ndp=1 on sipa + 守护把 br0邻居/conntrack src 自动加代理 | 兜底: 运营商对客户端地址做NS时代答(部分运营商把/64当on-link) | 部分运营商环境回程黑洞 |

### 与其他服务的共存
| 服务 | 兼容性处理 |
|------|-----------|
| **Clash (tproxy)** | 零改动兼容: CLASH链在mangle PREROUTING不挑接口,桥流量iif=br0照常命中(v4 TCP 10万+包); DNS劫持链CLASH_DNS同样全局; **v6不加CLASH6**(Clash核心无v6出站,接管=黑洞) |
| kano_wireguard | 补 `-i br0 -j WG_ROUTE_wg0`(原链绑wlan0,桥后绕过); WG_ROUTE_wg0 链末尾有 `88.0/24 RETURN` 本来就放行 |
| kano_tether_guard | guard.conf 改 GUARD_ETHERNET=0(它每5min重启ethernet tethering会与桥打架), kill -9旧pid后boot重拉 |
| 框架热点 | 全程不感知桥(幽灵TetheredState); 热点由 cmd wifi 或面板控制照常工作 |

## 三、守护进程(-d, 15s循环)的检查项
1. 桥丢失→整体重建  2. br0 MAC 漂移→锁定回去
3. dnsmasq 死→重启  4. local_network表v4复发→replace
5. 框架v6复活到wlan0→删地址+关v6  6. v6前缀变化(重拨)→刷新br0地址+RA
7. sipa表kernel路由复发→删  8. 回程三表被清→补
9. proxy NDP跟随: br0邻居+conntrack里新v6 src 自动加代理

## 四、运行态(2026-10-10 验证通过时刻)
- br0: 192.168.88.1/24 + 2408:xxxx:xxxx:xxxx::1/64, MAC=wlan0
- 手机: 88.106 v4 + v6(隐私地址) Clash代理正常
- Mac: 88.124 v4 + v6(隐私地址) ping 324/324双向 TCP ESTABLISHED
- Clash: TCP TPROXY 103K包命中
- 守护 pid 在 /data/kano_bridge/daemon.pid

## 五、回滚
- 临时还原: `sh /data/kano_bridge/run.sh -k` (拆桥+还88.1给wlan0+清规则+开从属口v6)
- 重启设备 = 全部归零(所有改动均为内存态), 出厂行为
- 彻底卸载: `rm -rf /data/kano_bridge` + 删 ufi_tools_boot.sh 里3行

## 六、产物
- 设备: /data/kano_bridge/{run.sh, off.sh, dnsmasq.conf, bin/dnsmasq(2.90 armv7 static, md5 2103413f...), logs/}
- 备份: 发布包 kano_bridge.tar.gz 一份
- 基线快照(出厂态): 设备 /data/local/tmp/baseline/ (iptables/rule/routes)

## 七、dnsmasq 自旋连环事故与三层防护 (v1.4~v1.6, 2026-10-13)

### 病理
厂商 dnsmasq 2.51(dns_tether)与自编 2.90 均会在「接口翻腾竞态」下进入**纯用户态死循环**:
~100% 单核空转, 持续耗电. 指纹: `/proc/pid/syscall`=running + 5s 内 voluntary_ctxt_switches Δ=0
+ syscr Δ=0 (健康 dnsmasq 的 poll() 主循环必有 vol 增量, 任何真实 DNS 业务必有 syscr 增量).
根因区: dnsmasq 事件簿记(periodic_ra 定时器链/netlink 解析) × 本机 27 接口高频翻腾
(蜂窝重拨变前缀/框架 v6 复活/桥重建) — 官方 CHANGELOG 2.86 修过同族 bug("tight loop
on systems with a very large number of network interfaces"), 2.51 太老没有兜底.

### 三次事故 → 三层防护
| 版本 | 事故 | 根因 | 防护 |
|------|------|------|------|
| v1.4 | 厂商 dnsmasq 开机 +35s 即自旋, 100%×1核永久(生命周期均值 89.6%) | 固件 boot 竞态, 2.51 无「接口找不到→清零定时器」兜底 | **spinwatch**: 守护每轮扫 dns_tether 的活 dnsmasq(跳过僵尸), 签名命中连续 2 轮→精确 pid kill (框架按需重拉健康实例) |
| v1.5 | 自家 dnsmasq(2.90) 在 v6 前缀变更重拉后自旋 103% | 旧实例已自旋时 SIGTERM 杀不死(自旋不回 poll 不处理信号)→新旧双活同抢 REUSEPORT→新实例出生即被传染 | ①monitor 每轮对自家 dnsmasq 同签名检测, 命中即 kill -9+重拉(单轮即杀) ②重启自家 dnsmasq 一律 TERM+KILL 双发 |
| v1.6 | 重启后客户端 v6 全黑洞(RA 停发) | v1.5 kill -9 后重拉撞 EADDRINUSE(端口未释放)→新进程未写 pidfile 即退出→旧判据 `[ -f pidfile ]&&!kill -0` 永假→**永久无人重拉** | 存活检测改 cmdline 扫描(`ps -A -o ARGS|grep conf-file=`, 不依赖 pidfile); 重拉失败记 WARN 下轮 15s 自动重试 |

### 关键工程教训
- 自旋判定证据必须用**进程自身**计数(vol/syscr), 不能用全局 UDP(背景杂音必破判)
- CPU delta 勿设上限(实测自旋 500~503 ticks/5s 含抖动, 上限 495 恰好漏杀)
- 扫描候选必须跳过 Z 态(netd 不回收的僵尸永远排首位, 不跳则检测永久失明)
- pidfile 判活两盲区: 进程退出自删 / 重生失败未写 — 存在性判断一律 cmdline 扫描
- SIGTERM 对自旋进程无效(信号经管道、主循环不回 poll 看不见), 必须 -9
- 守护链任何重拉动作失败不得丢失下轮重试机会(自愈不依赖单次成功)

### 验证记录(全部注入实测)
- v1.4: dns_tether 身份假自旋进程 → round1 → 21s → killed (日志留痕)
- v1.5: pidfile 占位自旋进程 → 45s 内 kill -9+重拉+DNS 恢复; 健康 70s/4 轮零误杀
- v1.6: 杀+删 pidfile 复现事故现场 → 下一轮 scan-based 重拉 → RTR-ADVERT 恢复
- 生产: 2026-10-13 三次真实触发全部自愈, 现场零人工干预

## 八、运营商无关的蜂窝 v6 前缀 (v1.8, 2026-10-15)

### 为什么改
v1.0~v1.7 把运营商前缀当常量用: 四处正则/比对写死 `2408`(中国联通)。换卡/换运营商后:
- 2409(移动) / 240e(电信) / 境外运营商: proxy NDP 播种、conntrack 源补代理、sipa 表 kernel 路由压制、
  local_network 表 v6 纠正**四处同时失效** → 客户端"拿到 v6 却完全不通"(回程黑洞原样复发)。
- 而且蜂窝前缀**每次重拨都会变**, 即便同一运营商也不该写死。

### 现在怎么做
统一从接口实际上游地址推导, 一处实现(`v6_prefix_of` / `cellular_v6_prefix` / `v6_prefix_of_addr`), 全脚本复用:

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `KANO_V6_PREFIX` 环境变量 | 显式覆盖, 形如 `2409:8a00:1234:0`(可带 `::`); 前缀异常/多拨测试用 |
| 2 | 接口上 `scope global dynamic` | SLAAC 地址 → 取该 /64 前 4 个 hextet |
| 3 | 任意 `scope global` | 兜底(某些固件不带 dynamic 标记) |

排除项: `fe80::/10`(链路本地) 与 `fc00::/7`(ULA)。**必须先展开 `::` 再切前 4 段** ——
运营商 /64 常含全零 hextet(如 `240e:3a0::/64`), 直接 `cut -d: -f1-4` 会切出错误前缀。

### 顺带修掉的两处历史死代码
1. **启动时 proxy NDP 播种**(旧 `grep -oE "^${V6P//[!0-9a-f]/}[0-9a-f:]*"`): 把前缀里的冒号全删了再拼正则
   (`^2408840081[0-9a-f:]*`), 与地址文本(带冒号)永不匹配 → 这段播种从来没生效过, 只有 monitor 每轮在补。
2. **sipa 表 kernel 路由压制**(旧 `grep -q "${V6P:-2408}/64 …"`): 前缀少一个冒号, 而 iproute2 打印的是
   `前缀::/64` → 条件恒假, 压制从不触发。(v1.0~v1.7 现场没暴露, 是因为启动路径已删过该路由。)

### 验证(2026-10-15, 真实设备 U20 + 沙箱双跑)
- 逻辑单测 10/10: 联通 2408 / 移动 2409(含压缩写法) / 电信 240e(含全零尾) / 2001:db8 各一组前缀推导,
  以及 fe80、ULA、static 兜底、dynamic 优先级 —— 沙箱 sh/awk 与设备 toybox sh/awk **结果逐行一致**。
- 设备实机只读复核: 真接口 `sipa_eth0`/`br0` → `2408:8409:7901:25ca`(与现场一致), `wlan0`/`lo` → 空;
  `KANO_V6_PREFIX=2409:8a00:1234:0` 覆盖生效; `v6_prefix_of_addr` 对压缩地址 `2409:8a00::1:2` 正确展开为 `2409:8a00:0:0`。
- monitor 判定仿真: 上游前缀 == br0 前缀 → 不动作(当前现场状态正确); 带覆盖时 → 触发刷新(符合预期)。
