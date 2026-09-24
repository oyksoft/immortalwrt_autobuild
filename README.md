# ImmortalWrt Auto-Build

利用 GitHub Actions + [ImmortalWrt 官方 ImageBuilder](https://downloads.immortalwrt.org/) 拼固件，5-10 分钟出货。

- **当前已配置设备**: NanoPi R66S（Rockchip RK3328，ARMv8）
- **架构**: `main` + GitHub Action ImageBuilder workflow
- **定时构建**: 每周一 02:00 UTC（北京时间 10:00）
- **手动触发**: Actions 页面 Run workflow
- **产物**: GitHub Actions Artifacts（30 天保留，含 sha256）

---

## 架构（v2：ImageBuilder 路线）

```
.github/workflows/build.yml      ← GitHub Action workflow
├── 装 zstd + apk-tools static 3.0.8
├── 下 ImmortalWrt IB tarball（72 MB）
├── 解 IB → 改内置 .config（PART SIZE）→ 重打包
│                                    ① 解压 IB
│                                    ② sed 改 .config + ptgen -p 参数
│                                    ③ tar -cI zstd 重新打包
├── 解压 IB → 跑 make image
│   ├── feeds.conf 加 passwall feed（IB 不读但留着）
│   ├── find R66S profile
│   ├── grep PACKAGES from files/r66s.config
│   ├── 下载 GitHub 最新 release → luci-app-passwall + i18n apk
│   ├── make image PROFILE=lunzn_fastrhino_r66s \
│   │            PACKAGES=$(... ) \
│   │            KERNELSIZE=64 ROOTFSPARTSIZE=400 PARTSIZE=480
│   └── 输出 sysupgrade.img.gz + manifest + SHA256SUMS
└── 上传 artifact（只 sysupgrade.img.gz 一个文件）
```

**和 v1 的区别**：
- v1 用 `make world` 从源码编译 → **1.5-2 h** → 已废弃
- v2 用 IB 拼装预编译包 → **5-10 min** → 当前

**目录**：
```
scripts/
├── build-ib.sh                   # IB 主逻辑（上面流程）
└── install-passwall-core.sh     # 刷机后手动装 passwall 核心
files/
├── r66s.config                   # R66S 完整 PACKAGES（passwall 全套关掉，只留 UI）
└── r66s.diffconfig               # review 用
.github/workflows/build.yml      # GitHub Action
```

---

## 关键决策与原因

### 为什么用 ImageBuilder（而不是源码编译）

源码编译（`make world`）会卡在：
- Go 1.23 / 1.22 版本要求（xray-core、sing-box 等 Go 包需要）
- u-boot / trusted-firmware 必须源码 build（5-10 min）
- 内存/CPU 受 runner 限制（GitHub-hosted runner 是 4 vCPU / 7 GB RAM）

ImageBuilder 路线绕开这些：
- 所有包预编译（ImmortalWrt 官方 build server）
- 不需要 Go toolchain
- 不需要 build u-boot / firmware（profile 自带下载）

### 为什么 passwall 核心包不在 IB 里

IB tarball 里 `luci-app-passwall` 有（ImmortalWrt 仓），但 **`passwall` 核心包**（Lua 脚本集）**没有**——Openwrt-Passwall 仓只 source build，**没 release pre-built apk**。

**解决**：刷机后跑 `install-passwall-core.sh`（在 R66S 上手动从 GitHub 拉源码 cp）。

---

## 快速开始

### 1. 触发 build

直接触发 GitHub Actions：

1. https://github.com/oyksoft/immortalwrt_autobuild/actions
2. 左侧选 `Build ImmortalWrt (ImageBuilder)`
3. `Run workflow`，branch 选 `main`，profile 留空（默认自动查 R66S）
4. 5-10 分钟出货

### 2. 下载产物

artifact `< 50 MB`，解压得：

```
out/
├── immortalwrt-r66s-25.12.2-N-squashfs-sysupgrade.img.gz   ← 完整 SD 卡镜像
├── immortalwrt-r66s-25.12.2-N-squashfs-sysupgrade.img.gz.sha256sums
├── manifest.json
└── profiles.json
```

只含 sysupgrade 镜像（**不再打包 IB 全产物**——之前 176 MB artifact 已修复）。

### 3. 刷 SD 卡

```bash
gunzip -c immortalwrt-r66s-25.12.2-N-squashfs-sysupgrade.img.gz | \
    sudo dd of=/dev/sdX bs=1M conv=fsync status=progress
sync
```

R66S SD 卡槽插入，上电。`192.168.100.1`（默认 LAN 网关已 patch 改了）。

### 4. 刷机后装 passwall 核心

固件已预装：
- ✅ luci-app-passwall 26.9.16（最新）
- ✅ luci-i18n-passwall-zh-cn
- ✅ sing-box、xray-core、hysteria 等引擎
- ✅ passwall UI 一打开就能看到
- ❌ passwall 核心（Lua 脚本集）— 需手动装

跑这一条装核心：

```bash
ssh root@192.168.100.1
curl -fsSL https://raw.githubusercontent.com/oyksoft/immortalwrt_autobuild/main/scripts/install-passwall-core.sh | sh
```

或本地拷过去跑：

```bash
scp scripts/install-passwall-core.sh root@192.168.100.1:/tmp/
ssh root@192.168.100.1
chmod +x /tmp/install-passwall-core.sh
/tmp/install-passwall-core.sh
```

---

## 配置

### files/r66s.config — 唯一真源

PACKAGES 列表（`make image` 时 IB 会装这些）全部从这里提取。

调整 firmware = 改这个文件 → 触发 build → 5-10 min 出货。

### 不用动的东西

| 项 | 说明 |
|---|---|
| `.github/workflows/build.yml` | 默认就好（除非换设备） |
| `scripts/build-ib.sh` | 默认就好（除非加特殊 logic） |

### 分区大小

```
kernel:  64 MB    ← r66s.config 里 CONFIG_TARGET_KERNEL_PARTSIZE=64
rootfs: 400 MB   ← r66s.config 里 CONFIG_TARGET_ROOTFS_PARTSIZE=400
```

`build-ib.sh` 第 [2.5/8] 步会 sed 改 IB 内置 .config 的 `CONFIG_TARGET_*_PARTSIZE` 和 ptgen 的 `-p 16m -p 300m`（IB 默认值），再重打包 tarball。

---

## 支持多设备吗？

**理论上支持，实际上没做适配。**

`build-ib.sh` 接受 `USER_PROFILE` env var，理论上能 build 任何 ImmortalWrt IB 出的 profile。

**没适配的地方**：
- `IB_URL` 写死了 `rockchip/armv8`——其他 arch 设备改 URL 模板就行
- ptgen 的 `-p 16m -p 300m` sed 假设 RK3568 默认 partition——其他 SoC 不一定是这个
- `luci-app-passwall` 下载用 GitHub release 通用 URL——跨设备 OK

**加新设备要做**：
1. 在 `build-ib.sh` 里加 `BRANCH` 和 `IB_URL` 模板支持参数化
2. 加 `IB_DIR` / `IB_PROFILE` 检测脚本
3. 改 `workflow_dispatch` 的 `inputs` 加 `device` 参数

**最简单**：复制 `r66s.config` 到新设备名（`x86_64.config` 等），然后 build-ib.sh 改 URL 生成。

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 磁盘满 | runner 默认 ~14 GB | 已加 `Free up disk space` 步骤删 dotnet/ghc |
| 6 小时超时 | 包过多 | 砍包或用 self-hosted runner |
| `make download` 报 hash mismatch | 上游 URL 变了 | 清 cache 重跑 |
| passwall apk 装不上 | 文件名 "25.12+_ 前缀" 不匹配 | `install-passwall-core.sh` 里有这逻辑 |
| `find <profile>` 空 | profile 名错 | 查 IB 里 `.profiles/` 内容 |

---

## 安全

- **私有仓库** 每月 2000 分钟免费（公开无限）。
- `files/r66s.config` 暴露你启用的所有包。
- 避免把密钥、API token 写进配置。

---

## License

MIT
