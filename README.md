# ufi-u2-bridge

FM_U20 (UNISOC 随身WiFi, Android 13, 32 位 userland) 的 **WiFi/有线同网段桥接** UFI Tools 插件。

出厂固件下 WiFi 热点是 `192.168.88.1/24`, 有线(USB 网卡)由 Android 原生 ethernet tethering 管理,
**每次重启从 192.168.0.0/16 里随机挑一个 /24** —— 两个下行口网段不一致, 两端客户端互不相通;
且客户端拿不到蜂窝 IPv6。本插件用二层桥 + 自管 DHCP/RA 把两个口并成一个网段并下发真 IPv6,
全程内存态, 停止或重启即还原出厂行为。

## 功能

- **统一网段**: wlan0(热点AP) + eth0(USB有线) 二层桥接为 `br0 = 192.168.88.1/24`, WiFi 与有线客户端同段互通
- **IPv6 双栈**: 蜂窝 /64 双挂 br0, dnsmasq 2.90(自编 armv7 静态) 发 RA/DHCPv6, 客户端 SLAAC 拿到运营商真 v6
- **Clash 透明代理零冲突**: tproxy 流量照常命中, v6 纯转发直通
- **域名劫持**: 内置 DNS 服务(53), 可把任意域名解析到内网 IP (iStore 风格), 面板可视化增删
- **全内存态**: `run.sh -k` 或重启即还原出厂网络; 15s 守护自愈(桥/MAC/路由表/v6 前缀/热点)
- **热点守护 (v1.7)**: 蜂窝重拨会拆掉厂商 tethering 栈导致热点不再复活, 守护检测后自动 `HotspotCtl restart`
  (依赖厂商的 `hotspotctl.dex`, 已随发行包/插件一起提供, 见下「第三方组件说明」)

## 适用设备 / 前提

- 机型: FM_U20 (UNISOC ums9621, Android 13, **armeabi-v7a 32 位 userland**), 需 **root**
- 依赖厂商 UFI Tools App (`com.minikano.f50_sms`): 插件靠它的 root shell 桥与 boot 链 (`/sdcard/ufi_tools_boot.sh`)
- 其他机型/固件未验证 —— 桥接方案深度依赖该固件的内存态行为 (tethering apex、tetherctrl 链、路由表结构)

## 安装

两种方式, 任选其一:

1. **插件(推荐)**: UFI Tools 插件管理导入 `plugin/bridge_manager_v1.3.js.txt` (自包含, 离线可装),
   主界面出现「桥接管理」, 点【安装】即部署到 `/data/kano_bridge/`。
2. **手动**: 解 `dist/kano_bridge_v1.7.tar.gz` 到 `/data/kano_bridge/`, 执行 `sh /data/kano_bridge/run.sh -s`。

## 用法

```
sh /data/kano_bridge/run.sh -s   # 启动(建桥)
sh /data/kano_bridge/run.sh -k   # 停止并还原出厂网络
sh /data/kano_bridge/run.sh -r   # 重启(改 dnsmasq.conf / 劫持条目后用)
sh /data/kano_bridge/run.sh -t   # 状态
sh /data/kano_bridge/run.sh -m   # 单轮自愈
sh /data/kano_bridge/run.sh -d   # 守护循环(15s)
```

## 域名劫持 (DNS)

桥接模式下本插件的 dnsmasq 是 br0 的唯一 DHCP 服务器, 同时内置 DNS 转发。
写进 `/data/kano_bridge/dnsmasq.hosts.conf` (主 conf 已 include), 或直接改 `scripts/dnsmasq.conf`:

```
# 例: 把这些域名劫持到内网服务
address=/nav.example.com/192.168.88.1
address=/*.local/192.168.88.1
server=/内网域名后缀/192.168.88.1
```

- `address=/域名/IP` 劫持到指定 IP;`address=/域名/`(无参数) 整个域名 NXDOMAIN;
- `address=/域名/::` 只屏蔽该域名的 AAAA(客户端自动回落 v4);
- 改后 `run.sh -r` 生效; 面板「劫持列表」可视化增删并**热重载**(不拆桥、不断客户端)。

## 目录

- `plugin/` UFI Tools 插件(自包含: 面板 + 内嵌安装包 base64)
- `scripts/` `run.sh`(服务) `off.sh`(一键还原) `dnsmasq.conf` `README.md`(全记录文档: 每步操作/作用/不做的后果/回滚) `extract_hotspotctl.sh`
- `bin-armv7/` `dnsmasq` 2.90 (zig 交叉编译静态, Android 补丁: 无 `/etc/passwd` 时强制以 root 运行)
- `gen/gen_bridge_plugin_v13.py` 插件生成器(改 `scripts/` 后重跑即重新打包, 产物确定性)
- `gen/plugin_harness_bridge.js` 插件宿主模拟器(交付前自检, 见下)
- `dist/` tar.gz 发行包(v1.3 ~ v1.7)

## 自检

```bash
# 正例: 期望全绿 (含真跑一遍插件安装流)
node gen/plugin_harness_bridge.js plugin/bridge_manager_v1.3.js.txt ok
# 负例: 期望安装链正确报错 (验证桩件真的会拦)
node gen/plugin_harness_bridge.js plugin/bridge_manager_v1.3.js.txt nodnsmasq
```

模拟器桩掉宿主 DOM / shell 桥, 会**真跑一遍 `doInstall`** —— 把插件分块写进 `.b64.tmp` 的 base64 拼回来,
解码解包, 校验内嵌包成员是否齐全、权限对不对(`bin/dnsmasq` 缺执行位则 `run.sh` 的 `[ -x "$DM" ]` 判定失败,
DHCP/DNS 直接不启动)、以及字节是否与生成器产物一致; 另外查入口按钮/面板 id/单条 shell 命令行长度
(< `MAX_ARG_STRLEN` 128KB)。插件在宿主里加载失败是**静默**的, 这是交付前唯一能抓到的环节。

## 第三方组件说明

- **dnsmasq 2.90** (`bin-armv7/dnsmasq`): GPLv2。静态 armv7 构建, 源码为官方 2.90 tarball +
  Android 适配补丁(在 `src/dnsmasq.c` 的 user/group 解析前强制 `daemon->username=NULL; groupname=NULL; group_set=1;`,
  因为 Android 无 `/etc/passwd`)。按 GPLv2 要求, 需要源码者请开 issue 索取, 或自行按上述补丁编译。
- **hotspotctl.dex** (`bin-armv7/hotspotctl.dex`, 26KB): 从厂商 UFI Tools App (`com.minikano.f50_sms`) 的
  `assets/shell/` 提取的资产, 供 v1.7 热点守护调用 (走框架 `startTetheredHotspot` 重启热点, SoftAp 配置零漂移)。
  **版权归原厂商**, 此处仅为在自有设备上与本 App 互操作而附带; 如不适, 删除该文件 (或 `SKIP_DEX=1` 重新生成插件)
  后桥接其余功能不受影响, 只是热点守护会记一条 WARN 自行禁用。App 升级后用 `scripts/extract_hotspotctl.sh` 重新提取。

## 参考

- F50 (ZTE 出厂桥接机) 机制复刻: 同段双挂 + 路由四表 + kernel 路由压制
- 详见 `scripts/README.md` (每一步操作 / 作用 / 不做的后果 对照表, 以及 v1.4~v1.6 dnsmasq 自旋事故复盘)

## 已知限制

- `run.sh` 里蜂窝 IPv6 前缀的识别按 `2408::/16` (中国联通) 硬编码, 换运营商需同步修改 (搜索 `2408`)。
- 守护是 15s 轮询(Android 用户态没有可订阅的网络事件源), 非中断驱动。
- 未附开源许可证: 默认保留所有权利(第三方组件 dnsmasq 仍受 GPLv2 约束)。

## 免责声明

仅供在**自有设备**上使用。所有改动均为内存态, `run.sh -k` 或重启即还原; 但网络配置类改动存在失联风险,
请在能物理接触设备的前提下使用。
