#!/usr/bin/env bash
# 给 PiliPlus 依赖打补丁（官方 lib/scripts/patch.ps1 的 macOS/Android 移植版）。
#
# PiliPlus 必须同时给两处打补丁才能编译：
#   1) Flutter SDK 本身（25 个 .patch）
#   2) pub cache 里的 material_ui 包（9 个 .patch）
# 官方每次 upgrade deps 都可能把 material_ui 升版本，新版本是未打补丁的，
# 于是 dyn_tab_bar.dart 之类用到 Flutter 内部 API 的文件就编译不过
# （报 IndicatorPainter / TabBarLayoutCallback undefined）。
#
#   bash mod/tools/patch_deps.sh                # 只补 material_ui（最常用）
#   bash mod/tools/patch_deps.sh --flutter      # 连 Flutter SDK 一起重打
#   bash mod/tools/patch_deps.sh --flutter-only
#
# 还原：Flutter SDK 用 `git -C <sdk> reset --hard HEAD`；
#      material_ui 删掉目录重新 `flutter pub get` 即可。
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
FLUTTER_ROOT="${FLUTTER_ROOT:-/Users/zhaonanwang/flutter_sdk/flutter-3.47.6}"
PUB_HOSTED="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"

DO_FLUTTER=0; DO_MATERIAL=1
for a in "$@"; do
  case "$a" in
    --flutter) DO_FLUTTER=1 ;;
    --flutter-only) DO_FLUTTER=1; DO_MATERIAL=0 ;;
  esac
done

fail=0

# ── 1) Flutter SDK ────────────────────────────────────────────────────
if [ "$DO_FLUTTER" = "1" ]; then
  echo "############ 1) Flutter SDK 补丁（先还原到干净状态）"
  git -C "$FLUTTER_ROOT" reset --hard HEAD >/dev/null || { echo "reset 失败"; exit 1; }
  git -C "$FLUTTER_ROOT" clean -fd packages/flutter/lib >/dev/null 2>&1
  FLUTTER_PATCHES=(
    modal_barrier text_selection mouse_cursor image_anim layout_builder
    navigation_drawer popup_menu fab null_safety_for_selectable_region
    selectable_region editable_text text_field scroll_position scrollable
    scrollable_gesture draggable_scrollable_sheet scaffold text text_painter
    sliver refresh_indicator double_tap_gesture bottom_sheet_android
    scroll_view navigator
  )
  cd "$FLUTTER_ROOT" || exit 1
  for p in "${FLUTTER_PATCHES[@]}"; do
    if git apply "$REPO/lib/scripts/$p.patch" 2>/tmp/patch_err_$p.txt; then
      echo "  ok   $p"
    else
      echo "  FAIL $p"; cat "/tmp/patch_err_$p.txt"; fail=1
    fi
  done
  [ "$fail" -eq 0 ] || { echo "Flutter 补丁有失败项，中止"; exit 1; }
else
  n=$(git -C "$FLUTTER_ROOT" status --short 2>/dev/null | wc -l | tr -d ' ')
  echo "############ 1) 跳过 Flutter SDK（当前已有 $n 个改动文件）"
  [ "$n" -lt 10 ] && echo "  ⚠️  改动文件偏少，可能需要 bash mod/tools/patch_deps.sh --flutter"
fi

# ── 2) material_ui ────────────────────────────────────────────────────
if [ "$DO_MATERIAL" = "1" ]; then
  echo "############ 2) material_ui 补丁"
  # 缓存目录跟着 PUB_HOSTED_URL 走：官方源是 pub.dev，国内镜像是 pub.flutter-io.cn。
  # 只认 pub.dev 会在用镜像时找不到包（踩过）。
  case "$PUB_HOSTED" in
    *pub.flutter-io.cn*) CACHE="$HOME/.pub-cache/hosted/pub.flutter-io.cn" ;;
    *)                    CACHE="$HOME/.pub-cache/hosted/pub.dev" ;;
  esac
  [ -d "$CACHE" ] || { echo "  pub cache 目录不存在: $CACHE"; exit 1; }

  export PATH="$FLUTTER_ROOT/bin:$PATH"
  export PUB_HOSTED_URL="$PUB_HOSTED"
  export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
  cd "$REPO" || exit 1
  flutter pub get >/tmp/pubget_patch.log 2>&1 || { echo "pub get 失败"; tail -20 /tmp/pubget_patch.log; exit 1; }

  MAT_DIR=$(ls -d "$CACHE"/material_ui-* 2>/dev/null | sort -V | tail -1)
  [ -n "$MAT_DIR" ] || { echo "  material_ui 未找到（$CACHE）"; exit 1; }
  echo "  目标: $MAT_DIR"
  if grep -q "TabBarLayoutCallback" "$MAT_DIR/lib/src/tabs.dart" 2>/dev/null; then
    echo "  已经是打过补丁的，跳过"
  else
    MATERIAL_PATCHES=(
      modal_barrier_material navigation_drawer popup_menu fab
      text_field scaffold refresh_indicator tabs bottom_sheet_android
    )
    cd "$MAT_DIR" || exit 1
    for p in "${MATERIAL_PATCHES[@]}"; do
      if git apply "$REPO/lib/scripts/material/$p.patch" 2>/tmp/mat_err_$p.txt; then
        echo "  ok   material/$p"
      else
        echo "  FAIL material/$p"; cat "/tmp/mat_err_$p.txt"; fail=1
      fi
    done
    [ "$fail" -eq 0 ] || { echo "material_ui 补丁有失败项"; exit 1; }
  fi
fi

echo "############ 完成"
