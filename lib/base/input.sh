# shellcheck shell=bash

# ------------------------------
# 输入与交互层
# 负责交互式输入、多行输入与帮助文本
# ------------------------------

usage() {
  local command_name=""

  command_name="${XTUN_COMMAND_NAME:-$(basename "${0}")}"
  printf 'xtun.sh v%s\n' "${SCRIPT_VERSION}"
  cat <<EOF

用法:
  ${command_name}
  ${command_name} install [参数]
  ${command_name} update-script
  ${command_name} upgrade [--xray-version vX.Y.Z]
  ${command_name} check-sni [域名] [--target host:port] [--timeout N]
  ${command_name} change-uuid [参数]
  ${command_name} change-sni [参数]
  ${command_name} change-path [参数]
  ${command_name} change-warp [参数]
  ${command_name} change-warp-rules [参数]
  ${command_name} change-cert-mode [参数]
  ${command_name} renew-cert [参数]
  ${command_name} uninstall [--yes] [--purge]
  ${command_name} show-links [--qr]
  ${command_name} diagnose
  ${command_name} status [--raw]
  ${command_name} restart
  ${command_name} repair-perms
  ${command_name} apply-net-opt [--bbr-kernel joey|none]
  ${command_name} apply-config [--manage-nginx-main]
  ${command_name} version
  ${command_name} help

安装参数:
  --xray-version VALUE        显式指定 Xray-core tag；默认追踪最新官方已发布版本（包含 pre-release）。
  --non-interactive           非交互运行；缺少必要参数时直接失败。
  --server-ip VALUE           REALITY 直连节点的公网 IP 或域名。
  --node-label-prefix VALUE   导出节点名称前缀，例如 HKG 或 SJC。
  --reality-uuid VALUE        指定 REALITY 节点 UUID。
  --reality-sni VALUE         REALITY 可见 SNI，同时用于 HAProxy 分流。
  --reality-short-id VALUE    REALITY 短 ID。
  --reality-private-key VALUE 复用现有 REALITY 私钥；仅支持 @文件路径或环境变量 REALITY_PRIVATE_KEY。
  --xhttp-uuid VALUE          指定 XHTTP CDN 节点 UUID。
  --xhttp-domain VALUE        XHTTP CDN 使用的橙云域名。
  --xhttp-path VALUE          XHTTP 路径，例如 /cfup-example。
  --enable-xhttp-vless-encryption   启用 XHTTP CDN 的 VLESS Encryption。
  --disable-xhttp-vless-encryption  禁用 XHTTP CDN 的 VLESS Encryption。
  --enable-xhttp-ech         启用 XHTTP CDN ECH（默认关闭）。
  --disable-xhttp-ech        禁用 XHTTP CDN ECH。
  --xhttp-ech-config-list VALUE      ECH 配置列表，默认启用值为 cloudflare-ech.com+https://223.5.5.5/dns-query。
  --xhttp-ech-force-query VALUE      ECH 强制查询模式，默认 none。
  --enable-xhttp-xpadding    启用 XHTTP xpadding（默认关闭）。
  --disable-xhttp-xpadding   禁用 XHTTP xpadding。
  --xhttp-xpadding-key VALUE        xpadding 参数名，默认 x_padding。
  --xhttp-xpadding-header VALUE     xpadding Header 名，默认 Referer。
  --xhttp-xpadding-placement VALUE  xpadding placement，默认 queryInHeader。
  --xhttp-xpadding-method VALUE     xpadding method，默认 tokenish。
  --cert-mode VALUE           证书模式：self-signed、existing、acme-dns-cf。
                              existing 同时接受现有证书文件和 Cloudflare Origin CA 证书。
  --cert-file VALUE           existing 模式使用的证书文件。
  --key-file VALUE            existing 模式使用的私钥文件。
  --cert-pem VALUE            existing 模式下仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing 模式下仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --acme-email VALUE          acme.sh 注册邮箱。
  --acme-ca VALUE             acme.sh 使用的 CA，默认 letsencrypt。
  --cf-dns-token VALUE        acme dns_cf 模式仅支持 @文件路径或环境变量 CF_DNS_TOKEN。
  --cf-dns-account-id VALUE   acme dns_cf 模式使用的 Cloudflare Account ID，可选。
  --cf-dns-zone-id VALUE      acme dns_cf 模式使用的 Cloudflare Zone ID，可选。
  --enable-warp               启用选择性 WARP 出站。
  --disable-warp              禁用 WARP 出站。
  --enable-net-opt            启用 Joey BBRv3 内核 + fq/RPS 网络优化。
  --disable-net-opt           禁用网络优化。
  --bbr-kernel joey|none      是否安装 Joey BBRv3 第三方内核（默认 joey）；none 只做 sysctl/helper。
  --manage-nginx-main         接管 /etc/nginx/nginx.conf（worker_connections / fd 限额）。
  --no-manage-nginx-main      不接管 nginx 主配置。
  --skip-sni-check            跳过 Reality 目标域名预检。
  --block-cn                  拦截回国流量（geoip:cn / geosite:cn）。
  --no-block-cn               不拦截回国流量（默认）。
  --warp-private-key VALUE    WARP WireGuard 私钥；仅支持 @文件路径或环境变量 WARP_PRIVATE_KEY。
  --warp-profile VALUE        导入 wgcf profile.conf；仅支持 @文件路径或环境变量 WARP_PROFILE。
  --warp-address-v4 VALUE     WARP WireGuard IPv4 内网地址。
  --warp-address-v6 VALUE     WARP WireGuard IPv6 内网地址。
  --warp-peer-public-key VALUE WARP 对端公钥，默认使用 Cloudflare 公开值。
  --warp-endpoint VALUE       WARP Endpoint host:port，默认 engage.cloudflareclient.com:2408。
  --warp-reserved VALUE       WARP reserved 三字节，逗号分隔，例如 1,2,3。
  --warp-mtu VALUE            WARP WireGuard MTU，默认 1420。
                              全部省略时会自动注册一台免费 WARP 设备。

变更 UUID 参数:
  --reality-uuid VALUE        指定新的 REALITY UUID，而不是自动生成。
  --xhttp-uuid VALUE          指定新的 XHTTP UUID，而不是自动生成。
  --reality-only              只轮换 REALITY UUID。
  --xhttp-only                只轮换 XHTTP UUID。

check-sni 参数:
  --target VALUE              覆盖探测目标 host:port（默认 SNI:443）。
  --timeout VALUE             每次探测超时秒数，默认 10。
  --server-ip VALUE           本机公网 IP，用于回环判定；默认自动读取。

变更 SNI 参数:
  --non-interactive           非交互运行。
  --reality-sni VALUE         新的 REALITY 可见 SNI。
  --skip-sni-check            跳过 Reality 目标域名预检。

变更路径参数:
  --non-interactive           非交互运行。
  --xhttp-path VALUE          新的 XHTTP 路径。

变更 WARP 参数:
  --non-interactive           非交互运行。
  --enable-warp               启用 WARP 分流。
  --disable-warp              禁用 WARP 分流。
  --warp-private-key VALUE    WARP WireGuard 私钥；仅支持 @文件路径或环境变量 WARP_PRIVATE_KEY。
  --warp-profile VALUE        导入 wgcf profile.conf；仅支持 @文件路径或环境变量 WARP_PROFILE。
  --warp-address-v4 VALUE     WARP WireGuard IPv4 内网地址。
  --warp-address-v6 VALUE     WARP WireGuard IPv6 内网地址。
  --warp-peer-public-key VALUE WARP 对端公钥。
  --warp-endpoint VALUE       WARP Endpoint host:port。
  --warp-reserved VALUE       WARP reserved 三字节，逗号分隔。
  --warp-mtu VALUE            WARP WireGuard MTU。
                              全部省略时会自动注册一台免费 WARP 设备。

变更 WARP 分流规则参数:
  --non-interactive           非交互运行。
  --add-domain VALUE          新增一个域名规则；裸域名会自动转成 domain: 前缀。
  --del-domain VALUE          删除一个域名规则；支持裸域名或 domain:/geosite: 形式。
  --reset-defaults            恢复脚本默认的 WARP 分流规则集合。
  --list                      只打印当前生效的 WARP 分流规则，不做修改。

变更证书模式参数:
  --non-interactive           非交互运行。
  --cert-mode VALUE           新证书模式：self-signed、existing、acme-dns-cf。
  --xhttp-domain VALUE        新的 XHTTP CDN 域名，可选。
  --cert-file VALUE           existing 模式使用的证书文件。
  --key-file VALUE            existing 模式使用的私钥文件。
  --cert-pem VALUE            existing 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --acme-email VALUE          acme.sh 注册邮箱。
  --acme-ca VALUE             acme.sh 使用的 CA。
  --cf-dns-token VALUE        acme dns_cf 模式仅支持 @文件路径或环境变量 CF_DNS_TOKEN。
  --cf-dns-account-id VALUE   acme dns_cf 模式使用的 Cloudflare Account ID，可选。
  --cf-dns-zone-id VALUE      acme dns_cf 模式使用的 Cloudflare Zone ID，可选。

续期证书参数:
  --non-interactive           非交互运行。
  --cert-file VALUE           existing 模式使用的证书文件。
  --key-file VALUE            existing 模式使用的私钥文件。
  --cert-pem VALUE            existing 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --acme-email VALUE          acme.sh 注册邮箱。
  --acme-ca VALUE             acme.sh 使用的 CA。
  --cf-dns-token VALUE        acme dns_cf 模式仅支持 @文件路径或环境变量 CF_DNS_TOKEN。
  --cf-dns-account-id VALUE   acme dns_cf 模式使用的 Cloudflare Account ID，可选。
  --cf-dns-zone-id VALUE      acme dns_cf 模式使用的 Cloudflare Zone ID，可选。

卸载参数:
  --yes                       跳过确认提示。
  --purge                     同时卸载脚本安装的软件包。

状态参数:
  --raw                       显示原始 systemctl 输出，而不是面板。

诊断命令:
  diagnose                    一次性输出服务、端口、配置与 TLS 信息。

脚本维护命令:
  update-script               下载并更新脚本自身的持久化 bundle 与管理命令。
  apply-net-opt               重新应用网络优化；--bbr-kernel joey|none 可切换内核策略并写回状态。
  apply-config                按当前状态重新生成托管配置；--manage-nginx-main 可开启 nginx 主配置接管。

链接参数:
  --qr                        额外输出每条分享链接的终端二维码（qrencode 由安装器安装）。

示例:
  ${command_name}
  ${command_name} update-script
  ${command_name} upgrade
  ${command_name} repair-perms
  ${command_name} apply-net-opt
  ${command_name} apply-config
  ${command_name} diagnose
  ${command_name} change-uuid
  ${command_name} check-sni www.stanford.edu
  ${command_name} change-sni --reality-sni www.stanford.edu
  ${command_name} change-path --xhttp-path /assets/v3
  ${command_name} change-warp --disable-warp
  ${command_name} change-warp-rules --add-domain chat.openai.com
  ${command_name} change-cert-mode --cert-mode self-signed
  ${command_name} renew-cert
  ${command_name} uninstall --yes
  ${command_name} uninstall --purge --yes
  ${command_name} install --non-interactive \
    --server-ip 203.0.113.10 \
    --xhttp-domain cdn.example.com \
    --cert-mode self-signed \
    --enable-net-opt \
    --enable-warp
EOF
}

prompt_with_default() {
  local var_name="${1}"
  local prompt_text="${2}"
  local default_value="${3}"
  local current_value=""
  local effective_default=""
  local answer=""

  current_value="${!var_name:-}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${current_value}" ]]; then
      return
    fi
    if [[ -n "${default_value}" ]]; then
      printf -v "${var_name}" '%s' "${default_value}"
      return
    fi
    die "缺少必填参数：${var_name}。"
  fi

  effective_default="${current_value:-${default_value}}"
  if [[ -n "${effective_default}" ]]; then
    read -r -p "${prompt_text} [${effective_default}]: " answer
    answer="${answer:-${effective_default}}"
  else
    read -r -p "${prompt_text}: " answer
  fi

  printf -v "${var_name}" '%s' "${answer}"
}

option_secret_env_name() {
  case "${1}" in
    --warp-private-key) printf 'WARP_PRIVATE_KEY' ;;
    --warp-profile) printf 'WARP_PROFILE' ;;
    --cf-dns-token) printf 'CF_DNS_TOKEN' ;;
    --reality-private-key) printf 'REALITY_PRIVATE_KEY' ;;
    *) return 1 ;;
  esac
}

option_requires_indirect_value() {
  case "${1}" in
    --warp-private-key|--warp-profile|--cf-dns-token|--reality-private-key|--cert-pem|--key-pem)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

enforce_indirect_option_value() {
  local option_name="${1}"
  local raw_value="${2-}"
  local env_name=""

  option_requires_indirect_value "${option_name}" || return 0
  [[ "${raw_value}" == @* ]] && return 0

  if env_name="$(option_secret_env_name "${option_name}" 2>/dev/null)"; then
    die "参数 ${option_name} 不支持直接明文传值；请改用 @文件路径，或环境变量 ${env_name}。"
  fi

  die "参数 ${option_name} 不支持直接明文传值；请改用 @文件路径，或改用对应文件参数。"
}

resolve_value_source() {
  local var_name="${1}"
  local env_name="${2:-${var_name}}"
  local current_value=""
  local file_path=""

  current_value="${!var_name:-}"
  if [[ -z "${current_value}" && -n "${!env_name:-}" ]]; then
    printf -v "${var_name}" '%s' "${!env_name}"
    current_value="${!var_name}"
  fi

  if [[ "${current_value}" == @* ]]; then
    file_path="${current_value#@}"
    [[ -f "${file_path}" ]] || die "${var_name} 指向的文件不存在：${file_path}"
    printf -v "${var_name}" '%s' "$(<"${file_path}")"
  fi

  sanitize_indirect_value "${var_name}"
}

# 这里进来的全是从文件或环境变量里拿的密钥类值，而这两个来源都会带上看不见的字节：
#   - `$(<file)` 只剪掉结尾的换行，\r 一个不动。令牌文件是在 Windows 上存的、
#     或者从网页复制粘贴过一手，内容就是 `token\r`。
#   - 环境变量同理，CI 的 secret 往回喂一层命令替换也只剪 \n。
# 后果按消费者不同，从「明显」到「查不出来」：WARP 私钥的 44 位 base64 正则会当场
# 拒掉（操作员盯着一个数出来正好 44 位的密钥发懵）；而 Cloudflare 令牌带 \r 时
# curl 会把这个裸 CR 原样塞进 Authorization 头发出去（实测 curl 8.14 不拦），
# Cloudflare 回 401，装到后面 acme.sh 签发那一步才炸。
# warp_profile_value 早就在自己那头 `tr -d '\r'` 了——说明这个坑踩过一次，
# 只是当时补在了消费者上，源头没补，于是别的消费者一个没落下都还在踩。
# 补在源头：所有 \r 一律删掉（PEM 的 CRLF 变 LF 反而是规范形态），
# 首尾空白整体剪掉（令牌、密钥、Endpoint、PEM 都不可能以空白开头或结尾）。
# 内部换行不动——PEM 和 wgcf profile 靠它。
sanitize_indirect_value() {
  local var_name="${1}"
  local value=""

  value="${!var_name:-}"
  [[ -n "${value}" ]] || return 0

  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret() {
  local var_name="${1}"
  local prompt_text="${2}"
  local current_value=""
  local answer=""

  resolve_value_source "${var_name}"
  current_value="${!var_name:-}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${current_value}" ]]; then
      return
    fi
    die "缺少必填密钥参数：${var_name}。"
  fi

  if [[ -n "${current_value}" ]]; then
    read -r -s -p "${prompt_text} [已填写，直接回车沿用]: " answer
    answer="${answer:-${current_value}}"
  else
    read -r -s -p "${prompt_text}: " answer
  fi
  printf '\n'
  printf -v "${var_name}" '%s' "${answer}"
  # 手工粘贴的令牌很容易带上一个尾随空格，和 @文件路径 那条路是同一个坑。
  sanitize_indirect_value "${var_name}"
}

prompt_multiline_value() {
  local var_name="${1}"
  local prompt_text="${2}"
  local current_value=""
  local line=""
  local answer="keep"

  current_value="${!var_name:-}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${current_value}" ]]; then
      return
    fi
    die "缺少必填多行内容：${var_name}。"
  fi

  if [[ -n "${current_value}" ]]; then
    read -r -p "${prompt_text} [已填写，回车沿用，输入 edit 重新粘贴]: " answer
    if [[ -z "${answer}" ]]; then
      return
    fi
  fi

  printf '%s\n' "${prompt_text}"
  printf '%s\n' "请直接粘贴内容，结束后单独输入一行 EOF。"

  current_value=""
  while IFS= read -r line; do
    # 真正的 tty 会把 CR 映射成 NL（ICRNL 默认开着），所以交互粘贴看不到 \r；
    # 但 stdin 是管道或文件时不映射。那时 CRLF 输入的结束行是 `EOF\r`，
    # 和 "EOF" 比不相等，循环就永远等不到结束标记，一路读到 stdin 关闭，
    # 于是这段内容里凭空多一行字面的 EOF——粘进来的 PEM 当场作废。
    line="${line//$'\r'/}"
    if [[ "${line}" == "EOF" ]]; then
      break
    fi
    current_value+="${line}"$'\n'
  done

  current_value="${current_value%$'\n'}"
  [[ -n "${current_value}" ]] || die "${var_name} 内容不能为空。"
  printf -v "${var_name}" '%s' "${current_value}"
  sanitize_indirect_value "${var_name}"
}

prompt_yes_no() {
  local var_name="${1}"
  local prompt_text="${2}"
  local default_value="${3}"
  local current_value=""
  local effective_default=""
  local answer=""

  current_value="${!var_name:-}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${current_value}" ]]; then
      return
    fi
    printf -v "${var_name}" '%s' "${default_value}"
    return
  fi

  effective_default="${current_value:-${default_value}}"
  read -r -p "${prompt_text} [${effective_default}]: " answer
  answer="${answer:-${effective_default}}"
  printf -v "${var_name}" '%s' "${answer}"
}
