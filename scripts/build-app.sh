#!/bin/bash
# 交叉编译 microduck（aarch64）并整理成可覆盖进 rootfs 的 dist/app/
#
# 用法:
#   ./scripts/build-app.sh [app-dir] [dist-dir]
#     app-dir  默认 ./app（CI 里是 checkout 出来的 microduck）
#     dist-dir 默认 ./dist/app
#   APP_FEATURES=feetech 显式开 Feetech 总线（A733 + 复刻 HAT）。
#
# 只编 A733 真正要跑的：robotd（BSP microduck-robotd.service 拉起）和
# robotctl（健康检查/init/relax）。configd/btd/mediad/sounds 由 BSP 的
# microduck-wifi/microduck-bt/... 取代，默认不编；需要时 APP_EXTRA_BINS。
set -euo pipefail

APP_DIR="${1:-./app}"
DIST="${2:-./dist/app}"
TARGET=aarch64-unknown-linux-gnu
BINS=(robotd robotctl)
# A733 只用 BSP 的 microduck-* 服务 + robotd/robotctl；下面这些是官方
# 配网/蓝牙/媒体工具，BSP 已有自己的实现，默认不编，需要时显式指定：
#   APP_EXTRA_BINS="configd btd mediad sounds"
if [[ -n "${APP_EXTRA_BINS:-}" ]]; then
	# shellcheck disable=SC2206
	BINS+=(${APP_EXTRA_BINS})
fi
# A733/Feetech：robotd 需要 feetech feature；CI 里显式传，避免 checkout 到
# 没设 default 的分支时又编成 Dynamixel。
APP_FEATURES="${APP_FEATURES:-}"

[[ -f "$APP_DIR/Cargo.toml" ]] || { echo "找不到 $APP_DIR/Cargo.toml"; exit 1; }

# 下面要 cd 进 $APP_DIR（cargo 只从 cwd 及上层读 .cargo/config.toml，`board`
# 别名就在那里面），所以两个输出路径先钉成绝对路径。不然 $DIST 会落到
# app/dist/app，$OUT 会变成 app/app/target/...，收集阶段必然扑空。
mkdir -p "$(dirname "$DIST")"
DIST="$(cd "$(dirname "$DIST")" && pwd)/$(basename "$DIST")"
APP_ABS="$(cd "$APP_DIR" && pwd)"

echo ">>> 交叉编译 ($TARGET)"
PKGS=()
for b in "${BINS[@]}"; do
	[[ -d "$APP_DIR/$b" ]] && PKGS+=(-p "$b")
done
[[ ${#PKGS[@]} -gt 0 ]] || { echo "没有找到任何可编的 crate"; exit 1; }
echo "    编  ${PKGS[*]}"
[[ -n "$APP_FEATURES" ]] && echo "    features: $APP_FEATURES"

cd "$APP_DIR"
# 优先用仓库自己的 `cargo board`（.cargo/config.toml 里的别名 = zigbuild +
# aarch64-unknown-linux-gnu.2.31）。裸 `cargo build --target` 在这里是不行的：
# mediad 在 Linux 上非可选地依赖 gstreamer/glib，这两个是 pkg-config crate，
# 必须有 aarch64 的头文件 .pc 和 .so 才编得过，否则死在 glib-sys 的 build
# script 里（"pkg-config has not been configured to support cross-compilation"）。
# 这些由 app/scripts/cross-sysroot.sh 提供，CI 里先把 PKG_CONFIG_LIBDIR /
# PKG_CONFIG_ALLOW_CROSS / RUSTFLAGS 导进环境。
if command -v cargo-zigbuild >/dev/null 2>&1; then
	echo "    toolchain: cargo board (zigbuild, glibc floor 2.31)"
	if [[ -n "$APP_FEATURES" ]]; then
		cargo board --bins "${PKGS[@]}" --features "$APP_FEATURES"
	else
		cargo board --bins "${PKGS[@]}"
	fi
else
	echo "    toolchain: cargo build（没装 cargo-zigbuild；glibc floor 不钉，需自备 sysroot）"
	if [[ -n "$APP_FEATURES" ]]; then
		cargo build --release --target "$TARGET" --bins "${PKGS[@]}" --features "$APP_FEATURES"
	else
		cargo build --release --target "$TARGET" --bins "${PKGS[@]}"
	fi
fi

OUT="$APP_ABS/target/$TARGET/release"
[[ -d "$OUT" ]] || { echo "没有产物目录 $OUT"; exit 1; }

echo ">>> 收集二进制 -> $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/usr/local/bin"

for b in "${BINS[@]}"; do
	if [[ -x "$OUT/$b" ]]; then
		install -m 755 "$OUT/$b" "$DIST/usr/local/bin/$b"
		echo "    bin  $b"
	fi
done

# 不再复制 microduck 的 systemd 单元：
#   官方单元 ExecStart=/opt/robot/daemon/current/bin/{robotd,configd,btd}，
#   还要求 robot/btd 用户和 /opt 布局；A733 镜像没有这些，BSP 自己又有
#   microduck-robotd.service（/usr/local/bin/robotd --port /dev/ttyAS0）。
#   两份同时 enable 会抢 /dev/ttyAS0，且官方单元会因为路径/用户不存在而失败。
#   A733 统一用 BSP 的 microduck-* 单元，应用只提供 /usr/local/bin 下的二进制。

echo ">>> dist:"
find "$DIST" -type f -o -type l | sed 's/^/    /'
