#!/bin/bash
# 把 dist/app/ 合进 BSP 的 rootfs overlay（这两个仓库唯一的"装配点"）
#
# 用法: ./scripts/stage-app.sh <bsp-dir> [dist-dir]
#
# 原理：BSP 的 ./bsp rootfs 会把 vendor/rootfs/micro/overlay/ 覆盖到 debootstrap
# 出来的根上，所以应用只要往这个 overlay 里丢文件即可，不需要改 BSP 的任何脚本。
set -euo pipefail

BSP="${1:?用法: stage-app.sh <bsp-dir> [dist-dir]}"
DIST="${2:-./dist/app}"
OVL="$BSP/vendor/rootfs/micro/overlay"

[[ -d "$OVL" ]] || { echo "找不到 $OVL（BSP 目录不对？）"; exit 1; }
[[ -d "$DIST" ]] || { echo "找不到 $DIST（先跑 build-app.sh）"; exit 1; }

echo ">>> 覆盖 $DIST -> $OVL"
tar -C "$DIST" -cf - . | tar -C "$OVL" -xpf -

echo ">>> 合入后的应用文件:"
find "$OVL/usr/local/bin" -maxdepth 1 -type f 2>/dev/null | sed 's/^/    /' || true
find "$OVL/etc/systemd/system" -maxdepth 1 -name '*.service' 2>/dev/null | sed 's/^/    /' || true
