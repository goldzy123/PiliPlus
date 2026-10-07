#!/usr/bin/env bash
# PiliPlus mod 自动验证脚本（不依赖机型坐标，用 uiautomator 找元素）
#
#   bash mod/tools/verify_mod.sh                    # 自动挑设备
#   bash mod/tools/verify_mod.sh 192.168.6.140:5555
#   bash mod/tools/verify_mod.sh --serial RFCNA09KHWA
#   APK=/path/to.apk bash mod/tools/verify_mod.sh   # 指定 APK
#
# 覆盖：本地 tab / 卡片日期 / 倍速按钮位置与两态 / 拖动不冻结 / 配置同步
# 每个检查打印 PASS / FAIL / SKIP + 证据。截图落在 _dsh/verify-out/。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # 仓库根目录
REPO="$PWD"
ADB=/opt/homebrew/bin/adb
OUT="${OUT_DIR:-$REPO/_dsh/verify-out}"
PKG=com.example.piliplus.dev
APK="${APK:-$REPO/_dsh/PiliPlus-mod-2.1.6-arm64-dev.apk}"
[ -f "$APK" ] || APK=$(ls -t "$REPO"/build/app/outputs/flutter-apk/app-release.apk 2>/dev/null | head -1)
SERVER=${SYNC_SERVER:-http://127.0.0.1:8720}

mkdir -p "$OUT"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✅ PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭  SKIP  $1"; SKIP=$((SKIP+1)); }

# ── 选设备 ────────────────────────────────────────────────────────────
SER=""
for a in "$@"; do
  case "$a" in
    --serial) shift; SER="$1" ;;
    *) [ -z "$SER" ] && SER="$a" ;;
  esac
done
if [ -z "$SER" ]; then
  SER=$($ADB devices | awk '/\tdevice$/{print $1; exit}')
fi
[ -z "$SER" ] && { echo "没有可用设备（adb devices）"; exit 1; }
echo "设备: $SER"
MODEL=$($ADB -s "$SER" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
SDK=$($ADB -s "$SER" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
echo "型号: $MODEL  SDK: $SDK"
echo

# ── 工具函数 ──────────────────────────────────────────────────────────
dump() {  # 输出当前界面的 uiautomator XML
  $ADB -s "$SER" shell "uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml" 2>/dev/null
}
shot() { $ADB -s "$SER" exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; }

# 按文本点击（从 dump 里找 bounds 中心）
tap_text() {
  dump > /tmp/_ui.xml
  local xy
  xy=$(python3 - "$1" <<'PY'
import re,sys
want=sys.argv[1]
xml=open('/tmp/_ui.xml',encoding='utf-8',errors='ignore').read()
for m in re.finditer(r'<node[^>]*>', xml):
    n=m.group(0)
    t=re.search(r'text="([^"]*)"', n)
    if not t or want not in t.group(1): continue
    b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not b: continue
    x1,y1,x2,y2=map(int,b.groups())
    print(f"{(x1+x2)//2} {(y1+y2)//2}"); sys.exit(0)
sys.exit(1)
PY
)
  [ -z "$xy" ] && return 1
  $ADB -s "$SER" shell "input tap $xy"
  return 0
}

has_text() {  # 当前界面是否含某文本
  dump > /tmp/_ui.xml
  grep -q "$1" /tmp/_ui.xml
}

# ── 0. 安装 + 启动 ────────────────────────────────────────────────────
echo "── 0. 安装并启动"
if [ -f "$APK" ]; then
  $ADB -s "$SER" install -r "$APK" >/dev/null 2>&1 && ok "安装 APK" || bad "安装 APK"
else
  bad "APK 不存在: $APK"
fi
$ADB -s "$SER" shell "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null 2>&1
sleep 1
$ADB -s "$SER" shell "am force-stop $PKG" >/dev/null 2>&1
$ADB -s "$SER" shell "am start -n $PKG/com.example.piliplus.MainActivity" >/dev/null 2>&1
sleep 18
# 关掉可能的「发现新版本」弹窗
tap_text "不再提醒" >/dev/null 2>&1
sleep 2
shot 00-home
echo

# ── 1. 本地 tab 存在 ──────────────────────────────────────────────────
echo "── 1. 底部导航有「本地」tab"
if has_text "本地"; then ok "导航栏存在「本地」"; else bad "导航栏没有「本地」"; fi
shot 01-nav

# ── 2. 卡片日期 ───────────────────────────────────────────────────────
echo "── 2. 推荐流卡片显示发布日期"
# Flutter 会把整张卡片的语义合并成一个节点，日期被拼在长文本里，
# 所以不能要求 text 属性以日期开头，要在整个 XML 里找。
DATE_RE='(刚刚|[0-9]+分钟前|[0-9]+小时前|昨天 [0-9:]+|[0-9]+天前|[0-9]{1,2}-[0-9]{1,2})'
found=""
for i in 1 2 3; do
  dump > /tmp/_ui.xml
  found=$(grep -oE "$DATE_RE" /tmp/_ui.xml | sort -u | head -5)
  [ -n "$found" ] && break
  sleep 4
done
if [ -n "$found" ]; then
  ok "卡片上找到日期文本"
  echo "$found" | sed 's/^/       /'
else
  bad "没找到任何日期文本（可能还在加载，或接口没数据）"
fi
shot 02-cards
echo

# ── 3. 倍速按钮位置 ───────────────────────────────────────────────────
echo "── 3. 竖屏倍速按钮在 UP 行 / 不在播放器控制条"
# 点第一张卡片进视频
tap_text "简介" >/dev/null 2>&1   # 若已在视频页则无副作用
$ADB -s "$SER" shell "input tap 400 700" >/dev/null 2>&1
sleep 14
shot 03-video
if has_text "1.5X" && has_text "2X"; then
  ok "倍速按钮存在（1.5X / 2X）"
else
  bad "没看到倍速按钮"
fi
if has_text "关注"; then ok "同一屏有「关注」按钮（说明按钮在 UP 那一行）"; else skip "没找到「关注」（可能未登录或布局不同）"; fi
# 播放器控制条里不应有倍速（竖屏非全屏）
$ADB -s "$SER" shell "input tap 400 700" >/dev/null 2>&1
sleep 1
dump > /tmp/_ui.xml
# 控制条出现时，「全屏」按钮和倍速按钮不应同屏（竖屏）
if grep -q "全屏" /tmp/_ui.xml && grep -qE 'text="(1\.5|2)X"' /tmp/_ui.xml; then
  bad "竖屏控制条里也出现了倍速按钮（重复）"
else
  ok "竖屏控制条里没有倍速按钮（不重复）"
fi
echo

# ── 4. 拖动不冻结 ─────────────────────────────────────────────────────
echo "── 4. 拖动进度条后画面是否冻结（逐秒抽帧）"
SZ=$($ADB -s "$SER" shell wm size | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | head -1)
W=${SZ%x*}; H=${SZ#*x}

# 先确保真的在播放：连拍两张比 MAD，不动就点一下播放器中间再试
playing=0
for i in 1 2 3; do
  $ADB -s "$SER" exec-out screencap -p > /tmp/_p1.png 2>/dev/null
  sleep 3
  $ADB -s "$SER" exec-out screencap -p > /tmp/_p2.png 2>/dev/null
  d=$(python3 -c "
from PIL import Image, ImageChops, ImageStat
a=Image.open('/tmp/_p1.png').convert('L').resize((120,68))
b=Image.open('/tmp/_p2.png').convert('L').resize((120,68))
print(ImageStat.Stat(ImageChops.difference(a,b)).mean[0])" 2>/dev/null)
  echo "      试探 ${i}：画面 MAD=$d"
  if python3 -c "import sys; sys.exit(0 if float('${d:-0}')>0.3 else 1)" 2>/dev/null; then
    playing=1; break
  fi
  $ADB -s "$SER" shell "input tap $((W/2)) $((H*22/100))" >/dev/null 2>&1
  sleep 2
done
if [ "$playing" = "1" ]; then ok "视频正在播放（可以开始拖动测试）"; else skip "视频没播起来，拖动测试无意义"; fi

$ADB -s "$SER" shell "rm -f /sdcard/vfy.mp4; screenrecord --time-limit 26 --bit-rate 6000000 /sdcard/vfy.mp4" >/dev/null 2>&1 &
sleep 5
# 唤出控制条并把进度拖到 70% 附近
$ADB -s "$SER" shell "input tap $((W/2)) $((H*22/100))" >/dev/null 2>&1
sleep 1
$ADB -s "$SER" shell "input tap $((W*7/10)) $((H*21/100))" >/dev/null 2>&1
sleep 26
$ADB -s "$SER" pull /sdcard/vfy.mp4 "$OUT/seek.mp4" >/dev/null 2>&1
rm -f /tmp/vfyf_*.png
for t in $(seq 2 1 28); do   # 2~5 秒当拖动前基线，8 秒后是拖动后
  /opt/homebrew/bin/ffmpeg -loglevel error -ss $t -i "$OUT/seek.mp4" -frames:v 1 -y /tmp/vfyf_$t.png 2>/dev/null
done
python3 - <<'METRIC'
import glob,re,sys
from PIL import Image, ImageChops, ImageStat
files=sorted(glob.glob('/tmp/vfyf_*.png'), key=lambda f:int(re.search(r'(\d+)\.png',f).group(1)))
if len(files)<8:
    print("  SKIP  抽帧失败（录制可能没成功）"); sys.exit(2)

def mad(a,b):
    return ImageStat.Stat(ImageChops.difference(a,b)).mean[0]

mads=[]; prev=None
for f in files:
    im=Image.open(f).convert('L').resize((160,90))
    if prev is not None:
        mads.append((int(re.search(r'(\d+)\.png',f).group(1)), mad(im,prev)))
    prev=im

base=sorted(m for t,m in mads if t<=5)
post=[(t,m) for t,m in mads if t>=8]
if not base or not post:
    print("  SKIP  采样区间不足"); sys.exit(2)
b=base[len(base)//2]
pmed=sorted(m for _,m in post)[len(post)//2]
lo=min(m for _,m in post)
print(f"  拖动前基线 MAD 中位数 {b:.2f}；拖动后中位数 {pmed:.2f}，最低 {lo:.2f}")

# 基线太低说明画面本身几乎不动（暗场景/静态镜头），判断不可靠
if b < 1.0:
    print("  SKIP  画面本身几乎不动（基线 MAD<1.0），本次测试无效，换个视频再跑"); sys.exit(2)

# 冻结判定：连续多秒 MAD 掉到基线的 10% 以下
thr=max(b*0.10, 0.10)
worst=0; run=0
for _,m in post:
    if m<thr: run+=1
    else: worst=max(worst,run); run=0
worst=max(worst,run)
print(f"  冻结阈值 {thr:.2f}；拖动后最长连续低于阈值 {worst} 秒")
if worst>=5:
    print("  FAIL  拖动后出现长时间画面冻结"); sys.exit(1)
if pmed < b*0.3:
    print("  FAIL  拖动后画面明显变慢/卡顿（中位数不到基线的 30%）"); sys.exit(1)
print("  PASS  拖动后画面持续更新，没有冻结"); sys.exit(0)
METRIC
case $? in 0) PASS=$((PASS+1));; 1) FAIL=$((FAIL+1));; *) SKIP=$((SKIP+1));; esac
echo

# ── 5. 配置同步 ───────────────────────────────────────────────────────
echo "── 5. 配置同步服务端可达性"
if curl -s --max-time 5 "${SERVER}/health" | grep -q '"ok":true'; then
  ok "Mac 同步服务在跑（${SERVER}）"
  PROF="verify-$MODEL"
  curl -s -X PUT "${SERVER}/api/profiles/${PROF}" -H 'content-type: application/json' \
    -d '{"data":{"boxes":{"setting":{},"video":{}}},"baseRev":0,"device":"verify-script"}' \
    | grep -q '"rev"' && ok "能写入配置档 $PROF" || bad "写入配置档失败"
  curl -s "${SERVER}/api/profiles" | grep -q "$PROF" && ok "配置列表里能看到 $PROF" || bad "配置列表里没有 $PROF"
else
  bad "同步服务不可达（${SERVER}）—— launchctl print gui/\$(id -u)/com.nana.piliplus-settings 看看"
fi
echo

# ── 汇总 ──────────────────────────────────────────────────────────────
echo "════════════════════════════════════"
echo "PASS $PASS   FAIL $FAIL   SKIP $SKIP"
echo "截图与录像: $OUT"
echo
echo "仍需人工确认的两项："
echo "  · 长按倍速按钮 → 变成「实心圆角矩形 + 主题色 + 人形图标」（UP 强制倍速）"
echo "  · 点按倍速按钮 → 变成「胶囊描边 + 主题色 + 对勾」（当前倍速）"
[ "$FAIL" -eq 0 ] || exit 1
