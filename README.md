# ImmortalWrt Auto-Build

用 GitHub Actions + [ImmortalWrt 官方 ImageBuilder](https://downloads.immortalwrt.org/) 拼固件，**3-5 分钟出货**。

| 项 | 值 |
|---|---|
| 设备 | NanoPi R66S（Rockchip RK3328 / RK3568，ARMv8） |
| 固件版本 | ImmortalWrt 25.12.2（内核 6.12.103） |
| 分区 | kernel 64 MB + rootfs 400 MB |
| LAN 网关 | `192.168.100.1`（首次启动时由 uci-defaults 改，见下） |
| 定时构建 | 每周一 02:00 UTC（北京时间 10:00） |
| 手动触发 | Actions 页面 → Run workflow |
| 产物 | Actions Artifact（7 天）+ Release 草稿（publish 后永久） |
| 镜像大小 | squashfs sysupgrade ≈ 79 MB |
| 实际耗时 | 3-5 分钟 |

---

## 快速开始

### 1. 触发构建

<https://github.com/oyksoft/immortalwrt_autobuild/actions> → 选 workflow → **Run workflow**（branch 填 `main`，profile 留空自动检测）→ 等 3-5 分钟。

### 2. 下载

Artifact（7 天）：run 页面底部 → `immortalwrt-r66s-25.12.2-<run号>` → 解压得到

```
immortalwrt-r66s-25.12.2-N-squashfs-sysupgrade.img.gz
SHA256SUMS                                          ← 校验用
```

校验：
```bash
sha256sum -c SHA256SUMS
```

Release 草稿（永久）：Releases 页面 → 找到 `R66S 构建 #N` 草稿 → **Publish release**。

> 草稿 body 里会显示本次用的 Passwall 版本（带链接），方便核对。

### 3. 刷 SD 卡

```bash
gunzip -c immortalwrt-r66s-25.12.2-N-squashfs-sysupgrade.img.gz | \
    sudo dd of=/dev/sdX bs=1M conv=fsync status=progress
sync
```

插卡上电，`http://192.168.100.1`（root / 无密码，建议登录后改）。

### 4. 装 passwall 核心（只需一次）

固件预装了 Passwall 的 **UI**、中文包和各类引擎，但**核心包**（`/usr/share/passwall`
下的 Lua 脚本集）不在任何预编译源里（Openwrt-Passwall 仓只 source build），需手动装：

```bash
ssh root@192.168.100.1
curl -fsSL https://raw.githubusercontent.com/oyksoft/immortalwrt_autobuild/main/scripts/install-passwall-core.sh | sh
```

脚本兼容 apk（25.12+）和 opkg，且不会覆盖你已有的 `/etc/config/passwall`。

---

## 固件里有什么

- ✅ **ImmortalWrt 25.12.2** 官方内核与基础系统
- ✅ **luci-app-passwall** —— 自动取 openwrt-passwall 仓库**最新 release**（带 token 调 API，限流时用 `git ls-remote` 兜底）
  - apk 会在所有源里选版本最高的：本地 `26.11.11-r1` > 官方源 `26.10.29-r1` → 用本地最新的 ✔
  - 已知限制：`luci-i18n-passwall-zh-cn` 会装官方源那份（版本号是 luci commit 号如 `26.309.x`，
    语义上比 upstream 发布号大）。i18n 只是 `.po` 翻译文件，版本滞后不影响功能。
    构建日志的「校验：实际安装的 passwall 版本」会显示实际结果。
- ✅ sing-box / xray-core / hysteria / v2ray-plugin 等代理引擎
- ✅ **BBR 加速**页面（网络 → BBR 加速），**默认开启**
- ✅ `kmod-tcp-bbr` / `kmod-tcp-hybla` 内核模块
- ✅ `tc-tiny`（排查网络队列用）
- ✅ 默认 LAN `192.168.100.1`
- ❌ passwall 核心包（需手动装，见上）

---

## BBR 加速（网络 → BBR 加速）

### 界面

```
TCP 拥塞控制
  算法                    [BBR（加速，推荐）▾]

运行状态
  页面版本                2026-11-15.6
  当前生效算法            bbr
  内核可用算法            reno cubic bbr hybla
  内核默认队列调度        fq_codel
  各网卡实际调度          br-lan=noqueue  eth0=mq  eth1=mq
  tcp_bbr 模块            已加载
```

- **只有一个配置项**：选拥塞控制算法。选 BBR = 开启加速，选 CUBIC = 恢复系统默认
- 选项来自内核**实际可用**的算法列表（动态读取，不会出现内核里没有的算法）
- 保存后**立即生效**，无需重启

### 在固件里以什么形式存在

不是 apk 包（软件包列表里看不到），是**注入的裸文件**：

```
/etc/config/bbr                          UCI 配置（option algorithm 'bbr'）
/etc/init.d/bbr                          rc.common 脚本（START=98 / STOP=98）
/etc/rc.d/S98bbr  /etc/rc.d/K98bbr       开机/关机软链（系统自动生成）
/usr/lib/lua/luci/controller/bbr.lua     LuCI 路由（挂到「网络」菜单）
/usr/lib/lua/luci/model/cbi/bbr.lua      LuCI 页面本体
```

而 BBR 内核模块本身来自官方包 `kmod-tcp-bbr`，它会自动装
`/etc/sysctl.d/12-tcp-bbr.conf`（内容就一行 `net.ipv4.tcp_congestion_control=bbr`），
**所以固件刷完第一次启动 BBR 就是开着的**。

选了非 BBR 算法时会动态生成 `/etc/sysctl.d/99-bbr-disable.conf` 覆盖它，保证重启后仍保持。

### 技术结论（都是实测/查源码得来的）

| 结论 | 依据 |
|---|---|
| **Passwall 没有 BBR 开关** | 源码里只有 TUIC/Naive **节点级** congestion_control，跟路由器本机无关 |
| 官方**没有**可用的 BBR LuCI 组件 | `luci-app-nps` 是内网穿透；`luci-app-sqm` 只有 QoS；`luci-app-turboacc` 需源码编译且要替换 firewall4/nftables |
| `net.core.default_qdisc` **改不动** | OpenWrt 由 netifd 接管；写 `fq` 会报 `ENOENT`（见下）；网卡是 `mq`，子队列创建时就定死 |
| **OpenWrt 内核只有 `fq_codel`** | `CONFIG_NET_SCH_FQ` 未开启 → 写 `fq` 找不到 `sch_fq` 模块 → `ENOENT` |
| ⚠️ **`fq_codel` ≠ `fq`** | `sch_fq_codel`（Fair Queue+CoDel AQM）和 `sch_fq`（Google Fair Queue，BBR pacing 用）是两个不同模块，名字像而已 |
| **BBR 不强制需要 fq** | 内核 4.13+ 有 TCP internal pacing 兜底 → `fq_codel + BBR` 是 OpenWrt 上唯一且标准的组合 |
| BBR 对本固件**有意义** | Passwall 的 sing-box/xray 在路由器本机建连到节点，属 TCP 端点，高延迟丢包线路上收益明显 |

> 官方 FAQ 说"路由器不该开 BBR"——那是针对纯转发场景。本固件跑代理，属于 TCP 端点。

---

## 架构（ImageBuilder 路线）

```
.github/workflows/build.yml
├── 校验自定义 Lua（luac5.1 语法 + CBI 冒烟测试）    ← 30 秒拦住 Lua 错误
├── 跑 scripts/build-ib.sh
│   ├── [1/9] 下 ImmortalWrt IB tarball（72 MB）
│   ├── [2/9] 解压
│   ├── [3/9] 改 IB 内置 .config + ptgen 参数（分区 64+400）
│   ├── [4/9] 检查 files/rootfs/（要注入的自定义文件）
│   ├── [5/9] 找 R66S profile
│   ├── [6/9] 从 files/r66s.config 提取 PACKAGES
│   ├── [7/9] 下 luci-app-passwall + i18n apk（取最新 release）
│   ├── [8/9] make package_index
│   └── [9/9] make image  PROFILE=... PACKAGES=... USER_FILES=files/rootfs
│              KERNELSIZE=64 ROOTFSPARTSIZE=400 PARTSIZE=480
│              → 自检：unsquashfs 查镜像里有没有自定义文件
└── 上传 artifact + 创建 Release 草稿（body 带 Passwall 版本链接）
```

**为什么用 ImageBuilder 而不是源码编译**：源码编译会卡在 Go 1.22/1.23 要求
（xray-core、sing-box）、u-boot 必须源码 build、runner 内存只有 7 GB。
IB 路线全部用预编译包，**零编译**，3-5 分钟出货。

### 目录结构

```
.github/workflows/build.yml      CI workflow
scripts/
├── build-ib.sh                   IB 构建主逻辑
├── install-passwall-core.sh     刷机后装 passwall 核心
├── install-bbr-ui.sh             手动安装 BBR 页面（排查固件注入问题时用）
├── test-bbr-cbi.lua              CBI 冒烟测试（CI 里跑）
└── diffconfig.sh                 从完整 .config 抽紧凑 diffconfig
files/
├── r66s.config                   完整 .config（PACKAGES 唯一真源）
├── r66s.diffconfig               review 用
└── rootfs/                       注入固件的自定义文件
    ├── etc/board.d/03_lan-ip     全新安装时把默认 LAN IP 改成 192.168.100.1
    ├── etc/config/bbr            BBR 加速 UCI 配置
    ├── etc/init.d/bbr            BBR 开机自动应用
    └── usr/lib/lua/luci/…        BBR 加速页面
```

> `files/rootfs/etc/init.d/bbr` 和 `etc/board.d/03_lan-ip` 在 git 里是 **755**，
> 其余是 644。Windows 下 `core.filemode=false` 会丢执行位，
> 改权限用 `git update-index --chmod=+x <文件>`。

> `R66s/.config` 是设备原始配置的本地备份，**不在仓库里**（`.gitignore` 忽略了）。

---

## 配置

### `files/r66s.config` — 包列表唯一真源

改这个文件 → 触发 build → 3-5 分钟出货。

> ⚠️ **不要用 `包名=版本` 的语法**（如 `luci-app-passwall=26.11.11-r1`）。
>
> IB 的 Makefile 里有这个 bug（`target/imagebuilder/files/Makefile`）：
>
> ```makefile
> define FormatPackages
> $(foreach pkg, ...,
>   $(eval pkg_name:=$(firstword $(subst =, ,$(pkg))))
>   $(if $(findstring =,$(pkg)),$(eval pkg_ver:==$(lastword $(subst =, ,$(pkg)))))  ← eval 不重置
>   $(pkg_name)$(call GetABISuffix,$(pkg_name))$(pkg_ver)
> ))
> ```
>
> `pkg_ver` 设在全局且循环里从不清空 → 一旦某个包带 `=版本`，
> **后面所有包都会继承这个版本约束**，apk 直接报错：
>
> ```
> ERROR: unable to select packages:
>   libgcc1-14.3.0-r5: breaks: world[libgcc1=26.11.11]
> ```
>
> 所以包列表里只能写纯包名。

### `files/rootfs/` — 自定义文件

往里丢文件就进固件，**不用改任何脚本**。

机制是 IB 官方的 `USER_FILES` 变量——IB 的 Makefile 里 `prepare_rootfs` target 会执行：

```makefile
$(call prepare_rootfs,$(TARGET_DIR),$(USER_FILES),$(DISABLED_SERVICES))
```

`build-ib.sh` 第 [9/9] 步把该目录作为 `USER_FILES` 传给 `make image`。

> **踩过的坑**（都试过，不可行，供参考）：
> - `$(TOPDIR)/files` —— 那是源码编译版 `include/image.mk` 的机制，IB 没有
> - 事后拷进 rootfs 目录 —— `make image` 会重建该目录
> - 自制 apk 包放进 `packages/` —— v2 tar.gz 格式不被 apk 的 `mkndx` 识别
> - `make install` —— IB 没有这个 target
> - hook `package_install` —— 插在 `apk add` 之前，仍被覆盖

### 分区大小

```
kernel  64 MB   ← CONFIG_TARGET_KERNEL_PARTSIZE=64
rootfs 400 MB   ← CONFIG_TARGET_ROOTFS_PARTSIZE=400
```

IB 默认是 16+300。`build-ib.sh` 第 [3/9] 步会 sed 改 IB 内置 `.config` 的
`CONFIG_TARGET_*_PARTSIZE` 以及所有用 ptgen 的脚本里的 `-p 16m` / `-p 300m`。

### LAN IP 为什么用 board.d 改

OpenWrt 默认 LAN IP 是 `192.168.1.1`（写在 `package/base-files/files/bin/config_generate` 里）。

ImageBuilder 路线**改不了它**——base-files 是预编译 apk，根本没有这个源文件可 patch
（之前仓库里的 `patches/001-base-files-default-lan-ip.patch` 就是这么失效的，已删除）。

**正解是改 `board.json`**——它是 `config_generate` 的数据源。

OpenWrt preinit 阶段（`lib/preinit/82_config_generate`）的流程：

```sh
[ -s /etc/board.json ] || /bin/board_detect    # 跑 /etc/board.d/* 生成 board.json
[ -s /etc/config/network -a -s /etc/config/system ] && exit 0   # 已有配置就完全不碰
# 否则用 board.json 里的 ipaddr 生成 /etc/config/network
```

所以往 board.json 写 `ipaddr` **只影响全新安装**：

| 场景 | 结果 |
|---|---|
| 全新刷机（不保留配置） | → `192.168.100.1` |
| sysupgrade 保留配置（`192.168.3.1`） | → **原样保留** |
| sysupgrade 保留配置（用户主动设的 `192.168.1.1`） | → **原样保留** |

实现：`files/rootfs/etc/board.d/03-lan-ip`（在 `02_network` 之后跑，往 board.json 的
`network.lan` 写 `ipaddr`）。

> 之前试过用 `uci-defaults` 改 `/etc/config/network` —— 那不行：
> uci-defaults 在 boot 阶段跑，那时 config 已经生成了，
> **光看 ipaddr 值区分不出「OpenWrt 默认值」和「用户主动设的同一个值」**，
> 会把用户保留配置里的自定义网段覆盖掉。

---

## CI 校验

CI 会在花 3-5 分钟 build 之前先卡住常见错误：

| 检查 | 手段 | 能抓到什么 |
|---|---|---|
| Lua 语法 | `luac5.1 -p` | 语法错 |
| CBI 运行时 | `scripts/test-bbr-cbi.lua`（mock 环境实际加载） | `Map.apply` 不存在、`uci.get` 缺 self、默认值不在选项列表内、DummyValue 类型错…… |
| 自定义文件是否进固件 | `unsquashfs` 查镜像 | 注入机制失效 |

> **自检的坑**：`sysupgrade.img` 是带 u-boot 头/分区的镜像，squashfs 在**偏移 128 MB** 处，
> 直接 `unsquashfs` 会报 `Can't find a valid SQUASHFS superblock`。
> 要用 magic `hsqs` 定位偏移再切出来。

---

## 支持多设备吗？

**理论上支持，实际没适配。**

`build-ib.sh` 接受 `USER_PROFILE` 环境变量，理论上能 build 任何 ImmortalWrt IB 出的 profile。

**没适配的地方**：
- `IB_URL` 写死了 `rockchip/armv8` —— 其他 arch 要改 URL 模板
- ptgen 的 `-p 16m` / `-p 300m` sed 假设 RK3568 默认分区 —— 其他 SoC 不一定
- `files/r66s.config` 是 R66S 专用的

**加新设备**：复制 `r66s.config` → 改 `build-ib.sh` 的 URL 生成 → 在 workflow 的
`workflow_dispatch` 加 `device` 参数。

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| release body 显示「Passwall: 未获取」 | GitHub API 限流（匿名 60 次/小时/IP，runner 共享 IP） | 已修：带 `GITHUB_TOKEN` + 重试 3 次 + `git ls-remote` 兜底 |
| 固件里 passwall 版本很旧 | 同上（API 失败时退回官方源自带版本） | 同上；也可看日志「最新 release：xxx」确认 |
| 「自检失败：自定义文件没进固件」 | `files/rootfs/` 空或 `USER_FILES` 没传 | 看 build 日志 [4/9] 步的文件清单 |
| LuCI 页面 500 | CBI 运行时错 | CI 的冒烟测试会先抓；本地可 `lua5.1 scripts/test-bbr-cbi.lua` |
| LuCI 菜单不显示 BBR 加速 | 浏览器缓存 | `rm -f /tmp/luci-indexcache*` + Ctrl+F5 |
| `make image` 报 `unable to select packages` | 包名不在索引里 | 检查 `packages/` 里的 apk 格式 |
| BBR 切了不生效 | 模块没加载 | 看页面「tcp_bbr 模块」是否显示"已加载"；`logread -e bbr` 看日志 |

---

## 安全

- 仓库设为私有（公开仓库 Actions 分钟数无限，私有 2000 分钟/月）
- `files/r66s.config` 会暴露你启用的所有包
- 不要把密钥、API token 写进配置

---

## License

MIT
