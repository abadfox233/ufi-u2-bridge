#!/system/bin/sh
# extract_hotspotctl.sh — 从 UFI Tools App 提取 hotspotctl.dex 到 kano_bridge/bin/
# 背景: v1.7 热点守护用 HotspotCtl restart 恢复热点 (走框架 startTetheredHotspot,
#       保存的 SoftApConfiguration 原样生效, 配置零漂移)。dex 是 UFI Tools App 内置资产,
#       App 重装/升级后若行为变化, 重跑本脚本即可重新提取。
# 用法: 在 U20 设备上以 root 执行: sh extract_hotspotctl.sh
set -e
DEST="/data/kano_bridge/bin"
APP_PKG="com.minikano.f50_sms"
ASSET="assets/shell/hotspotctl.dex"

APK=$(pm path "$APP_PKG" | sed 's/package://' | head -1)
[ -n "$APK" ] || { echo "ERROR: $APP_PKG not installed"; exit 1; }
mkdir -p "$DEST"
unzip -o -j "$APK" "$ASSET" -d "$DEST" >/dev/null
chmod 644 "$DEST/hotspotctl.dex"
echo "OK: $DEST/hotspotctl.dex ($(wc -c < "$DEST/hotspotctl.dex") bytes)"
echo "验证: CLASSPATH=$DEST/hotspotctl.dex app_process / HotspotCtl status"
echo "  (需先 export BOOTCLASSPATH, 见 run.sh hotspot_guard)"
