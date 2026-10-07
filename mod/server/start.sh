#!/bin/bash
# 启动 PiliPlus 设置同步服务（前台，Ctrl-C 退出）
set -euo pipefail
cd "$(dirname "$0")"

# 需要的话改这里：
export PORT="${PORT:-8720}"
export TOKEN="${TOKEN:-}"                       # 留空则不校验口令（仅限可信局域网）
export DATA_DIR="${DATA_DIR:-$HOME/.piliplus-settings}"

exec /opt/homebrew/bin/node piliplus-settings-server.mjs
