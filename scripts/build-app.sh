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

echo ">>> cargo build ($TARGET)"
PKGS=()
for b in "${BINS[@]}"; do
	[[ -d "$APP_DIR/$b" ]] && PKGS+=(-p "$b")
done
[[ ${#PKGS[@]} -gt 0 ]] || { echo "没有找到任何可编的 crate"; exit 1; }
echo "    编: ${PKGS[*]}"

cd "$APP_DIR"
cargo build --release --target "$TARGET" --bins "${PKGS[@]}"

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
