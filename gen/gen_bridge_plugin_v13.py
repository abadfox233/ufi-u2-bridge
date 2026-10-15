#!/usr/bin/env python3
# 生成 kano_bridge UFI Tools 插件 (plugin/bridge_manager_v1.3.js.txt)
#
# 用法: python3 gen/gen_bridge_plugin_v13.py
#   默认从仓库内取源:
#     scripts/run.sh, scripts/off.sh, scripts/dnsmasq.conf, scripts/README.md, bin-armv7/dnsmasq
#     + bin-armv7/hotspotctl.dex (可选, 提取自 UFI Tools App — 见 scripts/extract_hotspotctl.sh)
#   环境变量:
#     SRC=<扁平目录>  兼容旧用法: 该目录需含 run.sh/off.sh/dnsmasq.conf/README.md/bin/dnsmasq
#     OUT=<路径>      输出路径 (默认 plugin/bridge_manager_v1.3.js.txt)
#     SKIP_DEX=1      不把 hotspotctl.dex 打进安装包
#   产物确定性: tar 元数据归零 + 文件顺序固定 + gzip mtime=0 → 重复运行字节一致
import base64, tarfile, io, os, sys, gzip, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC = os.environ.get("SRC")
OUT = os.environ.get("OUT", os.path.join(REPO, "plugin", "bridge_manager_v1.3.js.txt"))


def collect():
    """[(arcname, 源路径)] — 顺序固定"""
    if SRC:
        pairs = [("run.sh", "run.sh"), ("off.sh", "off.sh"), ("dnsmasq.conf", "dnsmasq.conf"),
                 ("README.md", "README.md"), ("bin/dnsmasq", "bin/dnsmasq")]
        return [(a, os.path.join(SRC, s)) for a, s in pairs]
    pairs = [("run.sh", "scripts/run.sh"), ("off.sh", "scripts/off.sh"),
             ("dnsmasq.conf", "scripts/dnsmasq.conf"), ("README.md", "scripts/README.md"),
             ("bin/dnsmasq", "bin-armv7/dnsmasq")]
    out = [(a, os.path.join(REPO, s)) for a, s in pairs]
    dex = os.path.join(REPO, "bin-armv7", "hotspotctl.dex")
    if os.path.exists(dex) and os.environ.get("SKIP_DEX") != "1":
        out.append(("bin/hotspotctl.dex", dex))
    return out


# 1. 打包 tar.gz (确定性: tar 元数据归零 + gzip mtime=0)
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tf:
    for arcname, path in collect():
        blob = open(path, "rb").read()
        ti = tarfile.TarInfo(arcname)
        ti.size, ti.mtime, ti.mode = len(blob), 0, 0o644
        ti.uid = ti.gid = 0
        tf.addfile(ti, io.BytesIO(blob))
data = gzip.compress(buf.getvalue(), compresslevel=9, mtime=0)
b64 = base64.b64encode(data).decode()
lines = [b64[i:i+400] for i in range(0, len(b64), 400)]
pkg_js = "const PKG_B64 = [\n" + ",\n".join("'" + l + "'" for l in lines) + "\n    ].join('')"
print(f"tar.gz={len(data)}B b64={len(b64)} chars lines={len(lines)} "
      f"sha256={hashlib.sha256(data).hexdigest()[:16]}", file=sys.stderr)

tpl = r'''<!-- [KANO_PLUGIN_START] 桥接管理_kano_bridge_v1.3.js -->
//<script>
(() => {
    // ============================================================
    // 桥接管理 (kano_bridge) v1.3 — WiFi/有线同网段桥接 (88.0/24, v4+v6) + DNS 劫持管理
    // 自包含: 内嵌 run.sh/off.sh/dnsmasq.conf/README + dnsmasq 2.90 armv7 静态
    // v1.2: 新增 DNS 劫持界面 — 增/删劫持条目, 一键重载生效
    //       劫持语法: address=/域名/IP  (IP 留空=屏蔽域名; 填 :: =屏蔽该域名 IPv6)
    // 规约: createModal+showModal, .actions-buttons+.btn, 300x120ms 等待,
    //       root 检查放点击时, onClose 清定时器, @@EOF@@ 分隔
    // ============================================================
    const MOD = "/data/kano_bridge"
    const BOOT = "/sdcard/ufi_tools_boot.sh"
    const RUN = MOD + "/run.sh"
    const HOSTS = MOD + "/dnsmasq.hosts.conf"

    const sh = async (cmd, timeout) => {
        try { return await runShellWithRoot(cmd, timeout) } catch (e) { return { success: false, content: String(e) } }
    }
    const shq = s => "'" + String(s).replace(/'/g, "'\\''") + "'"
    const checkRoot = async () => {
        const r = await sh('whoami')
        return r.success && (r.content || '').includes('root')
    }

    // ---------- 内嵌安装包 (tar.gz 的 base64) ----------
    __PKG_B64__

    const reloadDns = async () => {
        // 校验 hosts conf 语法后热重载 dnsmasq (不拆桥不断网)
        const t = await sh(MOD + '/bin/dnsmasq --test --conf-file=' + MOD + '/dnsmasq.conf 2>&1')
        if (!(t.content || '').includes('syntax check OK')) return { ok: false, err: (t.content || 'conf error').slice(0, 120) }
        const r = await sh(
            'P=$(cat ' + MOD + '/dnsmasq.pid 2>/dev/null); [ -n "$P" ] && kill $P 2>/dev/null; sleep 1; ' +
            MOD + '/bin/dnsmasq --conf-file=' + MOD + '/dnsmasq.conf && echo RELOADED')
        return { ok: (r.content || '').includes('RELOADED'), err: (r.content || '').slice(0, 120) }
    }

    const doInstall = async (setStatus) => {
        if (!(await checkRoot())) { setStatus('需要 root (高级功能)', true); return false }
        setStatus('写入安装包 (内嵌, 无需联网)...')
        let r = await sh('mkdir -p ' + MOD + '; echo -n > ' + MOD + '.b64.tmp')
        if (!r.success) return setStatus('创建临时文件失败: ' + (r.content || '').slice(0, 80), true)
        const chunk = 50000
        for (let i = 0; i < PKG_B64.length; i += chunk) {
            r = await sh('echo ' + shq(PKG_B64.slice(i, i + chunk)) + ' >> ' + MOD + '.b64.tmp')
            if (!r.success) return setStatus('写入b64失败 @' + i, true)
        }
        setStatus('解码并解压...')
        r = await sh(
            'base64 -d ' + MOD + '.b64.tmp > ' + MOD + '/pkg.tar.gz 2>/dev/null; ' +
            'cd ' + MOD + ' && tar xzf pkg.tar.gz 2>&1 && rm -f pkg.tar.gz ' + MOD + '.b64.tmp; ' +
            'mkdir -p ' + MOD + '/logs; ' +
            '[ -f ' + HOSTS + ' ] || echo "# DNS 劫持条目: address=/域名/IP" > ' + HOSTS + '; ' +
            'chmod 755 ' + MOD + ' ' + MOD + '/run.sh ' + MOD + '/off.sh ' + MOD + '/bin/dnsmasq 2>/dev/null; ' +
            'ls ' + MOD + '/ ' + MOD + '/bin/')
        if (!r.success || !(r.content || '').includes('dnsmasq')) return setStatus('解压失败: ' + (r.content || '').slice(0, 120), true)
        setStatus('冒烟测试 dnsmasq...')
        r = await sh(MOD + '/bin/dnsmasq --version 2>&1 | head -2')
        if (!(r.content || '').includes('Dnsmasq version')) return setStatus('dnsmasq 无法运行: ' + (r.content || '').slice(0, 100), true)
        setStatus('驯服 tether_guard (防与桥打架)...')
        await sh('[ -f /data/kano_tether_guard/guard.conf ] && { sed -i "s/^GUARD_ETHERNET=1/GUARD_ETHERNET=0/" /data/kano_tether_guard/guard.conf; G=$(cat /data/kano_tether_guard/guard.pid 2>/dev/null); [ -n "$G" ] && kill -9 $G 2>/dev/null; setsid /data/kano_tether_guard/service.sh boot >/dev/null 2>&1 & } ; true')
        setStatus('启动桥接 (等热点就绪, 最长约2分钟)...')
        r = await sh('sh ' + RUN + ' -s', 150 * 1000)
        // 无论 -s 成败都拉守护: 开机时热点可能未就绪导致 -s 失败, 守护循环会自动重建
        setStatus('启动守护 (若热点未就绪将自动重试)...')
        await sh('setsid sh ' + RUN + ' -d >/dev/null 2>&1 &')
        setStatus(r.success ? '安装完成 — 手机/Mac 重连即可拿 88.x + IPv6'
                            : '热点暂未就绪, 守护已启动将自动重试(约1-2分钟)')
        return true
    }

    // ---------- 状态采集 (单次 shell 批量) ----------
    async function probe() {
        const r = await sh(
            'INST=no; [ -x ' + MOD + '/bin/dnsmasq ] && INST=yes; ' +
            'BR=no; ip link show br0 >/dev/null 2>&1 && BR=yes; ' +
            'DM=no; [ -f ' + MOD + '/dnsmasq.pid ] && kill -0 $(cat ' + MOD + '/dnsmasq.pid) 2>/dev/null && DM=yes; ' +
            'Dae=no; [ -f ' + MOD + '/daemon.pid ] && kill -0 $(cat ' + MOD + '/daemon.pid) 2>/dev/null && Dae=yes; ' +
            'HS=no; grep -qF kano_bridge ' + BOOT + ' 2>/dev/null && HS=yes; ' +
            'V6=$(ip -6 addr show br0 2>/dev/null | grep -m1 "scope global" | awk "{print \$2}" | cut -d/ -f1); ' +
            'LC=$(grep -c "192.168.88" ' + MOD + '/leases 2>/dev/null); ' +
            'DNS=no; ss -uln 2>/dev/null | grep -q "192.168.88.1:53" && DNS=yes; ' +
            'HN=$(grep -vc "^#" ' + HOSTS + ' 2>/dev/null); ' +
            'echo "@@EOF@@"; echo "INST=$INST|BR=$BR|DM=$DM|Dae=$Dae|HS=$HS|DNS=$DNS|HN=${HN:-0}|V6=$V6|LC=${LC:-0}"')
        const p = {}
        const line = (r.content || '').split('@@EOF@@')[1].split('\n').find(l => l.indexOf('INST=') === 0) || ''
        line.split('|').forEach(kv => { const i = kv.indexOf('='); if (i > 0) p[kv.slice(0, i)] = kv.slice(i + 1).trim() })
        return p
    }

    // ---------- CSS (kbm- 前缀) ----------
    const injectCss = () => {
        if (document.getElementById('kbm-style')) return
        const css = document.createElement('style')
        css.id = 'kbm-style'
        css.textContent = `
            .kbm-grid { display:grid; grid-template-columns:96px 1fr; gap:6px 10px; font-size:12px; margin:10px 0; align-items:start; }
            .kbm-k { color:#9aa0a6; }
            .kbm-v { color:var(--dark-text-color,#e8eaed); font-family:monospace; word-break:break-all; }
            .kbm-dot { width:10px; height:10px; border-radius:50%; display:inline-block; flex:none; }
            .kbm-dot.on { background:#31c48d; box-shadow:0 0 6px #31c48d; }
            .kbm-dot.off { background:#f05252; }
            .kbm-dot.warn { background:#f5a623; box-shadow:0 0 6px #f5a623; }
            .kbm-card { background:rgba(255,255,255,.05); border:1px solid rgba(255,255,255,.1); border-radius:10px; padding:10px 12px; margin:10px 0; }
            .kbm-title { font-size:14px; font-weight:600; display:flex; align-items:center; gap:6px; margin-bottom:4px; }
            .kbm-sub { margin-left:auto; font-size:11px; color:#9aa0a6; font-weight:400; }
            .kbm-note { font-size:11px; color:#9aa0a6; margin-top:6px; line-height:1.6; }
            .kbm-btnrow { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
            .kbm-btn { background:#2d2f35; color:#e8eaed; border:1px solid #5f6368; border-radius:8px; padding:7px 14px; font-size:13px; cursor:pointer; }
            .kbm-btn:active { background:#3c4043; }
            .kbm-btn.primary { background:#1a4d33; border-color:#2e7d5b; }
            .kbm-btn.danger { background:#4d1a1a; border-color:#7d2e2e; }
            .kbm-btn:disabled { opacity:.5; }
            .kbm-log { background:#0d0e10; border-radius:8px; padding:10px; font-family:monospace; font-size:11px; line-height:1.5; max-height:220px; overflow:auto; white-space:pre-wrap; color:#9ecbff; margin-top:6px; text-align:left; }
            .kbm-status { font-size:12px; color:#8ab4f8; margin:8px 0; min-height:16px; text-align:left; }
            .kbm-hjrow { display:flex; align-items:center; gap:8px; padding:6px 0; border-bottom:1px solid rgba(255,255,255,.06); }
            .kbm-hjdom { color:#8ab4f8; font-family:monospace; font-size:12px; flex:1; word-break:break-all; text-align:left; }
            .kbm-hjip { color:#31c48d; font-family:monospace; font-size:12px; max-width:38%; word-break:break-all; text-align:right; }
            .kbm-hjtag { font-size:10px; padding:1px 6px; border-radius:4px; flex:none; }
            .kbm-hjtag.v6 { background:#3d2e1a; color:#f5a623; }
            .kbm-hjtag.block { background:#4d1a1a; color:#f05252; }
            .kbm-inrow { display:flex; gap:8px; margin-top:10px; }
            .kbm-input { flex:1; background:#0d0e10; color:#e8eaed; border:1px solid #5f6368; border-radius:8px; padding:7px 10px; font-size:12px; font-family:monospace; min-width:0; }
            .kbm-modal * { box-sizing:border-box; }
        `
        document.head.appendChild(css)
    }

    // ---------- 面板 ----------
    let modalOpen = false
    let refreshTimer = null

    async function openModal() {
        if (modalOpen) return
        injectCss()
        const { id, el } = createModal({
            name: 'bridge_manager',
            title: '桥接管理 · kano_bridge',
            maxWidth: '92%',
            showConfirm: false,
            onClose: () => { if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null } modalOpen = false; return true },
            content: `
                <div class="kbm-modal" id="kbm_root" style="font-size:.8rem">
                    <div class="kbm-status" id="kbm_status">读取状态中...</div>

                    <div class="kbm-card">
                        <div class="kbm-title"><span class="kbm-dot off" id="kbm_dot"></span>桥接状态<span class="kbm-sub">br0 = 192.168.88.1/24</span></div>
                        <div class="kbm-grid" id="kbm_grid"></div>
                        <div class="kbm-btnrow">
                            <button class="kbm-btn primary" id="kbm_install">安装/修复</button>
                            <button class="kbm-btn primary" id="kbm_start">启动</button>
                            <button class="kbm-btn danger" id="kbm_stop">停止(还原)</button>
                            <button class="kbm-btn" id="kbm_restart">重启</button>
                            <button class="kbm-btn" id="kbm_boot">自启: ?</button>
                            <button class="kbm-btn" id="kbm_log">运行日志</button>
                        </div>
                    </div>

                    <div class="kbm-card">
                        <div class="kbm-title">DNS 劫持<span class="kbm-sub" id="kbm_hjsub">88.1:53</span></div>
                        <div id="kbm_hjlist"><div class="kbm-note">读取中...</div></div>
                        <div class="kbm-inrow">
                            <input class="kbm-input" id="kbm_hjdom" placeholder="域名 如 example.com 或 sub.example.com">
                            <input class="kbm-input" id="kbm_hjip" placeholder="IP (留空=屏蔽, :: =禁v6)">
                            <button class="kbm-btn primary" id="kbm_hjadd" style="flex:none">添加</button>
                        </div>
                        <div class="kbm-note">IP 填法: 内网 IP = 劫持到该地址 · <b>::</b> = 屏蔽该域名的 IPv6(自动回落v4) · 留空 = 整个域名屏蔽(NXDOMAIN)。通配: 写 a.com 覆盖全部子域。改完自动热重载, 全客户端立即生效(与 Clash DNS 共存)。</div>
                    </div>

                    <div class="kbm-card">
                        <div class="kbm-title">DHCP 客户端<span class="kbm-sub">88.50–88.150</span></div>
                        <div id="kbm_leases"><div class="kbm-note">(空)</div></div>
                    </div>

                    <div class="kbm-card" id="kbm_logcard" style="display:none">
                        <div class="kbm-title">运行日志<span class="kbm-sub">logs/bridge.log + dnsmasq.log</span></div>
                        <div class="kbm-log" id="kbm_logbox">(空)</div>
                    </div>

                    <div class="kbm-note">原理: wlan0(AP)+eth0(有线) 二层桥接同网段, dnsmasq 发 DHCPv4+RA(v6)+DNS劫持; Clash 透明代理零冲突; 全内存态, 停止或重启即还原出厂网络。守护 15s 自愈。</div>
                </div>
            `,
        })
        if (!el) return createToast('无法创建界面', 'red')
        modalOpen = true
        showModal(id)
        const $ = s => el.querySelector(s)

        const renderGrid = (rows) => {
            const g = $('#kbm_grid')
            g.innerHTML = ''
            rows.forEach(([k, v]) => {
                const kd = document.createElement('div'); kd.className = 'kbm-k'; kd.textContent = k
                const vd = document.createElement('div'); vd.className = 'kbm-v'; vd.textContent = v
                g.appendChild(kd); g.appendChild(vd)
            })
        }

        async function refresh() {
            const p = await probe()
            const st = $('#kbm_status')
            if (p.INST !== 'yes') {
                $('#kbm_dot').className = 'kbm-dot off'
                renderGrid([['状态', '未安装 — 点「安装/修复」(内嵌包, 离线可装)']])
                st.textContent = ''
                return
            }
            const rows = []
            if (p.BR === 'yes' && p.DM === 'yes') {
                $('#kbm_dot').className = 'kbm-dot on'
                rows.push(['状态', '● 桥接运行中 (br0 + DHCP' + (p.Dae === 'yes' ? ' + 守护' : '') + ')'])
            } else if (p.BR === 'yes') {
                $('#kbm_dot').className = 'kbm-dot warn'
                rows.push(['状态', '▲ 桥在但 dnsmasq 停 — 点「重启」'])
            } else {
                $('#kbm_dot').className = 'kbm-dot off'
                rows.push(['状态', '○ 未启用 (出厂网络)'])
            }
            rows.push(['网段', '192.168.88.0/24 (WiFi+有线同段)'])
            rows.push(['IPv6', p.V6 ? p.V6.split('::')[0] + '::/64 (SLAAC+RA)' : '(无 — 桥未运行或蜂窝无v6)'])
            rows.push(['DNS劫持', p.DNS === 'yes' ? '生效中 · ' + (p.HN || '0') + ' 条规则' : '(桥未运行)'])
            rows.push(['客户端', (p.LC || '0') + ' 台在线租约'])
            rows.push(['守护', p.Dae === 'yes' ? '运行中 (15s 自愈)' : '未运行'])
            renderGrid(rows)
            $('#kbm_boot').textContent = '自启: ' + (p.HS === 'yes' ? '开' : '关')
            $('#kbm_hjsub').textContent = (p.DNS === 'yes' ? '● ' : '') + '88.1:53 · ' + (p.HN || '0') + ' 条'
            st.textContent = '更新于 ' + new Date().toTimeString().slice(0, 8)
        }

        async function refreshHijack() {
            const r = await sh('cat ' + HOSTS + ' 2>/dev/null; echo @@EOF@@')
            const lines = (r.content || '').split('@@EOF@@')[0].split('\n')
                .map(s => s.trim()).filter(l => l && !l.startsWith('#'))
            const box = $('#kbm_hjlist')
            box.innerHTML = ''
            if (!lines.length) { box.innerHTML = '<div class="kbm-note">(暂无劫持条目 — 在下方添加)</div>'; return }
            lines.forEach(line => {
                const m = line.match(/^address=\/([^/]+)\/(.*)$/)
                if (!m) return
                const dom = m[1], ip = m[2]
                const row = document.createElement('div'); row.className = 'kbm-hjrow'
                const d = document.createElement('div'); d.className = 'kbm-hjdom'; d.textContent = dom
                const tag = document.createElement('span'); tag.className = 'kbm-hjtag'
                let ipText = ip
                if (ip === '::') { tag.className += ' v6'; tag.textContent = '禁v6' }
                else if (!ip) { tag.className += ' block'; tag.textContent = '屏蔽'; ipText = '—' }
                else { tag.style.display = 'none' }
                const v = document.createElement('div'); v.className = 'kbm-hjip'; v.textContent = ipText || '—'
                const del = document.createElement('button'); del.className = 'kbm-btn danger'; del.textContent = '删'
                del.style.cssText = 'flex:none;padding:3px 10px;font-size:11px'
                del.onclick = async () => {
                    del.disabled = true
                    await sh('sed -i ' + shq('/^address=\\/' + dom.replace(/\./g, '\\.') + '\\//d') + ' ' + HOSTS + '; true')
                    const rr = await reloadDns()
                    createToast(rr.ok ? '已删除并重载' : '重载失败: ' + rr.err, rr.ok ? undefined : 'red')
                    await refreshHijack(); await refresh()
                }
                row.appendChild(d); row.appendChild(tag); row.appendChild(v); row.appendChild(del)
                box.appendChild(row)
            })
        }

        async function refreshLeases() {
            const r = await sh('cat ' + MOD + '/leases 2>/dev/null; echo @@EOF@@')
            const lines = (r.content || '').split('@@EOF@@')[0].split('\n').filter(l => l.includes('192.168.88'))
            const box = $('#kbm_leases')
            box.innerHTML = ''
            if (!lines.length) { box.innerHTML = '<div class="kbm-note">(暂无客户端)</div>'; return }
            lines.forEach(l => {
                const parts = l.trim().split(/\s+/)
                const d = document.createElement('div'); d.className = 'kbm-v'
                d.textContent = parts[3] + '  ' + parts[2] + '  ' + parts[1]
                d.style.padding = '3px 0'
                box.appendChild(d)
            })
        }

        const busy = async (btn, fn) => {
            const old = btn.textContent
            btn.textContent = '执行中…'; btn.disabled = true
            try { await fn() } catch (e) { createToast('执行出错: ' + String(e).slice(0, 80), 'red') }
            btn.textContent = old; btn.disabled = false
            await refresh(); await refreshLeases(); await refreshHijack()
        }

        $('#kbm_hjadd').onclick = () => busy($('#kbm_hjadd'), async () => {
            const dom = ($('#kbm_hjdom').value || '').trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '').toLowerCase()
            const ip = ($('#kbm_hjip').value || '').trim()
            if (!dom || !/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/.test(dom)) return createToast('域名格式不对', 'red')
            if (ip && !/^([0-9.]+|[0-9a-f:]+)$/.test(ip)) return createToast('IP 格式不对', 'red')
            const entry = 'address=/' + dom + '/' + ip
            const dup = await sh('grep -qxF ' + shq(entry) + ' ' + HOSTS + ' 2>/dev/null && echo DUP')
            if ((dup.content || '').includes('DUP')) return createToast('该条目已存在')
            await sh('mkdir -p ' + MOD + '; [ -f ' + HOSTS + ' ] || echo "# DNS hijack" > ' + HOSTS + '; echo ' + shq(entry) + ' >> ' + HOSTS)
            const rr = await reloadDns()
            if (!rr.ok) {
                await sh('sed -i ' + shq('/^address=\\/' + dom.replace(/\./g, '\\.') + '\\//d') + ' ' + HOSTS + '; true')
                return createToast('配置无效已回滚: ' + rr.err, 'red')
            }
            $('#kbm_hjdom').value = ''; $('#kbm_hjip').value = ''
            createToast('已生效: ' + dom + (ip ? ' → ' + ip : ' (屏蔽)'))
        })

        $('#kbm_install').onclick = () => busy($('#kbm_install'), async () => {
            const ok = await doInstall((msg, isErr) => {
                $('#kbm_status').textContent = msg
                if (isErr) createToast(msg, 'red', 8000)
            })
            if (!ok) throw new Error('install failed')
        })
        $('#kbm_start').onclick = () => busy($('#kbm_start'), async () => {
            const chk = await sh('[ -x ' + MOD + '/bin/dnsmasq ]')
            if (!chk.success) return createToast('未安装, 先点「安装/修复」', 'red')
            const r = await sh('sh ' + RUN + ' -s', 150 * 1000)
            if (!r.success) createToast('热点未就绪, 守护将自动重试', 'yellow')
            await sh('setsid sh ' + RUN + ' -d >/dev/null 2>&1 &')
        })
        $('#kbm_stop').onclick = () => busy($('#kbm_stop'), async () => {
            await sh('sh ' + RUN + ' -k; true')
            createToast('已停止, 网络还原出厂 (重启效果相同)')
        })
        $('#kbm_restart').onclick = () => busy($('#kbm_restart'), async () => {
            await sh('sh ' + RUN + ' -r', 180 * 1000)
            await sh('setsid sh ' + RUN + ' -d >/dev/null 2>&1 &')
        })
        $('#kbm_boot').onclick = () => busy($('#kbm_boot'), async () => {
            const r = await sh(
                'grep -qF kano_bridge ' + BOOT + ' 2>/dev/null && FOUND=yes || FOUND=no; ' +
                'if [ "$FOUND" = yes ]; then sed -i "/kano_bridge/d;/run.sh -s/d;/run.sh -d/d" ' + BOOT + '; echo REMOVED; ' +
                'else printf "\\nsh ' + RUN + ' -s >/dev/null 2>&1\\nsetsid sh ' + RUN + ' -d >/dev/null 2>&1 &\\n" >> ' + BOOT + '; echo ADDED; fi')
            createToast((r.content || '').includes('ADDED') ? '已开启开机自启' : '已关闭开机自启')
        })
        $('#kbm_log').onclick = async () => {
            const card = $('#kbm_logcard')
            const show = card.style.display === 'none'
            card.style.display = show ? 'block' : 'none'
            if (show) {
                const r = await sh('echo "=== bridge.log ==="; tail -n 30 ' + MOD + '/logs/bridge.log 2>/dev/null; echo; echo "=== dnsmasq.log ==="; tail -n 20 ' + MOD + '/logs/dnsmasq.log 2>/dev/null')
                $('#kbm_logbox').textContent = (r.content || '(无日志 — 服务可能未启动过)')
            }
        }

        await refresh()
        await refreshHijack()
        await refreshLeases()
        refreshTimer = setInterval(async () => {
            if (!modalOpen || !document.body.contains(el)) { clearInterval(refreshTimer); refreshTimer = null; return }
            await refresh(); await refreshLeases()
        }, 10000)
    }

    // ---------- 入口按钮 ----------
    const mainBtn = document.createElement('button')
    mainBtn.classList.add('btn')
    mainBtn.textContent = '桥接管理'
    mainBtn.onclick = openModal

    const mountBtn = async () => {
        for (let i = 0; i < 300; i++) {
            const box = document.querySelector('.actions-buttons')
            if (box) {
                if (!box.contains(mainBtn)) box.appendChild(mainBtn)
                return
            }
            await new Promise(r => setTimeout(r, 120))
        }
        console.warn('[桥接管理] 未找到 .actions-buttons, 入口未挂载')
    }
    mountBtn()
})()
//</script>
<!-- [KANO_PLUGIN_END] 桥接管理_kano_bridge_v1.3.js -->
'''

out = tpl.replace("__PKG_B64__", pkg_js)
with open(OUT, "w") as f:
    f.write(out)
print(f"plugin written: {OUT} ({len(out)} bytes)", file=sys.stderr)
