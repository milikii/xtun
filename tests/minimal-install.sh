#!/usr/bin/env bash
# 调用者先用 debootstrap --variant=minbase 建立专用 Debian rootfs。
# 不删除 VPS 宿主工具，不改宿主的账户或 SSH 配置。
set -Eeuo pipefail

[[ "${XTUN_TEST_ISOLATED_VPS:-no}" == yes && "${EUID}" -eq 0 ]] || exit 2
TEST_ROOTFS="$(readlink -f "${1:?传入 /var/tmp/xtun-* 下的专用 minbase rootfs}")"
[[ "${TEST_ROOTFS}" == /var/tmp/xtun-* && -f "${TEST_ROOTFS}/etc/debian_version" ]] || exit 2
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_EVIDENCE="$(mktemp -d /var/tmp/xtun-minimal-evidence.XXXXXX)"
TEST_HIDDEN_TOOL=""
TEST_PROC_MOUNTED=no

minimal_cleanup() {
  if [[ -n "${TEST_HIDDEN_TOOL}" && -f "${TEST_ROOTFS}/var/tmp/hidden-tool" ]]; then
    mv "${TEST_ROOTFS}/var/tmp/hidden-tool" "${TEST_ROOTFS}${TEST_HIDDEN_TOOL}"
  fi
  [[ "${TEST_PROC_MOUNTED}" != yes ]] || umount "${TEST_ROOTFS}/proc"
}
trap minimal_cleanup EXIT

minimal_targets() {
  local path=""
  local file=""

  for path in usr/local/lib/xtun usr/local/sbin/xtun usr/local/bin/xray usr/local/share/xray \
    usr/local/etc/xray etc/ssl/xtun etc/haproxy/haproxy.cfg etc/nginx/conf.d/xtun.conf \
    etc/systemd/system/xray.service var/log/xtun root/xtun-backups root/.xtun-install-draft.env \
    root/xtun-output.md root/xtun-qr run/xtun.lock var/lib/xtun; do
    if [[ -e "${TEST_ROOTFS}/${path}" ]]; then
      stat -c '%n %a %u %g' "${TEST_ROOTFS}/${path}"
      while IFS= read -r -d '' file; do
        sha256sum "${file}"
        stat -c '%n %a %u %g' "${file}"
      done < <(find "${TEST_ROOTFS}/${path}" -type f -print0 | sort -z)
    fi
  done
}

minimal_cli() {
  chroot "${TEST_ROOTFS}" /bin/bash /src/xtun/xtun.sh install --task fresh \
    --server-ip 198.51.100.10 --reality-sni reality.example.test --xhttp-domain minimal.example.test --cert-mode existing \
    --cert-file /inputs/cert.pem --key-file /inputs/wrong-key.pem --skip-sni-check "$@"
}

minimal_cancel() {
  local label="${1}"
  local status=0

  minimal_targets > "${TEST_EVIDENCE}/${label}-before.txt"
  chroot "${TEST_ROOTFS}" dpkg-query -W > "${TEST_EVIDENCE}/${label}-packages-before.txt"
  printf '\n\n\n\nn\n' | minimal_cli > "${TEST_EVIDENCE}/${label}.log" 2>&1 || status=$?
  [[ "${status}" -eq 1 ]]
  grep -q '安装摘要' "${TEST_EVIDENCE}/${label}.log"
  grep -q '已取消本次安装' "${TEST_EVIDENCE}/${label}.log"
  grep -q '依赖准备后复检' "${TEST_EVIDENCE}/${label}.log"
  minimal_targets > "${TEST_EVIDENCE}/${label}-after.txt"
  chroot "${TEST_ROOTFS}" dpkg-query -W > "${TEST_EVIDENCE}/${label}-packages-after.txt"
  cmp "${TEST_EVIDENCE}/${label}-before.txt" "${TEST_EVIDENCE}/${label}-after.txt"
  cmp "${TEST_EVIDENCE}/${label}-packages-before.txt" "${TEST_EVIDENCE}/${label}-packages-after.txt"
  printf '%s\t0\n' "${label}" | tee -a "${TEST_EVIDENCE}/results.tsv"
}

for tool in openssl ip ss qrencode; do
  if chroot "${TEST_ROOTFS}" /bin/bash -c 'command -v "$1"' _ "${tool}" >/dev/null; then
    printf 'rootfs 必须起于缺少 openssl/iproute2/qrencode 的 minbase：%s 已存在。\n' "${tool}" >&2
    exit 2
  fi
done
mkdir -p "${TEST_ROOTFS}/src/xtun" "${TEST_ROOTFS}/inputs" "${TEST_ROOTFS}/usr/local/etc/xray"
cp -a "${ROOT_DIR}/xtun.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/static" "${TEST_ROOTFS}/src/xtun/"
printf '#!/bin/sh\nexit 101\n' > "${TEST_ROOTFS}/usr/sbin/policy-rc.d"
chmod 0755 "${TEST_ROOTFS}/usr/sbin/policy-rc.d"
mount -t proc proc "${TEST_ROOTFS}/proc"
TEST_PROC_MOUNTED=yes
# 仅在 chroot 放一个已有配置，避免宿主 443 监听遮住证书深预检。
printf 'original-fixture\n' > "${TEST_ROOTFS}/usr/local/etc/xray/config.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=minimal.example.test \
  -keyout "${TEST_ROOTFS}/inputs/right-key.pem" -out "${TEST_ROOTFS}/inputs/cert.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${TEST_ROOTFS}/inputs/wrong-key.pem" >/dev/null 2>&1

minimal_cancel all-missing-cancel

status=0
DEBIAN_FRONTEND=noninteractive minimal_cli --non-interactive > "${TEST_EVIDENCE}/confirmed-dependencies.log" 2>&1 || status=$?
[[ "${status}" -eq 1 ]]
grep -q '证书与私钥不匹配' "${TEST_EVIDENCE}/confirmed-dependencies.log"
grep -q '本次新增或更新的软件包已保留' "${TEST_EVIDENCE}/confirmed-dependencies.log"
grep -q '安装停在：依赖准备后的深预检' "${TEST_EVIDENCE}/confirmed-dependencies.log"
[[ "$(cat "${TEST_ROOTFS}/usr/local/etc/xray/config.json")" == original-fixture ]]
[[ ! -e "${TEST_ROOTFS}/usr/local/lib/xtun" && ! -e "${TEST_ROOTFS}/usr/local/etc/xray/node-meta.env" ]]
[[ ! -e "${TEST_ROOTFS}/var/lib/xtun/pending-op.tsv" && ! -e "${TEST_ROOTFS}/etc/systemd/system/xray.service" ]]
[[ "$(stat -c %a "${TEST_ROOTFS}/root/.xtun-install-draft.env")" == 600 ]]
for tool in openssl ip ss qrencode; do chroot "${TEST_ROOTFS}" /bin/bash -c 'command -v "$1"' _ "${tool}" >/dev/null; done
printf 'confirmed-dependencies-invalid-cert\t0\n' | tee -a "${TEST_EVIDENCE}/results.tsv"

# 逐个物理移走 chroot 内的可执行文件，再走真实取消路径；不伪造 command -v。
for tool in openssl ip qrencode; do
  tool_path="$(chroot "${TEST_ROOTFS}" /bin/bash -c 'command -v "$1"' _ "${tool}")"
  TEST_HIDDEN_TOOL="$(chroot "${TEST_ROOTFS}" readlink -f "${tool_path}")"
  mv "${TEST_ROOTFS}${TEST_HIDDEN_TOOL}" "${TEST_ROOTFS}/var/tmp/hidden-tool"
  if chroot "${TEST_ROOTFS}" /bin/bash -c 'command -v "$1"' _ "${tool}" >/dev/null; then exit 1; fi
  minimal_cancel "${tool}-missing-cancel"
  grep -q "${tool}" "${TEST_EVIDENCE}/${tool}-missing-cancel.log"
  mv "${TEST_ROOTFS}/var/tmp/hidden-tool" "${TEST_ROOTFS}${TEST_HIDDEN_TOOL}"
  TEST_HIDDEN_TOOL=""
done
printf 'minimal install evidence: %s\n' "${TEST_EVIDENCE}"
