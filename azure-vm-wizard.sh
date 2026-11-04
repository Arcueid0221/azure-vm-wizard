#!/usr/bin/env bash
# Azure 开机向导 / Azure VM wizard
# 面向新手：选订阅 → 注册计算服务 → 选区域 → 看配额和价格 → 选机型 → 费用清单 → 演练 → 创建；另有管理（含换公网 IP）和查花费菜单。
# 依赖 az、jq、curl（Azure Cloud Shell 里都自带）。兼容 macOS 自带的 bash 3.2。
# 用法见 bash azure-vm-wizard.sh --help
# shellcheck disable=SC2015,SC2016  # A && ok || explain：ok 不会失败；$100 是字面文字
VERSION=1.2.0
set -uo pipefail
export AZURE_CORE_ONLY_SHOW_ERRORS=true PYTHONWARNINGS=ignore

# 学生免费额度里的机型（每种每月 750 小时，12 个月），以控制台"免费服务"页为准
FREE_SIZES="Standard_B1s Standard_B2pts_v2 Standard_B2ats_v2"
HOURS_PER_MONTH=730
# 推荐区域顺序：离中国、日本近的排前面
PREFERRED_REGIONS="japaneast koreacentral eastasia southeastasia japanwest koreasouth westus2 westus3"
BALANCE_URL="https://www.microsoftazuresponsorships.com/balance"
PRICE_API="https://prices.azure.com/api/retail/prices"

# ---------- 参数 ----------
UI_LANG=zh; case ${LANG:-} in zh*) ;; *) [ -n "${LANG:-}" ] && UI_LANG=en ;; esac
OPT_SUB=""; OPT_REGION=""; OPT_SIZE=""; OPT_IMAGE=""; OPT_NAME=""; OPT_RG=""; OPT_USER=""; OPT_KEY=""
OPT_PORTS=""; OPT_SHUTDOWN=""; OPT_YES=""; OPT_DRY=""; OPT_MODE=""

usage() {
  cat <<'EOF'
Azure 开机向导 / Azure VM wizard

不带参数运行就是一问一答的向导，每一步直接回车即选推荐项。
Run without options for the interactive wizard; press Enter to accept each recommended choice.

  --create | --manage | --cost   直接进入：开新机器 / 管理机器 / 查花费
  --subscription 名称或ID        --region japaneast       --size Standard_B2ats_v2
  --image ubuntu|debian          --name 机器名（--manage 时直接选中这台）  --rg 资源组
  --user 登录用户名              --key 私钥路径           --ports 80,443（none 不开）
  --shutdown 23:00|none          每天自动关机（本机时区）
  --dry-run                      只打印将执行的命令，不创建
  --yes                          跳过最后的"确认创建"
  --lang zh|en                   界面语言
  -h, --help                     显示帮助    -v, --version  显示版本
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --create) OPT_MODE=create ;;
    --manage) OPT_MODE=manage ;;
    --cost) OPT_MODE=cost ;;
    --subscription) OPT_SUB=${2:-}; shift ;;
    --region) OPT_REGION=${2:-}; shift ;;
    --size) OPT_SIZE=${2:-}; shift ;;
    --image) OPT_IMAGE=${2:-}; shift ;;
    --name) OPT_NAME=${2:-}; shift ;;
    --rg) OPT_RG=${2:-}; shift ;;
    --user) OPT_USER=${2:-}; shift ;;
    --key) OPT_KEY=${2:-}; shift ;;
    --ports) OPT_PORTS=${2:-}; shift ;;
    --shutdown) OPT_SHUTDOWN=${2:-}; shift ;;
    --dry-run) OPT_DRY=1 ;;
    --yes) OPT_YES=1 ;;
    --lang) UI_LANG=${2:-zh}; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "$VERSION"; exit 0 ;;
    *) echo "未知参数 / unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case ${OPT_SIZE:-} in ""|Standard_*) ;; *) OPT_SIZE="Standard_$OPT_SIZE" ;; esac

# ---------- 输出 ----------
if [ -t 2 ]; then B=$'\033[1m'; Y=$'\033[33m'; R=$'\033[31m'; G=$'\033[32m'; N=$'\033[0m'; else B=""; Y=""; R=""; G=""; N=""; fi
t() { if [ "$UI_LANG" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N" >&2; }
info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s⚠ %s%s\n' "$Y" "$*" "$N" >&2; }
ok() { printf '%s✓ %s%s\n' "$G" "$*" "$N" >&2; }
# die 可能在 $(…) 子 shell 里被调用，所以连主进程一起结束
die() { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; kill -s TERM $$ 2>/dev/null; exit 1; }
trap 'exit 1' TERM

# ---------- 输入：从 /dev/tty 读，这样 bash <(curl …) 也能正常交互；AZW_TTY 可指定答案文件（测试用） ----------
if ! { exec 3<"${AZW_TTY:-/dev/tty}"; } 2>/dev/null; then NO_TTY=1; fi
read_in() {
  local a
  # 没有终端时一律按"直接回车"处理：有默认值就用默认值，确认类问题视为"否"
  [ -z "${NO_TTY:-}" ] || return 0
  printf '%s' "$1" >&2
  IFS= read -r a <&3 || a=""
  printf '%s' "$a"
}

# ask "提示" [默认值]
ask() { local a; a=$(read_in "$1${2:+ [$2]}: "); printf '%s' "${a:-${2:-}}"; }

# confirm "提示"：回答 y 才返回成功
confirm() {
  local a
  a=$(read_in "$1 (y/N): ")
  [ "$a" = y ] || [ "$a" = Y ]
}

# pick "标题" 默认序号 选项1 选项2 …：选中的序号（从 1 开始）输出到 stdout；默认序号为 0 表示没有默认
pick() {
  local title=$1 def=$2 i=1 n mark
  shift 2
  [ -n "${NO_TTY:-}" ] && [ "$def" = 0 ] && die "$(t "没有终端，无法回答：$title 请用参数指定（见 --help）" "No terminal to answer: $title Pass options instead (see --help)")"
  info "$title"
  for o in "$@"; do
    mark="  "; [ "$i" = "$def" ] && mark="→ "
    printf '  %s%2d) %s\n' "$mark" "$i" "$o" >&2
    i=$((i + 1))
  done
  while :; do
    if [ "$def" -gt 0 ]; then n=$(read_in "$(t "选择编号（回车 = ${def}）: " "Choose number (Enter = $def): ")")
    else n=$(read_in "$(t '选择编号: ' 'Choose number: ')"); fi
    [ -z "$n" ] && [ "$def" -gt 0 ] && n=$def
    if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $# ]; then echo "$n"; return; fi
  done
}

azs() { az "$@" --subscription "$SUB_ID"; }
in_cloud_shell() { [ -n "${ACC_CLOUD:-}" ] || [[ ${AZUREPS_HOST_ENVIRONMENT:-} == cloud-shell* ]]; }
money() { LC_ALL=C printf '$%.2f' "$1"; }

region_label() {
  local zh en
  case $1 in
    japaneast) zh="日本东部（东京），离中国、日本近，延迟低"; en="Japan East (Tokyo)" ;;
    japanwest) zh="日本西部（大阪），离中国、日本近"; en="Japan West (Osaka)" ;;
    koreacentral) zh="韩国中部（首尔），离中国、日本近，延迟低"; en="Korea Central (Seoul)" ;;
    koreasouth) zh="韩国南部（釜山），离中国、日本近"; en="Korea South (Busan)" ;;
    eastasia) zh="东亚（香港），离中国大陆近"; en="East Asia (Hong Kong)" ;;
    southeastasia) zh="东南亚（新加坡）"; en="Southeast Asia (Singapore)" ;;
    indonesiacentral) zh="印尼中部（雅加达）"; en="Indonesia Central (Jakarta)" ;;
    centralindia) zh="印度中部（浦那）"; en="Central India (Pune)" ;;
    australiaeast) zh="澳大利亚东部（悉尼）"; en="Australia East (Sydney)" ;;
    westus) zh="美国西部（加州）"; en="West US (California)" ;;
    westus2) zh="美国西部 2（华盛顿州）"; en="West US 2 (Washington)" ;;
    westus3) zh="美国西部 3（亚利桑那州）"; en="West US 3 (Arizona)" ;;
    eastus) zh="美国东部（弗吉尼亚州）"; en="East US (Virginia)" ;;
    eastus2) zh="美国东部 2（弗吉尼亚州）"; en="East US 2 (Virginia)" ;;
    centralus) zh="美国中部（爱荷华州）"; en="Central US (Iowa)" ;;
    canadacentral) zh="加拿大中部（多伦多）"; en="Canada Central (Toronto)" ;;
    uksouth) zh="英国南部（伦敦）"; en="UK South (London)" ;;
    westeurope) zh="西欧（荷兰）"; en="West Europe (Netherlands)" ;;
    northeurope) zh="北欧（爱尔兰）"; en="North Europe (Ireland)" ;;
    francecentral) zh="法国中部（巴黎）"; en="France Central (Paris)" ;;
    germanywestcentral) zh="德国中西部（法兰克福）"; en="Germany West Central (Frankfurt)" ;;
    swedencentral) zh="瑞典中部"; en="Sweden Central" ;;
    brazilsouth) zh="巴西南部（圣保罗）"; en="Brazil South (São Paulo)" ;;
    *) zh=""; en="" ;;
  esac
  printf '%-18s %s' "$1" "$(t "$zh" "$en")"
}

# 把 az 的英文报错翻译成能照着做的建议
explain_error() {
  local f=$1
  info ""
  if grep -q -E 'QuotaExceeded|exceeding approved .* quota|OperationNotAllowed' "$f"; then
    warn "$(t '配额不够：这个区域剩下的 vCPU 不够开这台机器。换个更小的机型，或者换个区域。' 'Quota exceeded: not enough vCPUs left in this region. Pick a smaller size or another region.')"
  elif grep -q -E 'SkuNotAvailable' "$f"; then
    warn "$(t '这个区域暂时没有这款机型（或者不对你的订阅开放）。换个区域或机型。' 'This size is not available in this region for your subscription. Try another region or size.')"
  elif grep -q -E 'AllocationFailed|ZonalAllocationFailed|OverconstrainedAllocationRequest' "$f"; then
    warn "$(t '机房暂时没有空闲机器。过一会儿再试，或者换个区域。' 'The datacenter is out of capacity right now. Retry later or pick another region.')"
  elif grep -q -E 'RequestDisallowedByPolicy' "$f"; then
    warn "$(t '订阅的策略不允许这样创建（常见原因是区域不在允许列表里）。重新运行脚本，从列表里选区域。' 'A subscription policy blocked this (usually the region is not allowed). Rerun and pick a region from the list.')"
  elif grep -q -E 'MissingSubscriptionRegistration' "$f"; then
    warn "$(t '订阅还没注册所需的服务。重新运行脚本，第 2 步会帮你注册。' 'A required resource provider is not registered. Rerun; step 2 registers it.')"
  elif grep -q -E 'adminUsername|reserved|InvalidParameter' "$f"; then
    warn "$(t '参数不合法，最常见的是用户名用了 root、admin、user 这类保留名。换个用户名再试。' 'Invalid parameter, most often a reserved username such as root/admin/user. Try another username.')"
  elif grep -q -E 'ResourceGroupBeingDeleted' "$f"; then
    warn "$(t '同名资源组正在删除中。等几分钟，或者换个资源组名。' 'A resource group with this name is being deleted. Wait a few minutes or use another name.')"
  elif grep -q -E 'AuthorizationFailed|Forbidden' "$f"; then
    warn "$(t '没有权限在这个订阅里创建。确认选的是自己的学生订阅。' 'No permission in this subscription. Make sure you picked your own student subscription.')"
  elif grep -q -E 'SubscriptionNotFound|ReadOnlyDisabledSubscription|SubscriptionDisabled' "$f"; then
    warn "$(t '订阅不可用（可能额度用完或已过期）。查一下余额：' 'The subscription is disabled (credit used up or expired). Check your balance:') $BALANCE_URL"
  else
    warn "$(t '没认出这个错误，原文如下：' 'Unrecognised error, original message:')"
  fi
  sed 's/^/    /' "$f" | head -20 >&2
}

# 某区域某前缀的 Linux 按量价格，输出 {"机型": 每小时美元}
fetch_vm_prices() {
  local loc=$1 prefix=$2 page next prices='{}'
  page=$(curl -fsS -G "$PRICE_API" --data-urlencode \
    "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$loc' and priceType eq 'Consumption' and contains(armSkuName,'$prefix')") || { echo '{}'; return; }
  while :; do
    prices=$(jq -c --argjson p "$prices" '$p + ([.Items[]
      | select((.productName|test("Windows|Cloud Services")|not) and (.skuName|test("Spot|Low Priority")|not))
      | {key:.armSkuName, value:.retailPrice}] | from_entries)' <<<"$page")
    next=$(jq -r '.NextPageLink // empty' <<<"$page")
    [ -n "$next" ] || break
    page=$(curl -fsS "$next") || break
  done
  echo "$prices"
}

# fetch_price 服务名 区域 meterName：输出单价，查不到输出 -1
fetch_price() {
  curl -fsS -G "$PRICE_API" --data-urlencode \
    "\$filter=serviceName eq '$1' and armRegionName eq '$2' and priceType eq 'Consumption' and meterName eq '$3'" 2>/dev/null \
    | jq -r '[.Items[].retailPrice][0] // -1' 2>/dev/null || echo -1
}

# ================= 公共步骤 =================
check_env() {
  local c
  for c in az jq curl; do
    command -v "$c" >/dev/null || die "$(t "缺少 ${c}。最省事的办法：在 Azure 控制台右上角打开 Cloud Shell（选 Bash）运行本脚本，什么都不用装。" "Missing $c. Easiest fix: run this script in Azure Cloud Shell (Bash), which has everything.")"
  done
  if ! az account show -o none 2>/dev/null; then
    info "$(t '还没登录 Azure，马上打开浏览器登录……' 'Not logged in; opening the browser to sign in...')"
    az login -o none || die "$(t '登录失败' 'Login failed')"
  fi
}

choose_subscription() {
  say "$(t '选订阅' 'Choose subscription')"
  local ids=() names=() quotas=() labels=() id name q def=0 i
  while IFS=$'\t' read -r id name; do
    q=$(az rest --method get --url "https://management.azure.com/subscriptions/$id?api-version=2022-12-01" \
      --query subscriptionPolicies.quotaId -o tsv 2>/dev/null </dev/null)
    ids+=("$id"); names+=("$name"); quotas+=("$q")
    case $q in
      AzureForStudents*) labels+=("★ $(t '学生订阅' 'Student'): $name"); [ "$def" = 0 ] && def=${#ids[@]} ;;
      *) labels+=("  $name ($q)") ;;
    esac
  done < <(az account list --all --query "[?state=='Enabled'].[id,name]" -o tsv)
  [ ${#ids[@]} -gt 0 ] || die "$(t '这个账号下没有可用订阅。学生优惠要先在 https://azure.microsoft.com/free/students 用学校邮箱开通。' 'No enabled subscription. Activate Azure for Students first: https://azure.microsoft.com/free/students')"

  i=-1
  if [ -n "$OPT_SUB" ]; then
    for n in "${!ids[@]}"; do [ "${ids[$n]}" = "$OPT_SUB" ] || [ "${names[$n]}" = "$OPT_SUB" ] && i=$n; done
    [ "$i" -ge 0 ] || die "$(t "找不到订阅：$OPT_SUB" "Subscription not found: $OPT_SUB")"
  else
    [ "$def" = 0 ] && warn "$(t '没找到学生订阅（Azure for Students）。如果你是学生，先用学校邮箱开通；别用学校或公司的订阅开机。' 'No Azure for Students subscription found. Activate it first; do not use a school or company subscription.')"
    i=$(( $(pick "$(t '带 ★ 的才有学生优惠：' 'Only ★ has student credit:')" "$def" "${labels[@]}") - 1 ))
  fi
  SUB_ID=${ids[$i]}; SUB_NAME=${names[$i]}; SUB_IS_STUDENT=""
  case ${quotas[$i]} in
    AzureForStudents*) SUB_IS_STUDENT=1 ;;
    *) warn "$(t "\"$SUB_NAME\" 不是学生订阅，开机的钱会记到这个订阅的账单上（学校、公司或你的信用卡）。" "\"$SUB_NAME\" is not a student subscription; costs go to its own bill.")"
       [ -n "$OPT_YES" ] || confirm "$(t '确定用它继续' 'Continue with it')" || exit 0 ;;
  esac
  ok "$(t '订阅' 'Subscription'): $SUB_NAME"
}

ensure_compute() {
  local state
  state=$(azs provider show -n Microsoft.Compute --query registrationState -o tsv)
  [ "$state" = Registered ] && return
  say "$(t '注册计算服务' 'Register compute service')"
  info "$(t "计算服务（Microsoft.Compute）状态：${state}。没注册时配额查出来是空的，看起来就像什么机器都开不了。注册免费，不会创建任何东西。" "Microsoft.Compute is $state. Until registered, quotas look empty. Registering is free and creates nothing.")"
  [ -n "$OPT_YES" ] || confirm "$(t '现在注册' 'Register now')" || die "$(t '未注册，无法继续' 'Not registered; cannot continue')"
  info "$(t '注册中，通常要 1 到 3 分钟……' 'Registering, usually 1-3 minutes...')"
  azs provider register -n Microsoft.Compute --wait || die "$(t '注册失败' 'Registration failed')"
  ok "$(t '已注册' 'Registered')"
}

# ================= 开新机器 =================
choose_region() {
  say "$(t '选区域' 'Choose region')"
  local regions=() labels=() r def=0 p n
  while read -r r; do [ -n "$r" ] && regions+=("$r"); done < <(
    azs policy assignment list --disable-scope-strict-match \
      --query "[].parameters.listOfAllowedLocations.value[]" -o tsv 2>/dev/null | sort -u)
  if [ -n "$OPT_REGION" ]; then
    LOC=$OPT_REGION
  elif [ ${#regions[@]} -gt 0 ]; then
    for p in $PREFERRED_REGIONS; do
      for n in "${!regions[@]}"; do [ "${regions[$n]}" = "$p" ] && [ "$def" = 0 ] && def=$((n + 1)); done
    done
    [ "$def" = 0 ] && def=1
    for r in "${regions[@]}"; do labels+=("$(region_label "$r")"); done
    LOC=${regions[$(( $(pick "$(t '这个订阅允许的区域（→ 是推荐）：' 'Regions allowed for this subscription (→ = recommended):')" "$def" "${labels[@]}") - 1 ))]}
  else
    info "$(t '没查到区域限制，请输入区域英文名，例如 japaneast（东京）、koreacentral（首尔）、eastasia（香港）、westus2（美国西部）。' 'No region policy found. Enter a region, e.g. japaneast, koreacentral, eastasia, westus2.')"
    LOC=$(ask "$(t '区域' 'Region')" japaneast)
  fi
  ok "$(t '区域' 'Region'): $(region_label "$LOC")"
}

show_quota() {
  USAGE=$(azs vm list-usage -l "$LOC" -o json 2>/dev/null) || die "$(t "查不到 $LOC 的配额，检查区域名是否拼对" "Cannot read quota for $LOC; check the region name")"
  CORES_LEFT=$(jq -r '[.[]|select(.name.value=="cores")|((.limit|tonumber)-(.currentValue|tonumber))][0] // 0' <<<"$USAGE")
  info "$(jq -r --arg l "$(t '区域总 vCPU：已用 %s / 上限 %s' 'Regional vCPUs: used %s / limit %s')" \
    '.[]|select(.name.value=="cores") as $x|$l|sub("%s";"\($x.currentValue)")|sub("%s";"\($x.limit)")' <<<"$USAGE")"
  [ "$CORES_LEFT" -gt 0 ] || die "$(t '这个区域的 vCPU 已经用完，换个区域，或者先删掉不用的机器（--manage）。' 'No vCPUs left here. Pick another region or delete unused VMs (--manage).')"
}

choose_size() {
  say "$(t '选机型' 'Choose size')"
  local prefix skus prices rows labels=() names=() archs=() prems=() hours=() name v mem arch prem price free def=0 i n
  if [ -n "$OPT_SIZE" ]; then
    prefix=$OPT_SIZE
  else
    local fams=("$(t 'B 系列：突发型，最便宜，有免费机型（推荐）' 'B series: burstable, cheapest, has free sizes (recommended)')"
      "$(t 'D 系列：通用型' 'D series: general purpose')" "$(t 'E 系列：大内存' 'E series: memory optimised')"
      "$(t 'F 系列：高主频' 'F series: compute optimised')" "$(t 'A 系列：老款' 'A series: legacy')")
    local prefixes=(Standard_B Standard_D Standard_E Standard_F Standard_A)
    prefix=${prefixes[$(( $(pick "$(t '先选系列（只下载这一系列的数据，避免拖慢电脑）：' 'Pick a series first (downloads only that series):')" 1 "${fams[@]}") - 1 ))]}
  fi

  info "$(t '查询机型和价格，大约 10 到 30 秒……' 'Fetching sizes and prices, about 10-30 s...')"
  skus=$(azs vm list-skus -l "$LOC" --resource-type virtualMachines --size "$prefix" -o json) || die "$(t '查机型失败' 'Failed to list sizes')"
  prices=$(fetch_vm_prices "$LOC" "$prefix")

  # 每行：名称 vCPU 内存 架构 是否支持高级盘 时价（查不到价格为 -1）
  rows=$(jq -r --argjson u "$USAGE" --argjson p "$prices" --argjson left "$CORES_LEFT" '
    ($u | map({key:.name.value, value:((.limit|tonumber)-(.currentValue|tonumber))}) | from_entries) as $q
    | .[] | select([.restrictions[]? | select(.type=="Location")] | length == 0)
    | (.capabilities | map({key:.name,value:.value}) | from_entries) as $c
    | ($c.vCPUs|tonumber) as $v
    | select(($q[.family] // 0) >= $v and $left >= $v)
    | [.name, $v, $c.MemoryGB, ($c.CpuArchitectureType // "x64"), ($c.PremiumIO // "False"), ($p[.name] // -1)]
    | @tsv' <<<"$skus" | sort -t$'\t' -k6,6g -k1,1 | awk -F'\t' '$6 >= 0')
  if [ -n "$OPT_SIZE" ]; then rows=$(awk -F'\t' -v s="$OPT_SIZE" '$1 == s' <<<"$rows"); fi
  [ -n "$rows" ] || die "$(t "$LOC 里没有配额够用的 ${OPT_SIZE:-这个系列}。换个系列或区域，或者先删掉不用的机器。" "No size in $LOC fits your quota. Try another series or region.")"

  while IFS=$'\t' read -r name v mem arch prem price; do
    free=""; case " $FREE_SIZES " in *" $name "*) free="★ $(t '免费额度' 'free tier')" ;; esac
    if [ "$def" = 0 ] && [ -n "$free" ] && [ "$arch" = x64 ]; then def=$(( ${#names[@]} + 1 )); fi
    labels+=("$(LC_ALL=C printf '%-20s %2s vCPU %5s GB  %-5s  $%.4f/h  ~%8s/%s  %s' \
      "$name" "$v" "$mem" "$arch" "$price" "$(money "$(echo "$price*$HOURS_PER_MONTH" | bc -l)")" "$(t '月' 'mo')" "$free")")
    names+=("$name"); archs+=("$arch"); prems+=("$prem"); hours+=("$price")
  done <<<"$rows"
  [ "$def" = 0 ] && def=1

  if [ ${#names[@]} = 1 ] && [ -n "$OPT_SIZE" ]; then i=0
  else
    info "$(t '价格是官方零售价（美元，Linux 按量付费），只含机器本身。★ 的在学生免费额度内，每月 750 小时不扣钱。' 'Prices are official USD pay-as-you-go Linux rates for the VM only. ★ = within the student free tier (750 h/month).')"
    info "$(t 'x64 兼容性最好；Arm64 稍便宜，但有些软件没有 ARM 版本。' 'x64 is most compatible; Arm64 is cheaper but some software lacks ARM builds.')"
    i=$(( $(pick "$(t '配额够用的机型（按价格排序）：' 'Sizes that fit your quota (by price):')" "$def" "${labels[@]}") - 1 ))
  fi
  SIZE=${names[$i]}; ARCH=${archs[$i]}; VM_HOURLY=${hours[$i]}
  SIZE_FREE=""; case " $FREE_SIZES " in *" $SIZE "*) SIZE_FREE=1 ;; esac
  # 免费额度含两块 64GB P6 高级 SSD；机型不支持高级盘时退回标准 SSD（E6）
  if [ "${prems[$i]}" = True ]; then DISK_SKU=Premium_LRS; DISK_METER="P6 LRS Disk"; DISK_SVC=Storage
  else DISK_SKU=StandardSSD_LRS; DISK_METER="E6 LRS Disk"; DISK_SVC=Storage; fi
  ok "$(t '机型' 'Size'): $SIZE ($ARCH)"
}

choose_image() {
  local x64=(Canonical:ubuntu-24_04-lts:server:latest Debian:debian-12:12-gen2:latest)
  local arm=(Canonical:ubuntu-24_04-lts:server-arm64:latest Debian:debian-12:12-arm64:latest)
  local n
  case $OPT_IMAGE in
    ubuntu) n=1 ;; debian) n=2 ;;
    "") say "$(t '选系统' 'Choose OS')"
        n=$(pick "$(t "系统（已按 $ARCH 架构匹配镜像）：" "OS (image matched to $ARCH):")" 1 \
          "Ubuntu 24.04 LTS（$(t '最常用，教程最多，推荐' 'most common, recommended')）" "Debian 12（$(t '更精简' 'lighter')）") ;;
    *) die "$(t '--image 只能是 ubuntu 或 debian' '--image must be ubuntu or debian')" ;;
  esac
  if [ "$ARCH" = Arm64 ]; then IMAGE=${arm[$((n - 1))]}; else IMAGE=${x64[$((n - 1))]}; fi
  [ "$n" = 1 ] && OS_NAME="Ubuntu 24.04" || OS_NAME="Debian 12"
}

choose_login() {
  say "$(t '名字和登录方式' 'Names and login')"
  VM=${OPT_NAME:-$(ask "$(t '机器名（字母、数字、减号）' 'VM name (letters, digits, hyphens)')" my-vm)}
  [[ $VM =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "$(t '机器名只能用字母、数字和减号' 'VM name: letters, digits and hyphens only')"
  RG=${OPT_RG:-$(ask "$(t '资源组（装这台机器所有东西的文件夹）' 'Resource group (folder for everything of this VM)')" "rg-$VM")}
  if [ "$(azs group exists -n "$RG")" = true ] && azs vm show -g "$RG" -n "$VM" -o none 2>/dev/null; then
    die "$(t "$RG 里已经有叫 $VM 的机器了，换个名字" "$RG already has a VM named $VM; choose another name")"
  fi
  while :; do
    USER_NAME=${OPT_USER:-$(ask "$(t '登录用户名（小写字母开头；不能用 root、admin、user 等）' 'Login username (lowercase; not root/admin/user)')" azureuser)}
    case $USER_NAME in
      root|admin|administrator|user|user1|test|guest|sys|support|owner|ubuntu|debian|azureadmin)
        warn "$(t "$USER_NAME 是保留名，Azure 不允许" "$USER_NAME is reserved by Azure")" ;;
      *) [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
         warn "$(t '用户名只能用小写字母、数字、下划线和减号，且以字母开头' 'Use lowercase letters, digits, _ or -, starting with a letter')" ;;
    esac
    [ -n "$OPT_USER" ] && die "$(t '用户名不可用' 'Username not allowed')"
  done
  KEY=${OPT_KEY:-$(ask "$(t 'SSH 私钥路径（不存在就自动新建）' 'SSH private key path (created if missing)')" "$HOME/.ssh/$VM")}
  # shellcheck disable=SC2088  # 用户手打的 ~ 不会被展开，这里手动换成 $HOME
  case $KEY in "~/"*) KEY="$HOME/${KEY#\~/}" ;; esac
  KEY_NEW=""
  [ -f "$KEY.pub" ] || KEY_NEW=1
}

choose_extras() {
  say "$(t '可选设置' 'Optional settings')"
  if [ -z "$OPT_PORTS" ]; then
    info "$(t 'SSH（22 端口）默认已开。要建网站就开 80,443；不需要直接回车。' 'SSH (22) is always open. Enter 80,443 for a website, or press Enter to skip.')"
    PORTS=$(ask "$(t '还要开放的端口（逗号分隔）' 'Extra ports (comma separated)')" none)
  else PORTS=$OPT_PORTS; fi
  [ "$PORTS" = none ] && PORTS=""
  [ -z "$PORTS" ] || [[ $PORTS =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || die "$(t "端口格式不对：$PORTS" "Bad port list: $PORTS")"

  if [ -z "$OPT_SHUTDOWN" ]; then
    info "$(t '每天定时自动关机（解除分配），忘了关也不会一直扣钱。只是练手的话推荐打开；要 24 小时跑服务的就别开。' 'Daily auto-shutdown (deallocate) stops charges if you forget. Good for practice; skip for 24/7 services.')"
    SHUTDOWN=$(ask "$(t "几点关机（本机时间 $(date +%z)，如 23:00；不要就填 none）" "Shutdown time (local $(date +%z), e.g. 23:00; none to skip)")" none)
  else SHUTDOWN=$OPT_SHUTDOWN; fi
  [ "$SHUTDOWN" = none ] && SHUTDOWN=""
  SHUTDOWN_UTC=""
  if [ -n "$SHUTDOWN" ]; then
    [[ $SHUTDOWN =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || die "$(t "时间格式不对：$SHUTDOWN" "Bad time: $SHUTDOWN")"
    # 本机时间 → UTC（auto-shutdown 只认 UTC）
    local z h m off mins
    z=$(date +%z); off=$(( (10#${z:1:2} * 60 + 10#${z:3:2}) * (${z:0:1}1) ))
    h=${SHUTDOWN%%:*}; m=${SHUTDOWN##*:}
    mins=$(( (10#$h * 60 + 10#$m - off + 1440) % 1440 ))
    SHUTDOWN_UTC=$(printf '%02d%02d' $((mins / 60)) $((mins % 60)))
  fi
}

cost_summary() {
  say "$(t '费用清单（每月，美元）' 'Monthly cost (USD)')"
  local vm_m disk_m ip_h ip_m total=0
  vm_m=$(echo "$VM_HOURLY*$HOURS_PER_MONTH" | bc -l)
  disk_m=$(fetch_price "$DISK_SVC" "$LOC" "$DISK_METER")
  ip_h=$(fetch_price "Virtual Network" "$LOC" "Standard IPv4 Static Public IP")
  ip_m=$(echo "$ip_h*$HOURS_PER_MONTH" | bc -l)

  if [ -n "$SIZE_FREE" ] && [ -n "$SUB_IS_STUDENT" ]; then
    info "  $(t '机器' 'VM')        $SIZE  $(money "$vm_m")  ★ $(t '免费额度内（每月 750 小时）' 'free tier (750 h/month)')"
  else
    info "  $(t '机器' 'VM')        $SIZE  $(money "$vm_m")  $(t '扣额度' 'charged')"; total=$(echo "$total+$vm_m" | bc -l)
  fi
  if [ "$DISK_SKU" = Premium_LRS ] && [ -n "$SUB_IS_STUDENT" ]; then
    info "  $(t '系统盘' 'Disk')      64GB P6 SSD  $(money "$disk_m")  ★ $(t '免费额度含 2 块 P6' 'free tier includes 2× P6')"
  else
    info "  $(t '系统盘' 'Disk')      64GB E6 SSD  $( [ "$disk_m" = -1 ] && t '价格未知' 'unknown' || money "$disk_m")  $(t '扣额度' 'charged')"
    [ "$disk_m" = -1 ] || total=$(echo "$total+$disk_m" | bc -l)
  fi
  info "  $(t '公网 IP' 'Public IP')   Standard  $(money "$ip_m")  $(t '按扣额度算（免费服务页若包含公网 IP 则不扣）' 'counted as charged unless your free services list includes it')"
  total=$(echo "$total+$ip_m" | bc -l)
  info "  $(t '出站流量' 'Egress')    $(t '每月前 100GB 免费，超出按量计费' 'first 100 GB/month free, then pay per GB')"
  info "  ${B}$(t '估计每月从额度里扣' 'Estimated monthly charge'): $(money "$total")$N $(t '（不含超额流量；免费额度规则以控制台"免费服务"页为准）' '(excl. extra egress; check Free services in the portal)')"
  [ -n "$SUB_IS_STUDENT" ] && info "  $(t '学生订阅额度 100 美元，用完会停用，不会扣你的信用卡。' 'Student credit is $100; the subscription stops when used up, no card is charged.')"
}

create_vm() {
  local cmd_rg cmd_vm cmd_port cmd_off err
  cmd_rg=(az group create --subscription "$SUB_ID" -n "$RG" -l "$LOC" -o none)
  cmd_vm=(az vm create --subscription "$SUB_ID" -g "$RG" -n "$VM" -l "$LOC"
    --size "$SIZE" --image "$IMAGE" --admin-username "$USER_NAME" --ssh-key-values "$KEY.pub"
    --os-disk-size-gb 64 --storage-sku "$DISK_SKU" --public-ip-sku Standard --nsg-rule SSH
    --os-disk-delete-option Delete --nic-delete-option Delete -o none)
  cmd_port=(az vm open-port --subscription "$SUB_ID" -g "$RG" -n "$VM" --port "$PORTS" --priority 1010 -o none)
  cmd_off=(az vm auto-shutdown --subscription "$SUB_ID" -g "$RG" -n "$VM" --time "$SHUTDOWN_UTC" -o none)

  say "$(t '演练：将要执行的命令' 'Dry run: commands to execute')"
  info "$(t '订阅' 'Subscription'): $SUB_NAME"
  [ -n "$KEY_NEW" ] && info "  ssh-keygen -t ed25519 -f $KEY -N \"\""
  info "  ${cmd_rg[*]}"
  info "  ${cmd_vm[*]}"
  [ -n "$PORTS" ] && info "  ${cmd_port[*]}"
  [ -n "$SHUTDOWN_UTC" ] && info "  ${cmd_off[*]}   # $(t "本机 $SHUTDOWN = UTC $SHUTDOWN_UTC" "local $SHUTDOWN = UTC $SHUTDOWN_UTC")"
  [ -n "$OPT_DRY" ] && { info "$(t '（--dry-run：只演练，没有创建）' '(--dry-run: nothing created)')"; exit 0; }
  [ -n "${NO_TTY:-}" ] && [ -z "$OPT_YES" ] && die "$(t '没有终端确认，要直接创建请加 --yes' 'No terminal to confirm; add --yes to create')"
  [ -n "$OPT_YES" ] || confirm "$(t '确认创建' 'Create now')" || { info "$(t '已取消，什么都没创建。' 'Cancelled; nothing created.')"; exit 0; }

  if [ -n "$KEY_NEW" ]; then
    mkdir -p "$(dirname "$KEY")" && ssh-keygen -t ed25519 -f "$KEY" -N "" -C "$VM" -q </dev/null || die "$(t '生成钥匙失败' 'Key generation failed')"
    ok "$(t '已生成钥匙' 'Key created'): $KEY"
  fi
  err=$(mktemp)
  info "$(t '创建中，大约 3 到 5 分钟……' 'Creating, about 3-5 minutes...')"
  "${cmd_rg[@]}" 2>"$err" || { explain_error "$err"; rm -f "$err"; exit 1; }
  "${cmd_vm[@]}" 2>"$err" || { explain_error "$err"; rm -f "$err"
    info "$(t "资源组 $RG 可能已建好但是空的，可以用 --manage 删掉，或者重新运行时沿用它。" "Resource group $RG may exist but be empty; delete it with --manage or reuse it.")"; exit 1; }
  ok "$(t '机器已创建' 'VM created')"
  if [ -n "$PORTS" ]; then "${cmd_port[@]}" 2>"$err" && ok "$(t "已开放端口 $PORTS" "Opened ports $PORTS")" || explain_error "$err"; fi
  if [ -n "$SHUTDOWN_UTC" ]; then "${cmd_off[@]}" 2>"$err" && ok "$(t "已设置每天 $SHUTDOWN 自动关机" "Auto-shutdown set for $SHUTDOWN daily")" || explain_error "$err"; fi
  rm -f "$err"
  after_create
}

login_help() {
  local ip=$1 user=$2 key=$3 name=$4
  say "$(t '怎么登录' 'How to log in')"
  info "Mac / Linux:"
  info "  ssh -i $key $user@$ip"
  info "Windows（PowerShell）:"
  info "  ssh -i \$HOME\\.ssh\\$(basename "$key") $user@$ip"
  info ""
  info "$(t '想以后直接 ssh 名字 登录，把这段加进 ~/.ssh/config：' 'To log in with just "ssh NAME", add this to ~/.ssh/config:')"
  info "  Host $name"
  info "      HostName $ip"
  info "      User $user"
  info "      IdentityFile $key"
  info ""
  info "$(t 'ssh 连不上（超时）？刚建好的机器等 1 分钟再试；学校、公司的网络可能封了 22 端口，换手机热点或 Cloud Shell 试试。' 'SSH timing out? Wait a minute after creation; school or office networks may block port 22, so try a phone hotspot or Cloud Shell.')"
}

after_create() {
  local ip
  ip=$(azs vm list-ip-addresses -g "$RG" -n "$VM" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
  say "$(t '完成' 'Done')"
  info "$(t '机器' 'VM'): $VM  $SIZE  $OS_NAME  $(region_label "$LOC")"
  info "$(t '公网 IP' 'Public IP'): $ip"
  if in_cloud_shell; then
    warn "$(t '你在 Cloud Shell 里：私钥存在云端，关掉网页后在自己电脑上就登录不了。' 'You are in Cloud Shell: the private key lives in the cloud.')"
    info "$(t "  现在就下载私钥：点 Cloud Shell 工具栏的「管理文件」→「下载」，输入 $KEY" "  Download it now: Cloud Shell toolbar → Manage files → Download, path $KEY")"
    info "$(t '  下载后放到自己电脑的 ~/.ssh/ 里（Windows 是 C:\Users\你的用户名\.ssh\）。' '  Put it in ~/.ssh/ on your computer (Windows: C:\Users\<you>\.ssh\).')"
    info "$(t '  Mac/Linux 再运行 chmod 600 私钥文件，否则 ssh 会拒绝使用。' '  On Mac/Linux run chmod 600 on it, or ssh will refuse it.')"
  fi
  login_help "$ip" "$USER_NAME" "$KEY" "$VM"
  info ""
  info "$(t '省钱提醒：' 'Saving money:')"
  info "$(t '  · 在系统里执行关机，机器仍然计费；要在 Azure 里"停止（解除分配）"才停止计机器的钱。用本脚本 --manage 可以一键停止。' '  · Shutting down inside the OS still bills; deallocate in Azure (use --manage).')"
  info "$(t '  · 停止后硬盘和公网 IP 照样收费；彻底不用就删除整台机器（--manage → 删除）。' '  · Disk and IP still bill when stopped; delete the VM when done (--manage).')"
  info "$(t '  · 查本月花费：--cost' '  · Check monthly cost: --cost')"
}

flow_create() {
  choose_region
  show_quota
  choose_size
  choose_image
  choose_login
  choose_extras
  cost_summary
  create_vm
}

# ================= 管理已有机器 =================
flow_manage() {
  say "$(t '管理已有机器' 'Manage VMs')"
  local rows names=() rgs=() labels=() name rg loc size state ip i act
  rows=$(azs vm list -d --query "[].[name,resourceGroup,location,hardwareProfile.vmSize,powerState,publicIps]" -o tsv)
  [ -n "$rows" ] || { info "$(t '这个订阅里还没有机器。' 'No VMs in this subscription.')"; return; }
  while IFS=$'\t' read -r name rg loc size state ip; do
    names+=("$name"); rgs+=("$rg")
    labels+=("$(printf '%-16s %-20s %-14s %-20s %s' "$name" "$size" "$loc" "${state:-?}" "${ip:-}")")
  done <<<"$rows"
  if [ -n "$OPT_NAME" ]; then
    i=-1
    for n in "${!names[@]}"; do [ "${names[$n]}" = "$OPT_NAME" ] && i=$n; done
    [ "$i" -ge 0 ] || die "$(t "找不到机器：$OPT_NAME" "VM not found: $OPT_NAME")"
    info "$(t '机器' 'VM'): ${labels[$i]}"
  else
    i=$(( $(pick "$(t '选一台机器：' 'Pick a VM:')" 1 "${labels[@]}") - 1 ))
  fi
  VM=${names[$i]}; RG=${rgs[$i]}

  act=$(pick "$(t "对 $VM 做什么：" "What to do with $VM:")" 1 \
    "$(t '看登录命令' 'Show login command')" \
    "$(t '停止（解除分配）：停止计机器的钱，硬盘和 IP 照样收费' 'Stop (deallocate): stops VM charges; disk and IP still bill')" \
    "$(t '启动' 'Start')" \
    "$(t '设置或取消每天自动关机' 'Set or remove daily auto-shutdown')" \
    "$(t '换公网 IP：多建几个测延迟，留最快的' 'Change public IP: try a few, keep the fastest')" \
    "$(t '删除整台机器（连同硬盘、IP，彻底停止计费）' 'Delete the VM with disk and IP (stops all charges)')" \
    "$(t '返回' 'Back')")
  case $act in
    1) local u ip2
       u=$(azs vm show -g "$RG" -n "$VM" --query osProfile.adminUsername -o tsv)
       ip2=$(azs vm list-ip-addresses -g "$RG" -n "$VM" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
       login_help "${ip2:-<IP>}" "$u" "$HOME/.ssh/$VM" "$VM"
       info "$(t '（私钥路径是按默认值猜的，以你创建时填的为准）' '(Key path is the default guess; use the one you chose)')" ;;
    2) info "$(t '停止中……' 'Deallocating...')"; azs vm deallocate -g "$RG" -n "$VM" -o none && ok "$(t '已停止（解除分配）' 'Deallocated')" ;;
    3) info "$(t '启动中……' 'Starting...')"; azs vm start -g "$RG" -n "$VM" -o none && ok "$(t '已启动（公网 IP 不变）' 'Started (same public IP)')" ;;
    4) OPT_SHUTDOWN=""; choose_extras_shutdown_only ;;
    5) change_ip ;;
    6) delete_vm ;;
    *) ;;
  esac
}

choose_extras_shutdown_only() {
  local ports_backup=${OPT_PORTS:-}
  OPT_PORTS=none; choose_extras; OPT_PORTS=$ports_backup
  if [ -n "$SHUTDOWN_UTC" ]; then
    azs vm auto-shutdown -g "$RG" -n "$VM" --time "$SHUTDOWN_UTC" -o none && ok "$(t "已设置每天 $SHUTDOWN 自动关机" "Auto-shutdown set for $SHUTDOWN")"
  else
    azs vm auto-shutdown -g "$RG" -n "$VM" --off -o none 2>/dev/null; ok "$(t '已取消自动关机' 'Auto-shutdown removed')"
  fi
}

delete_vm() {
  local others typed
  say "$(t "删除 $VM" "Delete $VM")"
  others=$(azs vm list -g "$RG" --query "[?name!='$VM'].name" -o tsv)
  if [ -n "$others" ]; then
    warn "$(t "资源组 $RG 里还有别的机器（${others}），只删这一台。" "Resource group $RG has other VMs ($others); deleting only this one.")"
    info "$(t '将删除：机器本身，以及创建时设置了"随机器删除"的系统盘和网卡。公网 IP 和防火墙规则会留下，需要在控制台另删。' 'Deletes the VM plus disk/NIC marked delete-with-VM. Public IP and NSG stay.')"
  else
    info "$(t "将删除整个资源组 ${RG}，里面的东西如下：" "The whole resource group $RG will be deleted:")"
    azs resource list -g "$RG" --query "[].[type,name]" -o tsv | sed 's/^/    /' >&2
  fi
  warn "$(t '删除后无法恢复，机器里的数据会全部丢失。' 'This cannot be undone; all data on the VM is lost.')"
  typed=$(read_in "$(t "确认请输入机器名 $VM: " "Type the VM name $VM to confirm: ")")
  [ "$typed" = "$VM" ] || { info "$(t '名字不一致，已取消。' 'Name mismatch; cancelled.')"; return; }
  if [ -n "$others" ]; then
    azs vm delete -g "$RG" -n "$VM" --yes -o none && ok "$(t '已删除' 'Deleted')"
  else
    azs group delete -n "$RG" --yes --no-wait && ok "$(t '已开始删除，几分钟后完成。' 'Deletion started; it finishes in a few minutes.')"
  fi
}

# ================= 换公网 IP =================
# tcp_ms IP 端口：TCP 连 5 次取中间值（毫秒，整数），连不上输出空
tcp_ms() {
  local i s all=""
  for i in 1 2 3 4 5; do
    s=$(curl -s -o /dev/null --noproxy '*' --connect-timeout 3 --max-time 3 -w '%{time_connect}' "telnet://$1:$2" </dev/null 2>/dev/null)
    awk -v s="${s:-0}" 'BEGIN{exit !(s > 0)}' && all="$all $(awk -v s="$s" 'BEGIN{printf "%d", s * 1000 + 0.5}')"
  done
  # shellcheck disable=SC2086
  [ -n "$all" ] && printf '%s\n' $all | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

# wait_up IP 端口：等新 IP 生效，最多约 2 分钟
wait_up() {
  local i
  for i in $(seq 1 40); do
    [ -n "$(curl -s -o /dev/null --noproxy '*' --connect-timeout 2 --max-time 2 -w '%{time_connect}' "telnet://$1:$2" </dev/null 2>/dev/null | awk '$1>0')" ] && return 0
    sleep 1
  done
  return 1
}

# measure IP：自动测，或者（网络被代理接管时）让用户自己测了填进来
measure() {
  if [ -n "$IP_MANUAL" ]; then
    read_in "$(t "  现在挂的是 $1，用你自己的办法测延迟，输入毫秒数（回车 = 跳过）: " "  Now on $1. Measure it yourself and enter ms (Enter = skip): ")" | tr -cd '0-9'
  else
    wait_up "$1" "$IP_PORT" || { warn "$(t "  $1 两分钟内没连上" "  $1 not reachable within 2 minutes")"; return; }
    tcp_ms "$1" "$IP_PORT"
  fi
}

# 把机器的主网卡配置指向某个公网 IP（节点会断几秒到几十秒）
attach_ip() { az network nic ip-config update --ids "$IP_CFG_ID" --public-ip-address "$1" -o none; }

change_ip() {
  local nic_id cfg old_id old_ip zone loc used lim free n i k best err name made ms addr
  local ids=() names=() addrs=() mss=() labels=() del=()
  say "$(t "换公网 IP：$VM" "Change public IP: $VM")"
  info "$(t 'Azure 没有"换 IP"按钮，只能新建公网 IP 换上去，地址是机房地址池里随机分的。同一区域不同地址段的延迟可能差几十毫秒，所以多建几个轮流挂上去测，留最快的，其余删掉。' 'Azure has no "change IP" button: you create a new public IP and attach it; the address is random. Latency can differ by tens of ms, so this tries a few in turn, keeps the fastest and deletes the rest.')"

  nic_id=$(azs vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)
  read -r cfg old_id < <(az network nic show --ids "$nic_id" --query "ipConfigurations[?primary].[name,publicIPAddress.id]" -o tsv)
  [ -n "${old_id:-}" ] && [ "$old_id" != None ] || die "$(t '这台机器的主网卡上没有公网 IP。' 'The primary NIC has no public IP.')"
  IP_CFG_ID="$nic_id/ipConfigurations/$cfg"
  old_ip=$(az network public-ip show --ids "$old_id" --query ipAddress -o tsv)
  loc=$(azs vm show -g "$RG" -n "$VM" --query location -o tsv)
  zone=$(azs vm show -g "$RG" -n "$VM" --query "zones[0]" -o tsv)
  { read -r used; read -r lim; } < <(azs network list-usages -l "$loc" --query "[?name.value=='PublicIPAddresses'] | [0].[currentValue,limit]" -o tsv)
  free=$(( ${lim:-0} - ${used:-0} ))
  info "$(t '现在的公网 IP' 'Current public IP'): $old_ip  (${old_id##*/})"
  info "$(t "这个区域公网 IP 配额：已用 $used / 共 $lim" "Public IP quota in this region: $used of $lim used")"
  [ "$free" -ge 1 ] || die "$(t '配额满了，建不了新 IP。先在控制台删掉不用的公网 IP 再来。' 'Quota is full; delete unused public IPs in the portal first.')"

  # 测延迟的办法：从运行脚本的电脑连 22 端口。先确认网络没被代理/加速器接管：没开放的端口如果也"连得上"，数字就是假的
  IP_PORT=22; IP_MANUAL=""
  if [ -n "$(curl -s -o /dev/null --noproxy '*' --connect-timeout 3 --max-time 3 -w '%{time_connect}' "telnet://$old_ip:9" </dev/null 2>/dev/null | awk '$1>0')" ]; then
    warn "$(t '你的网络像是经过了代理或加速器（连没开放的端口也能"连上"），在这台电脑上自动测出的延迟不可信。' 'Your network seems to go through a proxy (even a closed port "connects"), so automatic results here would be fake.')"
    info "$(t '  改成手动：每换上一个 IP，脚本会停下来显示地址，你用自己的办法（比如关掉代理后 ping，或在别的机器上测）测完把毫秒数填进来。也可以关掉代理后重新运行，或者在 Cloud Shell 里运行（测的是 Azure 机房到机器的距离）。' '  Switching to manual: after each IP is attached the script pauses; measure it your own way and type the ms. Or rerun without the proxy, or in Cloud Shell.')"
    IP_MANUAL=1
  else
    ms=$(tcp_ms "$old_ip" 22)
    if [ -z "$ms" ]; then
      warn "$(t '从这台电脑连不上 22 端口（学校、公司网络常见）。' 'Cannot reach port 22 from here (common on school/office networks).')"
      IP_PORT=$(ask "$(t '换个已开放的端口来测' 'Another open port to test')" 443)
      ms=$(tcp_ms "$old_ip" "$IP_PORT")
      [ -n "$ms" ] || { warn "$(t "$IP_PORT 也连不上，改成手动填延迟。" "Port $IP_PORT is unreachable too; switching to manual input.")"; IP_MANUAL=1; }
    fi
    in_cloud_shell && info "$(t '（在 Cloud Shell 里，测的是 Azure 机房到机器的延迟，不等于你自己电脑上的体验）' '(In Cloud Shell this measures from an Azure datacenter, not from your computer)')"
  fi
  [ -n "$IP_MANUAL" ] && ms=$(measure "$old_ip")
  ids=("$old_id"); names=("${old_id##*/}"); addrs=("$old_ip"); mss=("${ms:-}")
  info "$(t '现在这个 IP 的延迟' 'Latency of the current IP'): ${ms:-?} ms"

  n=$(ask "$(t "试几个新 IP（1-${free}）" "How many new IPs to try (1-$free)")" "$free")
  [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$free" ] || n=$free
  made=$(date +%m%d%H%M)

  say "$(t '演练：将要执行的命令' 'Dry run: commands to execute')"
  for i in $(seq 1 "$n"); do
    info "  az network public-ip create --subscription \"$SUB_ID\" -g $RG -n $VM-ip-$made-$i -l $loc --sku Standard --allocation-method Static --version IPv4${zone:+ --zone $zone}"
    info "  az network nic ip-config update --ids $IP_CFG_ID --public-ip-address <$VM-ip-$made-$i>   # $(t '换上去测延迟' 'attach and measure')"
  done
  info "  $(t '然后换上你选的那个，再删掉没选中的（删之前会列出来让你确认）' 'then attach the one you pick and delete the rest (listed for confirmation first)')"
  warn "$(t "每换一次 IP，机器的网络会断几秒到几十秒，正在用的连接（ssh、代理）都会断。总共大约 $((n + 1)) 次。" "Each swap drops the VM's connections for seconds to tens of seconds, about $((n + 1)) times in total.")"
  info "$(t "新 IP 按小时收费（Standard 静态 IP 约每小时 0.005 美元），测完删掉就不再收。" "New IPs bill hourly (about \$0.005/hour each) until deleted.")"
  [ -n "$OPT_DRY" ] && { info "$(t '（--dry-run：只演练，什么都没改）' '(--dry-run: nothing changed)')"; exit 0; }
  [ -n "${NO_TTY:-}" ] && [ -z "$OPT_YES" ] && die "$(t '没有终端确认，要直接执行请加 --yes' 'No terminal to confirm; add --yes')"
  [ -n "$OPT_YES" ] || confirm "$(t '开始' 'Start')" || { info "$(t '已取消，什么都没改。' 'Cancelled; nothing changed.')"; return; }

  # 中途出错或按 Ctrl+C：换回原来的 IP，再问要不要删掉这次建的
  err=$(mktemp)
  trap 'IP_ABORT=1' INT
  IP_ABORT=""
  for i in $(seq 1 "$n"); do
    name="$VM-ip-$made-$i"
    info "$(t "[$i/$n] 新建 ${name}……" "[$i/$n] Creating $name...")"
    { read -r k; read -r addr; } < <(azs network public-ip create -g "$RG" -n "$name" -l "$loc" --sku Standard --allocation-method Static --version IPv4 ${zone:+--zone "$zone"} \
      --query "publicIp.[id,ipAddress]" -o tsv 2>"$err") || { explain_error "$err"; break; }
    ids+=("$k"); names+=("$name"); addrs+=("$addr"); mss+=("")
    [ -n "$IP_ABORT" ] && break
    info "$(t "  地址 ${addr}，换到机器上……" "  Address $addr, attaching...")"
    attach_ip "$k" 2>"$err" || { explain_error "$err"; break; }
    mss[${#mss[@]}-1]=$(measure "$addr")
    info "  $addr: ${mss[${#mss[@]}-1]:-?} ms"
    [ -n "$IP_ABORT" ] && break
  done
  trap - INT
  rm -f "$err"

  # 挑：默认延迟最低的
  best=1; k=""
  for i in "${!ids[@]}"; do
    labels+=("$(printf '%-16s %-30s %s' "${addrs[$i]}" "${names[$i]}" "${mss[$i]:-?} ms")$([ "$i" = 0 ] && t '  ← 原来的' '  ← original')")
    [ -n "${mss[$i]}" ] && { [ -z "$k" ] || [ "${mss[$i]}" -lt "$k" ]; } && { k=${mss[$i]}; best=$((i + 1)); }
  done
  if [ -n "$IP_ABORT" ]; then
    warn "$(t '已中断，换回原来的 IP。' 'Interrupted; restoring the original IP.')"; best=1
  else
    best=$(pick "$(t '留哪个（→ 是延迟最低的）：' 'Which one to keep (→ is the fastest):')" "$best" "${labels[@]}")
  fi
  i=$((best - 1))
  info "$(t "换上 ${addrs[$i]}……" "Attaching ${addrs[$i]}...")"
  attach_ip "${ids[$i]}" || die "$(t "换回失败。请在控制台把网卡 ${nic_id##*/} 的公网 IP 设成 ${names[$i]}。" "Attach failed. In the portal, set the public IP of NIC ${nic_id##*/} to ${names[$i]}.")"
  ok "$(t "公网 IP 现在是 ${addrs[$i]}（${names[$i]}）" "Public IP is now ${addrs[$i]} (${names[$i]})")"

  # 删：没选中的新 IP 一组确认，原来的 IP 单独确认（有人想留着当备用）
  for k in "${!ids[@]}"; do [ "$k" != 0 ] && [ "$k" != "$i" ] && del+=("$k"); done
  if [ ${#del[@]} -gt 0 ]; then
    info "$(t '没选中的新 IP（留着会按小时收费）：' 'Unpicked new IPs (they bill hourly):')"
    for k in "${del[@]}"; do info "    ${names[$k]}  ${addrs[$k]}"; done
    if confirm "$(t '删掉这些' 'Delete these')"; then
      for k in "${del[@]}"; do az network public-ip delete --ids "${ids[$k]}" && ok "$(t '已删除' 'Deleted') ${names[$k]}"; done
    else info "$(t '没删。以后在控制台「公网 IP 地址」里删。' 'Kept. Delete them later under Public IP addresses in the portal.')"; fi
  fi
  if [ "$i" != 0 ]; then
    info "$(t '原来的 IP' 'Original IP'): ${names[0]}  ${addrs[0]}"
    if confirm "$(t '删掉原来的 IP（删了这个地址就找不回来了）' 'Delete the original IP (the address cannot be recovered)')"; then
      az network public-ip delete --ids "${ids[0]}" && ok "$(t '已删除' 'Deleted') ${names[0]}"
    else info "$(t '原来的 IP 留着，没挂在机器上也照样按小时收费。' 'Original IP kept; it still bills hourly while unattached.')"; fi
    info ""
    warn "$(t '地址变了，别忘了改用到旧地址的地方：' 'The address changed; update everything that used the old one:')"
    info "$(t "  · 域名的 A 记录：${addrs[0]} → ${addrs[$i]}" "  · DNS A record: ${addrs[0]} → ${addrs[$i]}")"
    info "$(t '  · ~/.ssh/config 里的 HostName；写 IP 的代理客户端链接' '  · HostName in ~/.ssh/config; proxy client links that use the IP')"
  fi
}

# ================= 查花费 =================
flow_cost() {
  say "$(t '本月花费' 'Cost this month')"
  local body res
  body='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"c":{"name":"Cost","function":"Sum"}}}}'
  res=$(az rest --method post --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.CostManagement/query?api-version=2023-03-01" \
    --body "$body" --query "properties.rows[0]" -o tsv 2>/dev/null)
  if [ -n "$res" ]; then
    info "$(t '本月到目前为止' 'Month to date'): $(awk '{printf "%.2f %s", $1, $2}' <<<"$res")"
  else
    info "$(t '本月到目前为止：0（或者还没有数据）' 'Month to date: 0 (or no data yet)')"
  fi
  info "$(t '费用数据通常有 8 到 24 小时延迟。' 'Cost data usually lags 8-24 hours.')"
  [ -n "${SUB_IS_STUDENT:-}" ] && info "$(t '学生额度还剩多少（命令行查不到，要在网页上看）：' 'Remaining student credit (web only):') $BALANCE_URL"
}

# ================= 主流程 =================
check_env
info "${B}$(t "Azure 开机向导 v$VERSION" "Azure VM wizard v$VERSION")$N  $(t '每一步直接回车即选推荐项（→）。' 'Press Enter to accept the recommended choice (→).')"
in_cloud_shell && info "$(t '检测到 Cloud Shell。' 'Running in Cloud Shell.')"
choose_subscription
ensure_compute
if [ -z "$OPT_MODE" ]; then
  case $(pick "$(t '要做什么：' 'What do you want to do:')" 1 "$(t '开一台新机器' 'Create a VM')" "$(t '管理已有机器（登录、停止、启动、换 IP、删除）' 'Manage VMs (login, stop, start, change IP, delete)')" "$(t '查本月花费和剩余额度' 'Check cost and credit')") in
    1) OPT_MODE=create ;; 2) OPT_MODE=manage ;; 3) OPT_MODE=cost ;;
  esac
fi
case $OPT_MODE in
  create) flow_create ;;
  manage) flow_manage ;;
  cost) flow_cost ;;
esac
