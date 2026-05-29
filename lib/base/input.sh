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
  ${command_name} upgrade
  ${command_name} change-uuid [参数]
  ${command_name} change-sni [参数]
  ${command_name} change-path [参数]
  ${command_name} change-label-prefix [参数]
  ${command_name} change-warp [参数]
  ${command_name} change-warp-rules [参数]
  ${command_name} change-cert-mode [参数]
  ${command_name} renew-cert [参数]
  ${command_name} uninstall [--yes] [--purge]
  ${command_name} purge [--yes]
  ${command_name} show-links [--client NAME] [--qr]
  ${command_name} add-client NAME [参数]
  ${command_name} list-clients
  ${command_name} diagnose
  ${command_name} status [--raw]
  ${command_name} restart
  ${command_name} repair-perms
  ${command_name} help

安装参数:
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
  --cert-mode VALUE           证书模式：self-signed、existing、cf-origin-ca、acme-dns-cf。
  --cert-file VALUE           existing / cf-origin-ca 模式使用的证书文件。
  --key-file VALUE            existing / cf-origin-ca 模式使用的私钥文件。
  --cert-pem VALUE            existing / cf-origin-ca 模式下仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing / cf-origin-ca 模式下仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --acme-email VALUE          acme.sh 注册邮箱。
  --acme-ca VALUE             acme.sh 使用的 CA，默认 letsencrypt。
  --cf-dns-token VALUE        acme dns_cf 模式仅支持 @文件路径或环境变量 CF_DNS_TOKEN。
  --cf-dns-account-id VALUE   acme dns_cf 模式使用的 Cloudflare Account ID，可选。
  --cf-dns-zone-id VALUE      acme dns_cf 模式使用的 Cloudflare Zone ID，可选。
  --enable-warp               启用选择性 WARP 出站。
  --disable-warp              禁用 WARP 出站。
  --enable-net-opt            启用 Joey BBRv3 内核 + fq/RPS 网络优化。
  --disable-net-opt           禁用网络优化。
  --warp-team VALUE           Cloudflare Zero Trust 团队名。
  --warp-client-id VALUE      服务令牌 Client ID。
  --warp-client-secret VALUE  服务令牌 Client Secret；仅支持 @文件路径或环境变量 WARP_CLIENT_SECRET。
  --warp-proxy-port VALUE     WARP 本地 SOCKS5 端口，默认 40000。

变更 UUID 参数:
  --reality-uuid VALUE        指定新的 REALITY UUID，而不是自动生成。
  --xhttp-uuid VALUE          指定新的 XHTTP UUID，而不是自动生成。
  --reality-only              只轮换 REALITY UUID。
  --xhttp-only                只轮换 XHTTP UUID。

客户端参数:
  add-client NAME             添加一个命名客户端，并为它生成独立的 REALITY / XHTTP UUID。
  --client NAME               show-links 使用指定客户端重新生成输出与订阅文件。
  --client-name VALUE         add-client 使用的客户端名称。
  --reality-uuid VALUE        为新客户端指定 REALITY UUID；省略时自动生成。
  --xhttp-uuid VALUE          为新客户端指定 XHTTP UUID；省略时自动生成。
  list-clients                输出当前可用客户端名称。

变更 SNI 参数:
  --non-interactive           非交互运行。
  --reality-sni VALUE         新的 REALITY 可见 SNI。

变更路径参数:
  --non-interactive           非交互运行。
  --xhttp-path VALUE          新的 XHTTP 路径。

变更节点名前缀参数:
  --non-interactive           非交互运行。
  --node-label-prefix VALUE   新的导出节点名前缀。

变更 WARP 参数:
  --non-interactive           非交互运行。
  --enable-warp               启用 WARP 分流。
  --disable-warp              禁用 WARP 分流。
  --warp-team VALUE           Cloudflare Zero Trust 团队名。
  --warp-client-id VALUE      服务令牌 Client ID。
  --warp-client-secret VALUE  服务令牌 Client Secret；仅支持 @文件路径或环境变量 WARP_CLIENT_SECRET。
  --warp-proxy-port VALUE     WARP 本地 SOCKS5 端口。

变更 WARP 分流规则参数:
  --non-interactive           非交互运行。
  --add-domain VALUE          新增一个域名规则；裸域名会自动转成 domain: 前缀。
  --del-domain VALUE          删除一个域名规则；支持裸域名或 domain:/geosite: 形式。
  --reset-defaults            恢复脚本默认的 WARP 分流规则集合。
  --list                      只打印当前生效的 WARP 分流规则，不做修改。

变更证书模式参数:
  --non-interactive           非交互运行。
  --cert-mode VALUE           新证书模式：self-signed、existing、cf-origin-ca、acme-dns-cf。
                              该变更作用于当前 VPS 上共享 XHTTP 域名的全部客户端链接。
  --xhttp-domain VALUE        新的 XHTTP CDN 域名，可选。
  --cert-file VALUE           existing / cf-origin-ca 模式使用的证书文件。
  --key-file VALUE            existing / cf-origin-ca 模式使用的私钥文件。
  --cert-pem VALUE            existing / cf-origin-ca 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing / cf-origin-ca 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --acme-email VALUE          acme.sh 注册邮箱。
  --acme-ca VALUE             acme.sh 使用的 CA。
  --cf-dns-token VALUE        acme dns_cf 模式仅支持 @文件路径或环境变量 CF_DNS_TOKEN。
  --cf-dns-account-id VALUE   acme dns_cf 模式使用的 Cloudflare Account ID，可选。
  --cf-dns-zone-id VALUE      acme dns_cf 模式使用的 Cloudflare Zone ID，可选。

续期证书参数:
  --non-interactive           非交互运行。
  --cert-file VALUE           existing / cf-origin-ca 模式使用的证书文件。
  --key-file VALUE            existing / cf-origin-ca 模式使用的私钥文件。
  --cert-pem VALUE            existing / cf-origin-ca 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
  --key-pem VALUE             existing / cf-origin-ca 模式仅支持 @文件路径；交互模式可直接粘贴 PEM。
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
  diagnose                    一次性输出服务、端口、配置、TLS 与最近自恢复信息。

脚本维护命令:
  update-script               下载并更新脚本自身的持久化 bundle 与管理命令。

链接参数:
  --client NAME               选择要输出的客户端；不传时默认保持原有输出，多客户端交互终端会提示选择。
  --qr                        额外输出分享链接二维码；需要系统已安装 qrencode。

示例:
  ${command_name}
  ${command_name} update-script
  ${command_name} upgrade
  ${command_name} repair-perms
  ${command_name} diagnose
  ${command_name} change-uuid
  ${command_name} change-sni --reality-sni www.stanford.edu
  ${command_name} change-path --xhttp-path /assets/v3
  ${command_name} change-label-prefix --node-label-prefix HKG
  ${command_name} change-warp --disable-warp
  ${command_name} change-warp-rules --add-domain chat.openai.com
  ${command_name} change-cert-mode --cert-mode self-signed
  ${command_name} change-cert-mode --cert-mode cf-origin-ca
  ${command_name} renew-cert
  ${command_name} add-client phone
  ${command_name} show-links --client phone
  ${command_name} uninstall --yes
  ${command_name} uninstall --purge --yes
  ${command_name} install --non-interactive \
    --server-ip 203.0.113.10 \
    --xhttp-domain cdn.example.com \
    --cert-mode self-signed \
    --enable-net-opt \
    --enable-warp \
    --warp-team your-team \
    --warp-client-id xxxxxxxxx.access \
    --warp-client-secret @/root/warp-client-secret.txt
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
    --warp-client-secret) printf 'WARP_CLIENT_SECRET' ;;
    --cf-api-token) printf 'CF_API_TOKEN' ;;
    --cf-dns-token) printf 'CF_DNS_TOKEN' ;;
    --reality-private-key) printf 'REALITY_PRIVATE_KEY' ;;
    *) return 1 ;;
  esac
}

option_requires_indirect_value() {
  case "${1}" in
    --warp-client-secret|--cf-api-token|--cf-dns-token|--reality-private-key|--cert-pem|--key-pem)
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
    if [[ "${line}" == "EOF" ]]; then
      break
    fi
    current_value+="${line}"$'\n'
  done

  current_value="${current_value%$'\n'}"
  [[ -n "${current_value}" ]] || die "${var_name} 内容不能为空。"
  printf -v "${var_name}" '%s' "${current_value}"
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
