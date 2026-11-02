#!/bin/bash
# 交叉编译 microduck（aarch64）并整理成可覆盖进 rootfs 的 dist/app/
#
# 用法:
#   ./scripts/build-app.sh [app-dir] [dist-dir]
#     app-dir  默认 ./app（CI 里是 checkout 出来的 microduck）
#     dist-dir 默认 ./dist/app
#
# 只编"板子上要跑的服务/工具"，不含只给开发者用的 duckctl（它要在 x86 上跑）：
#   robotd configd btd mediad sounds robotctl
# 其中 mediad / duck-detect 依赖的 Rockchip 库是运行时 dlopen，编译阶段不需要。
set -euo pipefail

APP_DIR="${1:-./app}"
DIST="${2:-./dist/app}"
TARGET=aarch64-unknown-linux-gnu
BINS=(robotd configd btd mediad sounds robotctl)

[[ -f "$APP_DIR/Cargo.toml" ]] || { echo "找不到 $APP_DIR/Cargo.toml"; exit 1; }

echo ">>> 交叉编译 ($TARGET)"
PKGS=()
for b in "${BINS[@]}"; do
	[[ -d "$APP_DIR/$b" ]] && PKGS+=(-p "$b")
done
[[ ${#PKGS[@]} -gt 0 ]] || { echo "没有找到任何可编的 crate"; exit 1; }
echo "    编: ${PKGS[*]}"

cd "$APP_DIR"
# 优先用仓库自己的 `cargo board`（.cargo/config.toml 里的别名 = zigbuild +
# aarch64-unknown-linux-gnu.2.31）。裸 `cargo build --target` 在这里是不行的：
# mediad 在 Linux 上非可选地依赖 gstreamer/glib，这两个是 pkg-config crate，
# 必须有 aarch64 的头文件、.pc 和 .so 才编得过，否则死在 glib-sys 的 build
# script 里（"pkg-config has not been configured to support cross-compilation"）。
# 这些由 app/scripts/cross-sysroot.sh 提供，CI 里先把 PKG_CONFIG_LIBDIR /
# PKG_CONFIG_ALLOW_CROSS / RUSTFLAGS 导进环境。
if command -v cargo-zigbuild >/dev/null 2>&1; then
	echo "    toolchain: cargo board (zigbuild, glibc floor 2.31)"
	cargo board --bins "${PKGS[@]}"
else
	echo "    toolchain: cargo build（没装 cargo-zigbuild；glibc floor 不钉，需自备 sysroot）"
	cargo build --release --target "$TARGET" --bins "${PKGS[@]}"
fi

OUT="$APP_DIR/target/$TARGET/release"
[[ -d "$OUT" ]] || { echo "没有产物目录 $OUT"; exit 1; }

echo ">>> 收集二进制与 systemd 单元 -> $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/usr/local/bin" "$DIST/etc/systemd/system" \
	"$DIST/etc/systemd/system/multi-user.target.wants"

for b in "${BINS[@]}"; do
	if [[ -x "$OUT/$b" ]]; then
		install -m 755 "$OUT/$b" "$DIST/usr/local/bin/$b"
		echo "    bin  $b"
	fi
done

# 官方 systemd 单元：btd / configd / robotd 是仓库里现成的
for u in btd/systemd/btd.service configd/systemd/configd.service robotd/systemd/robotd.service; do
	if [[ -f "$APP_DIR/$u" ]]; then
		install -m 644 "$APP_DIR/$u" "$DIST/etc/systemd/system/$(basename "$u")"
		echo "    unit $(basename "$u")"
	fi
done

# 开机自启：用相对符号链接，rootfs 里 /etc/systemd/system -> /usr/lib 无所谓
for u in "$DIST"/etc/systemd/system/*.service; do
	[[ -e "$u" ]] || continue
	ln -sf "../$(basename "$u")" \
		"$DIST/etc/systemd/system/multi-user.target.wants/$(basename "$u")"
done

echo ">>> dist:"
find "$DIST" -type f -o -type l | sed 's/^/    /'
