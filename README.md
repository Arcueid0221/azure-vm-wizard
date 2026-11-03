# Azure 开机向导（azure-vm-wizard）

给新手用的 Azure 开虚拟机脚本，一问一答，每一步直接回车就是推荐选项。专门照顾 **Azure for Students（学生订阅）**：

- 自动认出哪个是学生订阅（标 ★），选到学校/公司订阅时会警告
- 学生订阅没注册计算服务时帮你注册（不注册的话配额是空的，看起来什么都开不了）
- 只列出你的订阅**允许的区域**、**配额够用**的机型，带官方价格和 ★ 免费额度标记
- 创建前列出每月费用清单，再把要执行的命令演练给你看，确认后才创建
- 开放端口、每天自动关机可选
- 管理菜单：看登录命令、停止（解除分配）、启动、删除
- 查本月花费；常见报错翻译成能照着做的建议
- 中文 / English 界面

English: an interactive Azure VM wizard for beginners, especially Azure for Students. Run it with `--lang en`.

## 怎么运行

### 推荐：在 Azure Cloud Shell 里运行（什么都不用装）

1. 打开 [Azure 控制台](https://portal.azure.com)，点右上角的 Cloud Shell 图标，选 **Bash**。
2. 粘贴运行（已在 Mac 上实测能下载并运行；Cloud Shell 里的交互未实测）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Arcueid0221/azure-vm-wizard/main/azure-vm-wizard.sh)
```

注意要用 `bash <(curl …)`，不要用 `curl … | bash`：后者会让脚本读不到你的键盘输入。

在 Cloud Shell 里建的 SSH 私钥存在云端，创建完成后脚本会提示你下载到自己电脑。

### 在自己电脑上运行（Mac / Linux）

需要 Azure CLI、jq、curl。Mac：

```bash
brew install azure-cli jq
```

```bash
bash azure-vm-wizard.sh
```

第一次运行会打开浏览器让你登录 Azure。

### 常用参数

```bash
bash azure-vm-wizard.sh --help
```

| 参数 | 作用 |
|---|---|
| `--create` / `--manage` / `--cost` | 直接进入开新机器 / 管理机器 / 查花费 |
| `--region japaneast --size B2ats_v2 --image ubuntu` | 跳过对应的问题 |
| `--name 机器名 --rg 资源组 --user 用户名 --key 私钥路径` | 同上；`--manage --name 机器名` 直接管理这台 |
| `--ports 80,443` | 额外开放端口，`none` 不开 |
| `--shutdown 23:00` | 每天按本机时间自动关机，`none` 不开 |
| `--dry-run` | 只演练，打印命令，不创建 |
| `--yes` | 跳过最后的"确认创建"（没有终端时必须加） |
| `--lang en` | 英文界面 |

例如，不回答任何问题、只看会执行什么：

```bash
bash azure-vm-wizard.sh --create --region japaneast --size B2pts_v2 --image debian --name t2 --user lwl --ports none --shutdown none --dry-run </dev/null
```

## 需要知道的几件事

- **免费额度**：学生订阅 12 个月内，B1s、B2pts_v2、B2ats_v2 每种每月 750 小时免费，另含两块 64GB P6 高级 SSD。脚本按这个标 ★，以控制台"免费服务"页为准。
- **不是每个区域都有所有免费机型**：例如 japaneast 的 B1s 对学生订阅不开放，koreacentral 没有 B2pts_v2。脚本只列出真正能开的。
- **停止 ≠ 在系统里关机**：在系统里 `shutdown` 后仍然计费，要在 Azure 里"停止（解除分配）"。停止后硬盘和公网 IP 仍然收费，彻底不用就删除。
- **剩余额度**命令行查不到，去 <https://www.microsoftazuresponsorships.com/balance> 看。费用数据有 8 到 24 小时延迟。
- 价格来自 [Azure 零售价格接口](https://prices.azure.com/api/retail/prices)（美元、Linux 按量付费）。

## 怎么测试

```bash
shellcheck -s bash azure-vm-wizard.sh
```

交互流程可以用答案文件代替键盘（`AZW_TTY`，每行一个回答，空行等于回车），配合 `--dry-run` 不会创建任何东西：

```bash
printf '\n\n\n\n\n\nwiz-test\n\n\n\n80,443\n23:00\n' > /tmp/ans.txt
AZW_TTY=/tmp/ans.txt bash azure-vm-wizard.sh --dry-run
```

## 发布记录

### v1.1.0（2026-11-03）

- `--manage --name 机器名` 直接选中要管理的机器
- 创建时间提示改为 3 到 5 分钟（实测约 4 分半）
- 登录说明里加上 ssh 超时的排查提示

用脚本在 koreacentral 真实走了一遍完整流程（全参数 + `--yes`），已实测：

- 创建 B2ats_v2 + Ubuntu 24.04，新生成的钥匙能登录
- 开放 80、443 端口：防火墙规则已生效（优先级 1010）
- 每天 23:00 自动关机：Azure 里的关机计划为 UTC 15:00，已启用
- 管理菜单：停止（解除分配）、启动（公网 IP 不变）、删除时输错名字会取消、输对后整组删除完成
- 实测中作者本机所在网络连不上这台机器的 22 端口，从另外两台云服务器都能连上，判断是本地网络问题而不是脚本问题

未实测：管理菜单里的"设置或取消每天自动关机"；Cloud Shell、Linux、Windows 上的交互。


### v1.0.0（2026-11-03）

首个版本，发布到 GitHub 公开仓库 [Arcueid0221/azure-vm-wizard](https://github.com/Arcueid0221/azure-vm-wizard)。已实测（macOS，bash 3.2，Azure CLI 2.91.0，学生订阅）：

- shellcheck 无告警
- 交互开机流程（默认回答 + 开端口 + 自动关机）演练到最后一步，时区换算正确（本机 23:00 → UTC 1500）
- 全参数、无终端模式；无终端且没加 `--yes` 时拒绝创建
- 指定的机型在该区域不可用时给出提示（koreacentral 的 B2pts_v2）
- 保留用户名（admin）被拦下并重新询问
- `--cost`、`--manage` 的"看登录命令"、英文界面

未实测：

- 真正创建、开放端口、自动关机、停止、启动、删除（已在 v1.1.0 实测）
- Cloud Shell、Linux、Windows 上运行；真实终端（`/dev/tty`）下的交互（`bash <(curl …)` 只实测了下载和 `--version`）
- 未登录时自动 `az login`、订阅没有区域策略时手动输入区域、计算服务未注册时的注册步骤
- Debian 和 ARM 镜像只确认了镜像存在
