# 这套仓库的结构

镜像与应用程序分开，但由同一个仓库、同一条 GitHub Actions 流水线一起构建：

```
duck-a733/                        ← 新仓库（本仓库）：只放"怎么把两者装到一起"
├── .github/workflows/
│   └── build-image.yml           ← 全流程：编应用 → 编 BSP → 合成镜像 → 出 artifact
├── scripts/
│   ├── build-app.sh              ← 交叉编译 microduck（aarch64），产出 dist/app/
│   └── stage-app.sh              ← 把 dist/app/ 合进 BSP 的 rootfs 树
├── config/
│   └── a733-ci.env               ← CI 用的 BSP 配置（直连 GitHub，不走 ghfast 代理）
└── README.md
```

### 职责划分（不要越界）

| 仓库 | 负责 | 不负责 |
|---|---|---|
| `weilan157/bsp` | 内核 / U-Boot / boot0 / rootfs / systemd 单元 / 打包 | 应用二进制 |
| `weilan157/microduck` | `robotd` / `robotctl` 源码、Feetech 总线、策略 | 板级服务、网络/BT/配网 |
| `weilan157/duck-a733`（本仓库） | 按 ref 拉两端、交叉编译、覆盖进 overlay、CI | 改 BSP 脚本、改应用代码 |

两个上游仓库**不复制、不 fork**，流水线里按 ref 拉取：

| 仓库 | 作用 | 默认 ref |
|---|---|---|
| `weilan157/bsp`（本仓库的父项目，分支 `cubie-a7z-a733`） | 内核 / U-Boot / boot0 / rootfs / 打包（`./bsp` 那套） | `cubie-a7z-a733` |
| `weilan157/microduck` | 应用：`robotd` / `robotctl`（A733 只用这两个） | `feat/feetech`（A733 + 复刻 HAT） |

A733 + 复刻 HAT 是 **Feetech HD-1910**，所以流水线默认：
`APP_REF=feat/feetech`、`APP_FEATURES=feetech`。原版 Dynamixel 硬件才回 `main`，
并且不能传 `APP_FEATURES`。

这样"改动最小"：BSP 和应用各自演进，本仓库只维护**流水线 + 装配规则**。
想固定某个版本，就把 `build-image.yml` 里的 `BSP_REF` / `APP_REF` 改成 tag 或 commit。

## 产物

每次 `push` / `workflow_dispatch` 产出：

- `a733-image-<bsp_sha>-<app_sha>.img`（SD 卡镜像，直接 `dd` 写卡）
- 同名 `.sha256`
- `app-dist.tar.gz`（应用二进制，单独下载，便于在已有镜像上手动升级）

## 应用怎么装进镜像

BSP 的 rootfs 是把 `vendor/rootfs/micro/overlay/` 覆盖到 debootstrap 出来的根上，
所以装配规则就一条：**把应用产物覆盖进 overlay**（`scripts/stage-app.sh`）：

```
dist/app/usr/local/bin/{robotd,robotctl}
```

默认只编这两个。官方的 `configd` / `btd` / `mediad` / `sounds` 由 BSP 的
`microduck-wifi` / `microduck-bt` / `microduck-cam` 等取代，默认不编；
确实需要时用 `APP_EXTRA_BINS="configd btd mediad sounds"`。

**只覆盖二进制，不覆盖 systemd 单元。** A733 的 `microduck-robotd.service`
（`/usr/local/bin/robotd --port /dev/ttyAS0`，BSP 已 enable）就是唯一要跑的
robotd；microduck 官方单元是给 `/opt/robot/daemon/current` + `robot/btd` 用户
那套 updater 布局写的，A733 镜像没有这些，两份同时 enable 会抢 `/dev/ttyAS0`。
`build-app.sh` 因此不再复制 `robotd/configd/btd.service`。

## 本地怎么跑（和在 CI 里完全一样）

```bash
# 1) 应用（在 x86 主机上交叉编 aarch64）
#    Feetech 硬件必须带 feature；不传就是 Dynamixel。
APP_FEATURES=feetech ./scripts/build-app.sh    # 需要 rustup + aarch64 工具链
# 产物: dist/app/

# 2) 镜像
git clone -b cubie-a7z-a733 https://github.com/weilan157/bsp.git bsp
./scripts/stage-app.sh bsp        # 把 dist/app 合进 bsp/vendor/rootfs/micro/overlay
cd bsp && ./bsp env && ./bsp setup && ./bsp all
# 产物: bsp/out/a733/a733-micro.img
```

## CI 说明（重要）

- runner：`ubuntu-24.04`，**镜像 job 需要 4~6 小时超时上限内完成**
  （BSP 的 `sources/` 首次克隆 + 内核 + U-Boot + debootstrap + 打包，实测本机约 40 分钟，
  runner 更慢，所以给了 `timeout-minutes: 340`）；
- `sources/` 用 `actions/cache` 缓存（约 6~8 GB），第二次起构建时间会大幅下降；
- BSP 默认从 `ghfast.top` 代理拉源码（那是给国内网络用的），CI 里改成直连 GitHub，
  见 `config/a733-ci.env`；如果某天直连出问题，把那段 URL 换回代理即可；
- **首次跑大概率需要 1~2 轮微调**（apt 包名、runner 磁盘、debootstrap 镜像源）。
  流水线里每一步都单独命名，失败时能直接从日志定位到是哪一步。

## 已知缺口（下一步）

1. `mediad` 依赖 Rockchip MPP 的 GStreamer 插件、`duck-detect` 依赖 RKNN —— 这些是
   **运行时 dlopen**，能编过；但要在 A733 上真正跑起来需要各自的运行库，
   `deploy/` 里的 `setup-gstreamer.sh` / `setup-npu.sh` 是给 Radxa 的，A733 要另配；
2. `robotd` 的策略模型（Hugging Face Hub）和 duck 检测模型需要联网拉取，
   首次开机用官方 `scripts/seed-*.sh`；A733 镜像里目前没跑这些；
3. 设备树/驱动目前是 A733 能跑的最小集（WiFi/音频/摄像头已通，NPU 未通），
   应用侧按 RK3566 写的硬件假设（GPIO/舵机/PAM8406 之外的 HAT 外设）需要对一遍。
