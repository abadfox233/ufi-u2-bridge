#!/usr/bin/env node
/**
 * 桥接管理(kano_bridge)插件宿主模拟器 — 交付前功能验证
 * 用法: node plugin_harness_bridge.js <plugin.js.txt> [ok|nodnsmasq]
 *
 * 它不只查语法: 它**真跑一遍 doInstall** —— 把插件分块写入的 base64 全量拼回来,
 * 解码 + 解 tar, 校验成员/权限/字节是否等于内嵌包, 并检查状态采集与面板渲染。
 * 理由: 插件加载失败/安装链断是静默的(宿主无控制台), 只有模拟器能在交付前抓到。
 */
const fs = require('fs');
const zlib = require('zlib');

const FILE = process.argv[2];
const MODE = process.argv[3] || 'ok';
if (!FILE) { console.error('用法: node plugin_harness_bridge.js <插件.js.txt> [ok|nodnsmasq]'); process.exit(2); }

// ---- 1. 提取脚本体 + 内嵌包(作为"标准答案") ----
const raw = fs.readFileSync(FILE, 'utf8');
const m = raw.match(/\/\/<script>\n([\s\S]*?)\n\/\/<\/script>/);
if (!m || m[1].length < 500) { console.error('❌ 无法提取脚本体 — 检查 //<script> / //</script> 成对且紧跟 START 标记'); process.exit(1); }
const inner = m[1];
const pk = raw.match(/const PKG_B64 = \[\n([\s\S]*?)\n\s*\]\.join\(''\)/);
if (!pk) { console.error('❌ 找不到内嵌 PKG_B64'); process.exit(1); }
const PKG_B64 = [...pk[1].matchAll(/'([^']*)'/g)].map(x => x[1]).join('');
const PKG = Buffer.from(PKG_B64, 'base64');
const gunzipped = zlib.gunzipSync(PKG);
console.log(`内嵌包: base64=${PKG_B64.length} 字节, 解压后 tar=${gunzipped.length} 字节`);

// ---- 2. 假 DOM ----
const els = {}, injected = [], created = [];
function mkEl(id) {
  return {
    id, style: {}, textContent: '', title: '', value: '', children: [], classList: { add() {}, remove() {}, contains: () => false },
    appendChild(c) { this.children.push(c); if (c.id) els['#' + c.id] = c; return c; },
    contains(c) { return this.children.includes(c) || this === c; },
    removeChild(c) { this.children = this.children.filter(x => x !== c); },
    focus() {}, blur() {}, remove() {}, click() { if (typeof this.onclick === 'function') this.onclick(); },
    addEventListener() {}, removeEventListener() {},
    insertAdjacentHTML(pos, html) { injected.push(html); for (const mm of html.matchAll(/id="([^"]+)"/g)) els['#' + mm[1]] = mkEl(mm[1]); },
    querySelector(sel) { return els[sel] || null; },
  };
}
els['.actions-buttons'] = mkEl('ab');
els['.functions-container'] = mkEl('fc');
global.document = {
  body: mkEl('body'), head: mkEl('head'),
  getElementById: id => els['#' + id] || null,
  querySelector: sel => els[sel] || null,
  createElement: tag => { const e = mkEl('created-' + tag); e.tagName = tag; created.push(e); return e; },
  addEventListener() {},
};
global.location = { hostname: '192.168.88.1', origin: 'http://192.168.88.1:2333' };
global.window = global;
global.localStorage = { _d: {}, getItem(k) { return this._d[k] ?? null; }, setItem(k, v) { this._d[k] = v; } };

// ---- 3. 宿主 API 桩件 (真实模拟盒子侧 shell) ----
const calls = [], toasts = [];
let b64buf = '';          // 模拟 MOD.b64.tmp
let installed = null;     // 模拟解包结果
const LSRC = './bin/dnsmasq ./bin/hotspotctl.dex ./run.sh ./off.sh ./dnsmasq.conf ./README.md';
global.createToast = (msg, color) => { toasts.push([msg, color]); };
global.createFixedToast = global.createToast;
global.collapseGen = () => {};
global.requestInterval = (fn) => { return () => {}; };
global.createModal = ({ name, title, content, onClose }) => {
  const el = mkEl('modal');
  el.querySelector = sel => els[sel] || null;
  el.insertAdjacentHTML('beforeend', content);
  return { id: 'modal', el };
};
global.showModal = () => calls.push(['showModal']);

global.runShellWithRoot = async (cmd) => {
  calls.push(['sh', cmd]);
  const ok = c => ({ success: true, content: c });

  // 安装: 分块写入
  if (/echo -n > \/data\/kano_bridge\.b64\.tmp/.test(cmd)) { b64buf = ''; return ok(''); }
  const app = cmd.match(/^echo '([A-Za-z0-9+/=]+)' >> \/data\/kano_bridge\.b64\.tmp$/);
  if (app) {
    if (app[1].length > 50000) return { success: false, content: 'argv too long' };
    b64buf += app[1];
    return ok('');
  }
  // 安装: 解码 + 解包
  if (/base64 -d \/data\/kano_bridge\.b64\.tmp/.test(cmd)) {
    try {
      const gz = Buffer.from(b64buf, 'base64');
      const tar = zlib.gunzipSync(gz);
      installed = tar;                       // 原始 tar 字节, 下面逐段解析
      const names = parseTar(tar).map(f => f.name);
      if (MODE === 'nodnsmasq') return { success: false, content: 'tar: not found' };
      return ok(names.map(n => './' + n).join(' ') + '\n');
    } catch (e) { return { success: false, content: 'decode fail: ' + e.message }; }
  }
  if (/bin\/dnsmasq --version/.test(cmd)) {
    return MODE === 'nodnsmasq' ? { success: false, content: 'not found' } : ok('Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley\n');
  }
  if (/kano_tether_guard\/guard\.conf/.test(cmd)) return ok('');
  if (/run\.sh -s/.test(cmd)) return ok('bridge up\n@@EOF@@\n');
  if (/run\.sh -d/.test(cmd)) return ok('');
  if (/run\.sh -k|run\.sh -r/.test(cmd)) return ok('ok\n@@EOF@@\n');
  if (/whoami/.test(cmd)) return ok('root\n');
  // 状态采集 probe(): 一次 shell 批量
  if (/INST=/.test(cmd)) {
    return ok('INST=yes\nBR=yes\nDM=yes\nDae=yes\nHS=yes\nV6=2408:8400:8:1::1\nLC=2\nDNS=yes\n@@EOF@@\n');
  }
  if (/dnsmasq\.hosts\.conf/.test(cmd)) return ok('');
  return ok('');
};

// 极简 tar 解析(只取文件名 + mode + 内容)
function parseTar(buf) {
  const out = []; let off = 0;
  while (off + 512 <= buf.length) {
    const hdr = buf.slice(off, off + 512);
    const name = hdr.slice(0, 100).toString().replace(/\0.*$/, '');
    if (!name) break;
    const mode = parseInt(hdr.slice(100, 108).toString().replace(/\0.*$/, '').trim() || '0', 8);
    const size = parseInt(hdr.slice(124, 136).toString().replace(/\0.*$/, '').trim() || '0', 8);
    const type = hdr.slice(156, 157).toString();
    const data = buf.slice(off + 512, off + 512 + size);
    out.push({ name, mode, size, type, data });
    off += 512 + Math.ceil(size / 512) * 512;
  }
  return out;
}

// ---- 4. 跑插件 ----
(async () => {
  let thrown = null;
  try { await new Function(inner)(); } catch (e) { thrown = e; }
  await new Promise(r => setTimeout(r, 500));

  const fails = [];
  const ok = (cond, label, extra = '') => { console.log(`  ${cond ? '✅' : '❌'} ${label}${extra ? ' → ' + extra : ''}`); if (!cond) fails.push(label); };

  console.log('=== 1) IIFE 无异常(静默失败第一现场) ===');
  ok(!thrown, '无异常', thrown ? (thrown.stack || thrown).toString().split('\n').slice(0, 2).join(' | ') : '');

  console.log('=== 2) 点入口按钮 → 面板 HTML ===');
  const entry = created.find(b => b.textContent === '桥接管理');
  ok(!!entry, '主按钮已创建', created.map(b => b.textContent).join('/'));
  if (entry) { entry.onclick(); await new Promise(r => setTimeout(r, 400)); }
  const ids = injected.flatMap(h => [...h.matchAll(/id="([^"]+)"/g)].map(x => x[1]));
  const missing = ids.filter(id => !els['#' + id]);
  ok(ids.length > 5 && missing.length === 0, `${ids.length} 个面板 id 全可查`, missing.join(','));

  console.log('=== 3) 真跑安装流 (doInstall 全链路) ===');
  const btns = ['kbm_install', 'kbm_start', 'kbm_stop', 'kbm_restart', 'kbm_boot'];
  const missBtn = btns.filter(b => !els['#' + b] || typeof els['#' + b].onclick !== 'function');
  ok(missBtn.length === 0, '五个动作按钮都绑了 onclick', missBtn.join(','));
  els['#kbm_install'].onclick();
  await new Promise(r => setTimeout(r, 300));

  const writes = calls.filter(c => c[0] === 'sh' && />> \/data\/kano_bridge\.b64\.tmp$/.test(c[1]));
  const total = writes.reduce((a, c) => a + (c[1].match(/^echo '([A-Za-z0-9+/=]+)'/) || [, ''])[1].length, 0);
  ok(total === PKG_B64.length, `分块写入字节数完整 ${total}/${PKG_B64.length}`);
  ok(writes.length > 1, `确实分块(${writes.length} 块)`);
  const decoded = installed ? parseTar(installed) : [];
  ok(b64buf === PKG_B64, '拼回的 base64 与内嵌包逐字节一致');
  if (installed) {
    const tarExactly = Buffer.from(installed).equals(gunzipped);
    ok(tarExactly, '解出的 tar 与内嵌包解压结果逐字节一致');
    const names = decoded.map(f => f.name);
    const modes = Object.fromEntries(decoded.map(f => [f.name, f.mode & 0o777]));
    console.log('     成员:', names.join(', '));
    console.log('     权限:', JSON.stringify(modes));
    ok(['run.sh', 'off.sh', 'dnsmasq.conf', 'README.md', 'bin/dnsmasq', 'bin/hotspotctl.dex'].every(n => names.includes(n)),
       '成员齐全(含 bin/hotspotctl.dex)');
    ok(modes['bin/dnsmasq'] && (modes['bin/dnsmasq'] & 0o111) !== 0, 'bin/dnsmasq 可执行位在(否则 run.sh 的 -x 判定不通过, DHCP/DNS 不启动)');
    ok(modes['run.sh'] && (modes['run.sh'] & 0o111) !== 0, 'run.sh 可执行位在');
    ok(modes['bin/hotspotctl.dex'] !== undefined && (modes['bin/hotspotctl.dex'] & 0o111) === 0, 'hotspotctl.dex 0644(app_process 读文件不需执行位)');
    const dexInTar = decoded.find(f => f.name === 'bin/hotspotctl.dex');
    // dex 是可选成员(生成器 SKIP_DEX=1 时不含) → 按仓库里有没有该文件自适应判定, 路径按脚本位置解析
    const dexPath = require('path').join(__dirname, '..', 'bin-armv7', 'hotspotctl.dex');
    const dexExists = fs.existsSync(dexPath);
    if (dexExists) {
      ok(!!dexInTar && dexInTar.size === fs.statSync(dexPath).size, '内嵌 dex 与仓库文件一致', String(dexInTar && dexInTar.size));
    } else {
      ok(!dexInTar, '(仓库无 hotspotctl.dex) 内嵌包也不含它');
    }
  } else ok(false, '解码解包成功');
  const lastAfter = calls.filter(c => c[0] === 'sh').slice(-4).map(c => String(c[1]).replace(/\s+/g, ' ').slice(0, 70));
  console.log('     安装流尾部 shell:', JSON.stringify(lastAfter, null, 0));
  ok(!toasts.some(t => /失败|出错|无法/.test(String(t[0]))), '全流程无错误 toast', JSON.stringify(toasts.slice(-2)));

  console.log('=== 4) 真实 shell 约束 ===');
  const cmdLens = calls.filter(c => c[0] === 'sh').map(c => String(c[1]).length);
  ok(Math.max(...cmdLens) < 128 * 1024, `单条 shell 命令行最长 ${Math.max(...cmdLens)} B < MAX_ARG_STRLEN 128KB`);
  ok(!calls.some(c => c[0] === 'sh' && /127\.0\.0\.1/.test(c[1])), '未误用 127.0.0.1');
  ok(!/fetch\(/.test(inner), '插件不依赖网络(fetch) —— 离线可装');

  if (MODE === 'nodnsmasq') console.log('\n(本次为负向模式 nodnsmasq: 期望上面第 3 组出现失败上报)');
  console.log('\n' + (fails.length ? `❌ 未通过 ${fails.length} 项: ${fails.join(' | ')}` : '✅ 全部检查通过'));
  process.exit(fails.length ? 1 : 0);
})();
