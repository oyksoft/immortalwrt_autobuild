# ImmortalWrt Auto-Build

利用 GitHub Actions 自动编译 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 固件。

- **当前已配置设备**: NanoPi R66S（Rockchip RK3328，ARMv8）
- **预留多设备**: matrix 策略，加新设备只需要放 config + 改一行 workflow
- **定时构建**: 每周一 02:00 UTC（北京时间 10:00）
- **手动触发**: Actions 页面 Run workflow，可选 branch
- **产物**: GitHub Actions Artifacts（30 天保留，含 sha256）

---

## 目录结构

```
.
├── .github/workflows/build.yml   # Actions 工作流（matrix: device × branch）
├── scripts/
│   ├── build.sh                  # 编译入口脚本（接受 DEVICE + BRANCH 环境变量）
│   └── diffconfig.sh             # 从 .config 提取 diffconfig
├── files/
│   ├── r66s.config               # R66S 的完整编译配置
│   ├── r66s.diffconfig           # R66S 的精简配置（review 用）
│   ├── .config                   # 单设备兼容 fallback（可选）
│   └── <device>.config           # 其他设备的 config 文件
├── .gitignore
└── README.md
```

**配置解析优先级**（在 `build.sh` 里）：
1. `files/$DEVICE.config`（按设备名匹配）
2. `files/.config`（单设备 fallback）
3. 报错退出

---

## 快速开始

### 1. 准备 `.config`

每个设备对应 `files/<slug>.config`（`<slug>` 是你在 workflow matrix 里用的设备名）。

获取 `.config` 的方式：

| 来源 | 命令 |
|---|---|
| 本地已用 `make menuconfig` 生成 | `cp immortalwrt/.config files/<slug>.config` |
| 从已编译设备反推（不推荐，缺包） | `zcat /proc/config.gz > files/<slug>.config` |
| 官方 defconfig 起步 | `git clone https://github.com/immortalwrt/immortalwrt && cd immortalwrt && make defconfig`，再把生成的 `.config` 拷过来 |

**生成 `diffconfig`（便于 review）：**

```bash
bash scripts/diffconfig.sh files/<slug>.config files/<slug>.diffconfig
```

### 2. 推到 GitHub

```bash
git add .gitignore .github README.md files scripts
git commit -m "Initial ImmortalWrt build pipeline"
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

### 3. 在 GitHub 上启用 Actions

1. 进入仓库 **Settings → Actions → General**
2. 勾选 **Allow all actions and reusable workflows**
3. 进入 **Actions** 页面，等待首次构建
   - 首次约 **1.5–3 小时**（拉源码 + 首次下载 toolchain + 编译所有设备）
   - 之后有缓存约 **30–60 分钟/设备**

### 4. 下载固件

每次 run 结束后在 **Artifacts** 区下载：

```
immortalwrt-r66s-master-<run-number>.zip
├── nanopi-r66s/
│   ├── immortalwrt-rockchip-armv8-lunzn_fastrhino-r66s-squashfs-sysupgrade.img.gz
│   ├── immortalwrt-rockchip-armv8-lunzn_fastrhino-r66s-ext4-sysupgrade.img.gz
│   └── ...
├── packages/
├── manifest.txt
└── SHA256SUMS
```

校验：

```bash
sha256sum -c SHA256SUMS   # 在解压后的目录里
```

---

## 添加新设备

### 步骤

1. **放 config**：
   ```bash
   cp /path/to/your/new-device.config files/redmi-ax6s.config
   bash scripts/diffconfig.sh files/redmi-ax6s.config files/redmi-ax6s.diffconfig
   ```

2. **改 workflow**（`.github/workflows/build.yml`）：
   ```yaml
   strategy:
     fail-fast: false
     matrix:
       device: [r66s, redmi-ax6s]      # 在这里加 slug
   ```

3. **（可选）按设备放补丁/自定义文件**：
   ```
   files/
   ├── redmi-ax6s.config
   ├── redmi-ax6s.diffconfig
   └── redmi-ax6s/                     # 整个目录会被 rsync 进源树 rootfs
       ├── etc/
       │   └── config/
       │       └── passwall
       └── usr/
           └── bin/
               └── my-helper.sh
   ```
   OpenWrt 的 `files/` 机制：源码根目录下的 `files/` 会被拷贝到最终固件里对应位置。
   如果需要这个特性，可以扩展 `build.sh` 把 `files/$DEVICE/` 拷贝到 `$SRC_DIR/files/`。

4. **提交并推送**：
   ```bash
   git add files/redmi-ax6s.config files/redmi-ax6s.diffconfig .github/workflows/build.yml
   git commit -m "Add Redmi AX6S build target"
   git push
   ```

下次定时/手动触发时会自动加入新设备。

### 设备命名规范

建议用 **短横线连接的 slug**（与下游 OpenWrt 设备树或社区常用名一致）：

| Slug | 对应设备 |
|---|---|
| `r66s` | FriendlyElec NanoPi R66S |
| `redmi-ax6s` | Xiaomi Redmi AX6S / AX3200 |
| `x86_64` | x86_64 通用（PC/软路由） |
| `r4s` | FriendlyElec NanoPi R4S |

slug 名只影响 workflow matrix、cache key、artifact 名——不影响 OpenWrt 内部的 `CONFIG_TARGET_PROFILE`，后者在 `.config` 里指定。

---

## 配置选项

### 切换 ImmortalWrt 分支

| 方式 | 操作 |
|---|---|
| 手动构建 | Actions 页面 Run workflow 时选择 branch（下拉框） |
| 定时构建 | 修改 `.github/workflows/build.yml` 里 `env.IMMORTALWRT_BRANCH` 默认值 |

常用分支：
- `master`：ImmortalWrt 滚动分支，最新但可能不稳定
- `openwrt-23.05`：基于 OpenWrt 23.05，相对稳定
- `openwrt-21.02`：旧 LTS

### 修改构建参数

环境变量（在 workflow 或 build.sh 里调整）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DEVICE` | `r66s` | 设备 slug（由 matrix 注入） |
| `IMMORTALWRT_REPO` | `https://github.com/immortalwrt/immortalwrt.git` | 源码仓库 |
| `IMMORTALWRT_BRANCH` | `master` | 分支 |
| `JOBS` | `nproc`（runner 上 = 4） | 并行编译任务数 |
| `ROOT_DIR` | `${{ github.workspace }}` | 仓库根路径 |

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 磁盘满 / `No space left on device` | dl + build_dir + staging_dir 总占用 25–35GB，runner 默认 ~14GB 不够 | 已加 `Free up disk space` 步骤删 dotnet/ghc；若仍 OOM 改用 self-hosted runner |
| `feeds update` 卡死 | 网络抽风 | 重跑 workflow（cache 已保留） |
| `make download` 报 hash mismatch | 上游 dl URL 变了 / cache 损坏 | 删对应 cache 重跑 |
| 6 小时超时 | 单设备包过多 | 砍包，或拆多次构建；多设备 matrix 也会让总时间叠加 |
| ccache 没生效 | 缓存 key 变了（device/branch/.config 任一改动） | 正常现象，下次构建会重建 |
| matrix 中某个设备报错 | 该 `.config` 不适合当前 branch | 检查 `make defconfig` 输出；或单独跑那个 device |

---

## 安全提醒

- **私有仓库** 每月 2000 分钟免费（公开无限）。
- `.config` 会暴露你启用的所有包和任何自定义 feed URL。
- 避免把密钥、API token 写进配置。

---

## License

MIT
