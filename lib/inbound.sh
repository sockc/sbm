#!/usr/bin/env bash

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  if has_cmd uuidgen; then
    uuidgen
    return 0
  fi

  if has_cmd python3; then
    python3 -c 'import uuid; print(uuid.uuid4())'
    return 0
  fi

  err "无法生成 UUID：缺少 /proc、uuidgen 或 python3"
  return 1
}

gen_short_id() {
  if has_cmd openssl; then
    openssl rand -hex 4
    return 0
  fi

  od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

gen_reality_keypair() {
  local out private_key public_key

  out="$(sing-box generate reality-keypair 2>/dev/null)" || {
    err "执行 sing-box generate reality-keypair 失败"
    return 1
  }

  private_key="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public/  {print $2; exit}')"

  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    err "解析 Reality 密钥失败"
    printf '%s\n' "$out"
    return 1
  fi

  printf '%s|%s\n' "$private_key" "$public_key"
}

detect_connect_host() {
  local ip=""
  if has_cmd curl; then
    ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  elif has_cmd wget; then
    ip="$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [ -n "$ip" ]; then
    printf '%s\n' "$ip"
    return 0
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

is_valid_ip() {
  local addr="$1"

  [ "$addr" = "::" ] && return 0
  [ "$addr" = "0.0.0.0" ] && return 0

  if has_cmd python3; then
    python3 - "$addr" <<'PY'
import sys, ipaddress
try:
    ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0)
except Exception:
    raise SystemExit(1)
PY
    return $?
  fi

  case "$addr" in
    *[!0-9a-fA-F:.]*|'') return 1 ;;
    *) return 0 ;;
  esac
}

prompt_listen_addr() {
  local addr
  while true; do
    addr="$(prompt_default "请输入监听地址" "0.0.0.0")"
    if is_valid_ip "$addr"; then
      printf '%s\n' "$addr"
      return 0
    fi
    echo "输入无效：监听地址必须是 IP，例如 0.0.0.0 或 ::"
  done
}

prompt_listen_port() {
  local port
  while true; do
    port="$(prompt_default "请输入监听端口" "443")"
    case "$port" in
      ''|*[!0-9]*)
        echo "输入无效：端口必须是 1-65535 的数字"
        ;;
      *)
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
          printf '%s\n' "$port"
          return 0
        fi
        echo "输入无效：端口必须是 1-65535"
        ;;
    esac
  done
}

restart_singbox_service() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

save_reality_meta() {
  local reality_tag="$1"
  local connect_host="$2"
  local listen_port="$3"
  local user_name="$4"
  local user_uuid="$5"
  local flow="$6"
  local server_name="$7"
  local handshake_server="$8"
  local handshake_port="$9"
  local public_key="${10}"
  local private_key="${11}"
  local short_id="${12}"
  local tcp_fast_open="${13}"

  ensure_inbound_meta_dir
  local meta_file
  meta_file="$(inbound_meta_file_by_tag "${reality_tag}")"

  cat > "${meta_file}" <<JSON
{
  "protocol": "vless-reality",
  "tag": "${reality_tag}",
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "user_name": "${user_name}",
  "uuid": "${user_uuid}",
  "flow": "${flow}",
  "server_name": "${server_name}",
  "handshake_server": "${handshake_server}",
  "handshake_port": ${handshake_port},
  "public_key": "${public_key}",
  "private_key": "${private_key}",
  "short_id": "${short_id}",
  "tcp_fast_open": "${tcp_fast_open}",
  "type": "tcp",
  "security": "reality",
  "fingerprint": "${DEFAULT_CLIENT_FP}"
}
JSON

  chmod 600 "${meta_file}" 2>/dev/null || true
}

deploy_vless_reality() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"
  ensure_inbound_meta_dir

  local reality_tag
  local listen_addr listen_port user_name user_uuid
  local server_name handshake_server handshake_port
  local short_id keys private_key public_key
  local connect_host tcp_fast_open tmp_file
  local default_host flow

  default_host="$(detect_default_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP"

  reality_tag="$(prompt_default "请输入 Reality 实例标签" "$(next_inbound_tag_by_prefix "reality")")"
  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_listen_port)"
  user_name="$(prompt_default "请输入用户备注" "${reality_tag}")"
  user_uuid="$(prompt_default "请输入 UUID" "$(gen_uuid)")"
  server_name="$(prompt_default "请输入伪装域名 server_name" "download.visualstudio.microsoft.com")"
  handshake_server="$(prompt_default "请输入 Reality 握手目标域名" "${server_name}")"
  handshake_port="$(prompt_default "请输入 Reality 握手目标端口" "443")"
  short_id="$(prompt_default "请输入 short_id" "$(gen_short_id)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "${default_host}")"
  flow="xtls-rprx-vision"

  if confirm_default_no "开启 TCP Fast Open 吗？"; then
    tcp_fast_open="true"
  else
    tcp_fast_open="false"
  fi

  keys="$(gen_reality_keypair)" || {
    pause_enter
    return 1
  }

  private_key="${keys%%|*}"
  public_key="${keys##*|}"

  echo
  echo "========== 配置预览 =========="
  echo "实例标签       : ${reality_tag}"
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}"
  echo "用户备注       : ${user_name}"
  echo "UUID           : ${user_uuid}"
  echo "server_name    : ${server_name}"
  echo "握手目标       : ${handshake_server}:${handshake_port}"
  echo "short_id       : ${short_id}"
  echo "连接地址       : ${connect_host}"
  echo "TCP Fast Open  : ${tcp_fast_open}"
  echo "=============================="
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.reality.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${reality_tag}" "${listen_addr}" "${listen_port}" "${tcp_fast_open}" \
    "${user_name}" "${user_uuid}" "${flow}" \
    "${server_name}" "${handshake_server}" "${handshake_port}" \
    "${private_key}" "${short_id}" <<'PY'
import json, sys

(
    path_cfg, reality_tag, listen_addr, listen_port, tcp_fast_open,
    user_name, user_uuid, flow,
    server_name, handshake_server, handshake_port,
    private_key, short_id
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

reality_obj = {
    "type": "vless",
    "tag": reality_tag,
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "tcp_fast_open": (tcp_fast_open == "true"),
    "users": [
        {
            "name": user_name,
            "uuid": user_uuid,
            "flow": flow
        }
    ],
    "tls": {
        "enabled": True,
        "server_name": server_name,
        "reality": {
            "enabled": True,
            "handshake": {
                "server": handshake_server,
                "server_port": int(handshake_port)
            },
            "private_key": private_key,
            "short_id": [short_id]
        }
    }
}

for i, ib in enumerate(inbounds):
    if ib.get("tag") == reality_tag:
        inbounds[i] = reality_obj
        break
else:
    inbounds.append(reality_obj)

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 Reality 入站失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_vless_meta \
    "${reality_tag}" "reality" "${listen_addr}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${user_uuid}" "${flow}" "${server_name}" "0" \
    "" "" \
    "${public_key}" "${private_key}" "${short_id}" "${handshake_server}" "${handshake_port}"

  ok "VLESS + Reality 部署完成"
  echo
  echo "------ 客户端关键参数 ------"
  echo "实例标签    : ${reality_tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "UUID        : ${user_uuid}"
  echo "流控        : ${flow}"
  echo "传输        : tcp"
  echo "TLS         : reality"
  echo "SNI         : ${server_name}"
  echo "Public Key  : ${public_key}"
  echo "Short ID    : ${short_id}"
  echo "备注        : ${user_name}"
  echo "----------------------------"
  echo

  local meta_file vless_uri
  meta_file="$(vless_meta_file_by_tag "${reality_tag}")"
  vless_uri="$(build_vless_uri_from_meta "${meta_file}" "${user_name}" "${user_uuid}" 2>/dev/null || true)"
  show_uri_and_qr "VLESS Reality URI" "${vless_uri}"

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    local backend
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "tcp"; then
          ok "已放行 ${listen_port}/tcp"
        else
          err "放行 ${listen_port}/tcp 失败"
        fi
      fi
    fi
  fi

  pause_enter
}

menu_deploy_vless_reality() {
  deploy_vless_reality
}

gen_password() {
  if has_cmd openssl; then
    openssl rand -hex 12
    return 0
  fi

  if has_cmd python3; then
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
    return 0
  fi

  echo "pass-$(date +%s)"
}

gen_self_signed_cert() {
  local server_name="$1"
  local cert_dir="${BASE_DIR}/certs"
  local cert_path="${cert_dir}/hy2-selfsigned.crt"
  local key_path="${cert_dir}/hy2-selfsigned.key"
  local san tmp_conf

  if ! has_cmd openssl; then
    err "未找到 openssl，无法自动生成自签证书"
    return 1
  fi

  mkdir -p "${cert_dir}" "${TMP_DIR}"

  if is_valid_ip "${server_name}"; then
    san="IP:${server_name}"
  else
    san="DNS:${server_name}"
  fi

  tmp_conf="${TMP_DIR}/openssl-hy2-selfsigned.cnf"

  cat > "${tmp_conf}" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${server_name}

[v3_req]
subjectAltName = ${san}
extendedKeyUsage = serverAuth
keyUsage = digitalSignature, keyEncipherment
EOF

  if ! openssl req -x509 -nodes -newkey rsa:2048 \
    -days 3650 \
    -keyout "${key_path}" \
    -out "${cert_path}" \
    -config "${tmp_conf}" \
    -extensions v3_req >/dev/null 2>&1; then
    err "生成自签证书失败"
    return 1
  fi

  chmod 600 "${key_path}" 2>/dev/null || true
  chmod 644 "${cert_path}" 2>/dev/null || true

  printf '%s|%s\n' "${cert_path}" "${key_path}"
}

prompt_port_default() {
  local prompt="$1"
  local default_port="$2"
  local port

  while true; do
    port="$(prompt_default "${prompt}" "${default_port}")"
    case "$port" in
      ''|*[!0-9]*)
        echo "输入无效：端口必须是 1-65535 的数字"
        ;;
      *)
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
          printf '%s\n' "$port"
          return 0
        fi
        echo "输入无效：端口必须是 1-65535"
        ;;
    esac
  done
}

ensure_inbound_meta_dir() {
  mkdir -p "${INBOUND_META_DIR}"
}

inbound_meta_name_by_tag() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe='._-'))
PY
}

inbound_meta_file_by_tag() {
  local tag="$1"
  local name
  name="$(inbound_meta_name_by_tag "${tag}")"
  printf '%s/%s.json\n' "${INBOUND_META_DIR}" "${name}"
}

next_inbound_tag_by_prefix() {
  local prefix="$1"

  python3 - "${CONFIG_DIR}/config.json" "${prefix}" <<'PY'
import json, os, re, sys

cfg_path, prefix = sys.argv[1], sys.argv[2]
nums = []

if os.path.exists(cfg_path):
    cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
    for ib in cfg.get("inbounds", []):
        tag = str(ib.get("tag", ""))
        m = re.fullmatch(re.escape(prefix) + r"-(\d{3})", tag)
        if m:
            nums.append(int(m.group(1)))

n = 1
while n in nums:
    n += 1

print(f"{prefix}-{n:03d}")
PY
}

show_current_inbounds() {
  require_config_file || {
    pause_enter
    return 1
  }

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
inbounds = cfg.get("inbounds", [])

print("当前入站实例：")
print("编号 标签                     类型         监听地址")
print("----------------------------------------------------------------")

idx = 1
for ib in inbounds:
    tag = ib.get("tag", "") or "<未设置>"
    typ = ib.get("type", "")
    listen = ib.get("listen", "")
    port = ib.get("listen_port", "")
    endpoint = f"{listen}:{port}" if listen and port else f"{listen or '<空>'}:{port or '<空>'}"
    print(f"{idx:<4} {tag:<24} {typ:<12} {endpoint}")
    idx += 1

if idx == 1:
    print("<暂无入站实例>")

print("----------------------------------------------------------------")
PY

  pause_enter
}

get_inbound_tag_by_index() {
  local idx="$1"

  python3 - "${CONFIG_DIR}/config.json" "${idx}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = int(sys.argv[2])
inbounds = cfg.get("inbounds", [])

if idx < 1 or idx > len(inbounds):
    raise SystemExit(1)

print(inbounds[idx - 1].get("tag", "") or "")
PY
}

delete_legacy_inbound_meta_by_tag() {
  local tag="$1"

  case "${tag}" in
    vless-reality-in|reality-*|reality*)
      rm -f "${BASE_DIR}/reality-meta.json"
      ;;
    hy2-in|hy2-*|hy2*)
      rm -f "${BASE_DIR}/hy2-meta.json"
      ;;
    vmess-in|vmess-*|vmess*)
      rm -f "${BASE_DIR}/vmess-meta.json"
      rm -rf "${BASE_DIR}/vmess-meta"
      ;;
    tuic-in|tuic-*|tuic*)
      rm -f "${BASE_DIR}/tuic-meta.json"
      ;;
    trojan-in|trojan-*|trojan*)
      rm -f "${BASE_DIR}/trojan-meta.json"
      ;;
  esac
}

delete_inbound_instance() {
  need_root
  require_config_file || {
    pause_enter
    return 1
  }

  ensure_inbound_meta_dir

  show_current_inbounds
  echo

  local idx tmp_file tag meta_file
  idx="$(prompt_required "请输入要删除的入站编号")"

  # 先取 tag，仅用于删元数据；允许为空
  tag="$(get_inbound_tag_by_index "${idx}" 2>/dev/null || true)"

  echo "准备删除入站实例：${tag:-<未设置>}"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.delete-inbound.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${idx}" <<'PY'
import json, sys

path_cfg = sys.argv[1]
idx = int(sys.argv[2])

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.get("inbounds", [])

if idx < 1 or idx > len(inbounds):
    raise SystemExit(1)

del inbounds[idx - 1]
cfg["inbounds"] = inbounds

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "删除入站实例失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  if [ -n "${tag:-}" ]; then
    meta_file="$(inbound_meta_file_by_tag "${tag}")"
    rm -f "${meta_file}"
    delete_legacy_inbound_meta_by_tag "${tag}"
  fi

  ok "已删除入站实例：${tag:-<未设置>}"
  pause_enter
}

save_hy2_meta() {
  local hy2_tag="$1"
  local connect_host="$2"
  local listen_port="$3"
  local user_name="$4"
  local password="$5"
  local server_name="$6"
  local obfs_password="$7"
  local up_mbps="$8"
  local down_mbps="$9"
  local cert_mode="${10}"

  ensure_inbound_meta_dir
  local meta_file
  meta_file="$(inbound_meta_file_by_tag "${hy2_tag}")"

  cat > "${meta_file}" <<JSON
{
  "protocol": "hysteria2",
  "tag": "${hy2_tag}",
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "user_name": "${user_name}",
  "password": "${password}",
  "server_name": "${server_name}",
  "cert_mode": "${cert_mode}",
  "obfs_password": "${obfs_password}",
  "up_mbps": ${up_mbps},
  "down_mbps": ${down_mbps}
}
JSON

  chmod 600 "${meta_file}" 2>/dev/null || true
}

deploy_hysteria2() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"
  ensure_inbound_meta_dir

  local hy2_tag
  local listen_addr listen_port user_name password
  local cert_path key_path connect_host server_name
  local up_mbps down_mbps obfs_password use_obfs
  local cert_mode default_host tmp_file backend cert_pair

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  hy2_tag="$(prompt_default "请输入 Hysteria2 实例标签" "$(next_inbound_tag_by_prefix "hy2")")"
  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_port_default "请输入 Hysteria2 监听端口" "8443")"
  user_name="$(prompt_default "请输入 Hysteria2 用户备注" "${hy2_tag}")"
  password="$(prompt_default "请输入 Hysteria2 密码" "$(gen_password)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "${default_host}")"
  server_name="$(prompt_required "请输入客户端 server_name / SNI（证书域名）")"

  echo
  echo "证书模式："
  echo "1. 正式证书"
  echo "2. 自签证书"
  read -r -p "请选择 [1-2]（默认 1）: " cert_mode
  cert_mode="${cert_mode:-1}"

  if [ "${cert_mode}" = "2" ]; then
    cert_pair="$(gen_self_signed_cert "${server_name}")" || {
      pause_enter
      return 1
    }
    cert_path="${cert_pair%%|*}"
    key_path="${cert_pair##*|}"

    echo
    echo "已自动生成自签证书："
    echo "certificate_path : ${cert_path}"
    echo "key_path         : ${key_path}"
    echo
  else
    cert_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
    key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
  fi

  up_mbps="$(prompt_default "请输入上行带宽 up_mbps" "100")"
  down_mbps="$(prompt_default "请输入下行带宽 down_mbps" "100")"

  if [ ! -f "${cert_path}" ]; then
    err "证书文件不存在：${cert_path}"
    pause_enter
    return 1
  fi

  if [ ! -f "${key_path}" ]; then
    err "私钥文件不存在：${key_path}"
    pause_enter
    return 1
  fi

  if confirm_default_no "启用 salamander obfs 吗？"; then
    use_obfs="true"
    obfs_password="$(prompt_default "请输入 obfs 密码" "$(gen_password)")"
  else
    use_obfs="false"
    obfs_password=""
  fi

  echo
  echo "========== Hysteria2 配置预览 =========="
  echo "实例标签       : ${hy2_tag}"
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}/udp"
  echo "用户备注       : ${user_name}"
  echo "密码           : ${password}"
  echo "客户端连接地址 : ${connect_host}"
  echo "客户端 SNI     : ${server_name}"
  if [ "${cert_mode}" = "2" ]; then
    echo "证书模式       : 自签证书"
  else
    echo "证书模式       : 正式证书"
  fi
  echo "证书路径       : ${cert_path}"
  echo "私钥路径       : ${key_path}"
  echo "up_mbps        : ${up_mbps}"
  echo "down_mbps      : ${down_mbps}"
  echo "obfs           : ${use_obfs}"
  if [ "${use_obfs}" = "true" ]; then
    echo "obfs_password  : ${obfs_password}"
  fi
  echo "========================================"
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.hy2.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${hy2_tag}" "${listen_addr}" "${listen_port}" "${user_name}" "${password}" \
    "${cert_path}" "${key_path}" "${up_mbps}" "${down_mbps}" \
    "${use_obfs}" "${obfs_password}" <<'PY'
import json, sys

(
    path_cfg, hy2_tag, listen_addr, listen_port, user_name, password,
    cert_path, key_path, up_mbps, down_mbps,
    use_obfs, obfs_password
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

hy2_obj = {
    "type": "hysteria2",
    "tag": hy2_tag,
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "up_mbps": int(up_mbps),
    "down_mbps": int(down_mbps),
    "users": [
        {
            "name": user_name,
            "password": password
        }
    ],
    "tls": {
        "enabled": True,
        "certificate_path": cert_path,
        "key_path": key_path
    }
}

if use_obfs == "true":
    hy2_obj["obfs"] = {
        "type": "salamander",
        "password": obfs_password
    }

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == hy2_tag:
        inbounds[i] = hy2_obj
        replaced = True
        break

if not replaced:
    inbounds.append(hy2_obj)

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 Hysteria2 入站失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_hy2_meta "${hy2_tag}" "${connect_host}" "${listen_port}" "${user_name}" "${password}" "${server_name}" "${obfs_password}" "${up_mbps}" "${down_mbps}" "${cert_mode}"

  ok "Hysteria2 部署完成"
  echo
  echo "------ Hysteria2 客户端关键参数 ------"
  echo "实例标签    : ${hy2_tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "用户名备注  : ${user_name}"
  echo "密码        : ${password}"
  echo "SNI         : ${server_name}"
  echo "协议        : hysteria2"
  echo "传输        : UDP / QUIC"
  echo "up/down     : ${up_mbps}/${down_mbps} Mbps"
  if [ "${use_obfs}" = "true" ]; then
    echo "obfs        : salamander"
    echo "obfs密码    : ${obfs_password}"
  fi
  echo "--------------------------------------"
  echo

  if [ "${cert_mode}" = "2" ]; then
    echo "证书模式    : 自签证书"
    echo "客户端建议  :"
    echo "  1. 更安全：在客户端 tls.certificate_path 中导入这张自签证书"
    echo "  2. 更省事：在客户端 tls.insecure = true（仅测试/临时使用）"
    echo "自签证书路径: ${cert_path}"
  else
    echo "证书模式    : 正式证书"
    echo "客户端建议  : 正常校验证书即可"
  fi
  echo
  echo "注意：如果你用官方 Hysteria2 客户端，常见的 userpass 实际要填成 <用户名>:<密码> 的组合。"
  echo

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/udp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "udp"; then
          ok "已放行 ${listen_port}/udp"
        else
          err "放行 ${listen_port}/udp 失败"
        fi
      fi
    fi
  fi

  local hy2_meta hy2_uri
  hy2_meta="$(inbound_meta_file_by_tag "${hy2_tag}")"
  hy2_uri="$(build_hy2_uri "${hy2_meta}" 2>/dev/null || true)"
  show_uri_and_qr "Hysteria2 URI" "${hy2_uri}"

  pause_enter
}

menu_deploy_hysteria2() {
  deploy_hysteria2
}

gen_uuid_value() {
  if has_cmd sing-box; then
    sing-box generate uuid 2>/dev/null && return 0
  fi

  if has_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
    return 0
  fi

  python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
}

gen_random_path() {
  if has_cmd openssl; then
    echo "/$(openssl rand -hex 4)"
    return 0
  fi

  python3 - <<'PY'
import secrets
print("/" + secrets.token_hex(4))
PY
}

save_vmess_meta() {
  local vmess_tag="$1"
  local connect_host="$2"
  local listen_port="$3"
  local user_name="$4"
  local uuid="$5"
  local transport_type="$6"
  local tls_enabled="$7"
  local server_name="$8"
  local path="$9"
  local host="${10}"
  local method="${11}"
  local cert_mode="${12}"

  ensure_inbound_meta_dir
  local meta_file
  meta_file="$(inbound_meta_file_by_tag "${vmess_tag}")"

  cat > "${meta_file}" <<JSON
{
  "protocol": "vmess",
  "tag": "${vmess_tag}",
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "user_name": "${user_name}",
  "uuid": "${uuid}",
  "transport_type": "${transport_type}",
  "tls_enabled": "${tls_enabled}",
  "server_name": "${server_name}",
  "path": "${path}",
  "host": "${host}",
  "method": "${method}",
  "cert_mode": "${cert_mode}"
}
JSON

  chmod 600 "${meta_file}" 2>/dev/null || true
}

deploy_vmess() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"

  local transport_choice transport_type tls_choice tls_enabled cert_mode
  local listen_addr listen_port user_name uuid vmess_tag
  local connect_host server_name cert_path key_path
  local path host method default_host tmp_file backend cert_pair default_tag_prefix

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  echo
  echo "请选择 VMess 传输方式："
  echo "1. HTTP"
  echo "2. WebSocket"
  read -r -p "请选择 [1-2]（默认 2）: " transport_choice
  transport_choice="${transport_choice:-2}"

  case "${transport_choice}" in
    1)
      transport_type="http"
      default_tag_prefix="vmess-http"
      ;;
    2)
      transport_type="ws"
      default_tag_prefix="vmess-ws"
      ;;
    *)
      err "无效选项"
      pause_enter
      return 1
      ;;
  esac

  vmess_tag="$(prompt_default "请输入 VMess 实例标签" "$(next_inbound_tag_by_prefix "${default_tag_prefix}")")"

  echo
  echo "是否启用 TLS："
  echo "1. 开启"
  echo "2. 关闭"
  read -r -p "请选择 [1-2]（默认 2）: " tls_choice
  tls_choice="${tls_choice:-2}"

  case "${tls_choice}" in
    1) tls_enabled="true" ;;
    2) tls_enabled="false" ;;
    *)
      err "无效选项"
      pause_enter
      return 1
      ;;
  esac

  listen_addr="$(prompt_listen_addr)"
  if [ "${tls_enabled}" = "true" ]; then
    listen_port="$(prompt_port_default "请输入 VMess 监听端口" "443")"
  else
    if [ "${transport_type}" = "http" ]; then
      listen_port="$(prompt_port_default "请输入 VMess 监听端口" "8080")"
    else
      listen_port="$(prompt_port_default "请输入 VMess 监听端口" "80")"
    fi
  fi

  user_name="$(prompt_default "请输入 VMess 用户备注" "${vmess_tag}")"
  uuid="$(prompt_default "请输入 UUID" "$(gen_uuid_value)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "${default_host}")"

  if [ "${transport_type}" = "http" ]; then
    path="$(prompt_default "请输入 HTTP path" "/")"
    host="$(prompt_default "请输入 HTTP host（留空为不设置）" "")"
    method="$(prompt_default "请输入 HTTP method" "GET")"
  else
    path="$(prompt_default "请输入 WebSocket path" "$(gen_random_path)")"
    host="$(prompt_default "请输入 WS Host 头（留空为不设置）" "")"
    method=""
  fi

  server_name=""
  cert_path=""
  key_path=""
  cert_mode="0"

  if [ "${tls_enabled}" = "true" ]; then
    server_name="$(prompt_required "请输入 TLS server_name / SNI")"

    echo
    echo "证书模式："
    echo "1. 正式证书"
    echo "2. 自签证书"
    read -r -p "请选择 [1-2]（默认 1）: " cert_mode
    cert_mode="${cert_mode:-1}"

    if [ "${cert_mode}" = "2" ]; then
      cert_pair="$(gen_self_signed_cert "${server_name}")" || {
        pause_enter
        return 1
      }
      cert_path="${cert_pair%%|*}"
      key_path="${cert_pair##*|}"

      echo
      echo "已自动生成自签证书："
      echo "certificate_path : ${cert_path}"
      echo "key_path         : ${key_path}"
      echo
    else
      cert_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
      key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
    fi

    if [ ! -f "${cert_path}" ]; then
      err "证书文件不存在：${cert_path}"
      pause_enter
      return 1
    fi

    if [ ! -f "${key_path}" ]; then
      err "私钥文件不存在：${key_path}"
      pause_enter
      return 1
    fi
  fi

  echo
  echo "========== VMess 配置预览 =========="
  echo "实例标签       : ${vmess_tag}"
  echo "传输方式       : ${transport_type}"
  echo "TLS            : ${tls_enabled}"
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}"
  echo "用户备注       : ${user_name}"
  echo "UUID           : ${uuid}"
  echo "客户端连接地址 : ${connect_host}"
  echo "alterId        : 0"
  echo "path           : ${path}"
  if [ -n "${host}" ]; then
    echo "host/Host      : ${host}"
  fi
  if [ "${transport_type}" = "http" ]; then
    echo "method         : ${method}"
  fi
  if [ "${tls_enabled}" = "true" ]; then
    echo "server_name    : ${server_name}"
    if [ "${cert_mode}" = "2" ]; then
      echo "证书模式       : 自签证书"
    else
      echo "证书模式       : 正式证书"
    fi
    echo "证书路径       : ${cert_path}"
    echo "私钥路径       : ${key_path}"
  fi
  echo "==================================="
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.vmess.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${vmess_tag}" "${listen_addr}" "${listen_port}" "${user_name}" "${uuid}" \
    "${transport_type}" "${path}" "${host}" "${method}" \
    "${tls_enabled}" "${server_name}" "${cert_path}" "${key_path}" <<'PY'
import json, sys

(
    path_cfg, vmess_tag, listen_addr, listen_port, user_name, uuid,
    transport_type, req_path, host, method,
    tls_enabled, server_name, cert_path, key_path
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

vmess_obj = {
    "type": "vmess",
    "tag": vmess_tag,
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "users": [
        {
            "name": user_name,
            "uuid": uuid,
            "alterId": 0
        }
    ]
}

if transport_type == "http":
    transport = {
        "type": "http",
        "path": req_path,
        "method": method or "GET"
    }
    if host:
        transport["host"] = [host]
elif transport_type == "ws":
    transport = {
        "type": "ws",
        "path": req_path
    }
    if host:
        transport["headers"] = {"Host": host}
else:
    raise SystemExit("unknown transport type")

vmess_obj["transport"] = transport

if tls_enabled == "true":
    vmess_obj["tls"] = {
        "enabled": True,
        "server_name": server_name,
        "certificate_path": cert_path,
        "key_path": key_path
    }

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == vmess_tag:
        inbounds[i] = vmess_obj
        replaced = True
        break

if not replaced:
    inbounds.append(vmess_obj)

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 VMess 入站失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_vmess_meta "${vmess_tag}" "${connect_host}" "${listen_port}" "${user_name}" "${uuid}" "${transport_type}" "${tls_enabled}" "${server_name}" "${path}" "${host}" "${method}" "${cert_mode}"

  ok "VMess 部署完成"
  echo
  echo "------ VMess 客户端关键参数 ------"
  echo "实例标签    : ${vmess_tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "UUID        : ${uuid}"
  echo "alterId     : 0"
  echo "传输        : ${transport_type}"
  echo "path        : ${path}"
  if [ -n "${host}" ]; then
    echo "host/Host   : ${host}"
  fi
  if [ "${transport_type}" = "http" ]; then
    echo "method      : ${method}"
  fi
  if [ "${tls_enabled}" = "true" ]; then
    echo "TLS         : enabled"
    echo "SNI         : ${server_name}"
  else
    echo "TLS         : disabled"
  fi
  echo "----------------------------------"
  echo

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "tcp"; then
          ok "已放行 ${listen_port}/tcp"
        else
          err "放行 ${listen_port}/tcp 失败"
        fi
      fi
    fi
  fi

  local vmess_meta vmess_uri
  vmess_meta="$(inbound_meta_file_by_tag "${vmess_tag}")"
  vmess_uri="$(build_vmess_uri "${vmess_meta}" 2>/dev/null || true)"
  show_uri_and_qr "VMess URI" "${vmess_uri}"

  pause_enter
}

menu_deploy_vmess() {
  deploy_vmess
}

save_tuic_meta() {
  local tuic_tag="$1"
  local connect_host="$2"
  local listen_port="$3"
  local user_name="$4"
  local uuid="$5"
  local password="$6"
  local server_name="$7"
  local congestion_control="$8"
  local zero_rtt_handshake="$9"
  local heartbeat="${10}"
  local cert_mode="${11}"

  ensure_inbound_meta_dir
  local meta_file
  meta_file="$(inbound_meta_file_by_tag "${tuic_tag}")"

  cat > "${meta_file}" <<JSON
{
  "protocol": "tuic",
  "tag": "${tuic_tag}",
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "user_name": "${user_name}",
  "uuid": "${uuid}",
  "password": "${password}",
  "server_name": "${server_name}",
  "congestion_control": "${congestion_control}",
  "zero_rtt_handshake": "${zero_rtt_handshake}",
  "heartbeat": "${heartbeat}",
  "cert_mode": "${cert_mode}"
}
JSON

  chmod 600 "${meta_file}" 2>/dev/null || true
}

deploy_tuic() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"
  ensure_inbound_meta_dir

  local tuic_tag
  local listen_addr listen_port user_name uuid password
  local connect_host server_name cert_path key_path cert_mode
  local congestion_control zero_rtt_choice zero_rtt_handshake
  local heartbeat default_host tmp_file backend cert_pair

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  tuic_tag="$(prompt_default "请输入 TUIC 实例标签" "$(next_inbound_tag_by_prefix "tuic")")"
  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_port_default "请输入 TUIC 监听端口" "443")"
  user_name="$(prompt_default "请输入 TUIC 用户备注" "${tuic_tag}")"
  uuid="$(prompt_default "请输入 UUID" "$(gen_uuid_value)")"
  password="$(prompt_default "请输入 TUIC 密码" "$(gen_password)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "${default_host}")"
  server_name="$(prompt_required "请输入 TLS server_name / SNI")"

  echo
  echo "证书模式："
  echo "1. 正式证书"
  echo "2. 自签证书"
  read -r -p "请选择 [1-2]（默认 1）: " cert_mode
  cert_mode="${cert_mode:-1}"

  if [ "${cert_mode}" = "2" ]; then
    cert_pair="$(gen_self_signed_cert "${server_name}")" || {
      pause_enter
      return 1
    }
    cert_path="${cert_pair%%|*}"
    key_path="${cert_pair##*|}"

    echo
    echo "已自动生成自签证书："
    echo "certificate_path : ${cert_path}"
    echo "key_path         : ${key_path}"
    echo
  else
    cert_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
    key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
  fi

  if [ ! -f "${cert_path}" ]; then
    err "证书文件不存在：${cert_path}"
    pause_enter
    return 1
  fi

  if [ ! -f "${key_path}" ]; then
    err "私钥文件不存在：${key_path}"
    pause_enter
    return 1
  fi

  echo
  echo "请选择 congestion_control："
  echo "1. cubic"
  echo "2. new_reno"
  echo "3. bbr"
  read -r -p "请选择 [1-3]（默认 1）: " congestion_control
  case "${congestion_control:-1}" in
    1) congestion_control="cubic" ;;
    2) congestion_control="new_reno" ;;
    3) congestion_control="bbr" ;;
    *) congestion_control="cubic" ;;
  esac

  echo
  echo "是否开启 zero_rtt_handshake："
  echo "1. 关闭（推荐）"
  echo "2. 开启"
  read -r -p "请选择 [1-2]（默认 1）: " zero_rtt_choice
  case "${zero_rtt_choice:-1}" in
    1) zero_rtt_handshake="false" ;;
    2) zero_rtt_handshake="true" ;;
    *) zero_rtt_handshake="false" ;;
  esac

  heartbeat="$(prompt_default "请输入 heartbeat（默认 10s）" "10s")"

  echo
  echo "========== TUIC 配置预览 =========="
  echo "实例标签       : ${tuic_tag}"
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}/udp"
  echo "用户备注       : ${user_name}"
  echo "UUID           : ${uuid}"
  echo "密码           : ${password}"
  echo "客户端连接地址 : ${connect_host}"
  echo "SNI            : ${server_name}"
  if [ "${cert_mode}" = "2" ]; then
    echo "证书模式       : 自签证书"
  else
    echo "证书模式       : 正式证书"
  fi
  echo "证书路径       : ${cert_path}"
  echo "私钥路径       : ${key_path}"
  echo "congestion     : ${congestion_control}"
  echo "zero_rtt       : ${zero_rtt_handshake}"
  echo "heartbeat      : ${heartbeat}"
  echo "==================================="
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.tuic.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${tuic_tag}" "${listen_addr}" "${listen_port}" "${user_name}" "${uuid}" "${password}" \
    "${cert_path}" "${key_path}" "${congestion_control}" "${zero_rtt_handshake}" "${heartbeat}" <<'PY'
import json, sys

(
    path_cfg, tuic_tag, listen_addr, listen_port, user_name, uuid, password,
    cert_path, key_path, congestion_control, zero_rtt_handshake, heartbeat
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

tuic_obj = {
    "type": "tuic",
    "tag": tuic_tag,
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "users": [
        {
            "name": user_name,
            "uuid": uuid,
            "password": password
        }
    ],
    "congestion_control": congestion_control,
    "zero_rtt_handshake": (zero_rtt_handshake == "true"),
    "heartbeat": heartbeat,
    "tls": {
        "enabled": True,
        "certificate_path": cert_path,
        "key_path": key_path
    }
}

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == tuic_tag:
        inbounds[i] = tuic_obj
        replaced = True
        break

if not replaced:
    inbounds.append(tuic_obj)

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 TUIC 入站失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_tuic_meta "${tuic_tag}" "${connect_host}" "${listen_port}" "${user_name}" "${uuid}" "${password}" "${server_name}" "${congestion_control}" "${zero_rtt_handshake}" "${heartbeat}" "${cert_mode}"

  ok "TUIC 部署完成"
  echo
  echo "------ TUIC 客户端关键参数 ------"
  echo "实例标签    : ${tuic_tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "UUID        : ${uuid}"
  echo "密码        : ${password}"
  echo "SNI         : ${server_name}"
  echo "congestion  : ${congestion_control}"
  echo "zero_rtt    : ${zero_rtt_handshake}"
  echo "heartbeat   : ${heartbeat}"
  echo "--------------------------------"
  echo

  if [ "${zero_rtt_handshake}" = "true" ]; then
    echo "警告：zero_rtt_handshake 已开启，存在重放攻击风险，不推荐长期使用。"
    echo
  fi

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/udp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "udp"; then
          ok "已放行 ${listen_port}/udp"
        else
          err "放行 ${listen_port}/udp 失败"
        fi
      fi
    fi
  fi

  local tuic_meta tuic_uri
  tuic_meta="$(inbound_meta_file_by_tag "${tuic_tag}")"
  tuic_uri="$(build_tuic_uri "${tuic_meta}" 2>/dev/null || true)"
  show_uri_and_qr "TUIC URI" "${tuic_uri}"

  pause_enter
}

menu_deploy_tuic() {
  deploy_tuic
}

# ---------------------------
# AnyTLS helpers
# ---------------------------

detect_default_connect_host() {
  local host=""

  # 优先取 IPv4
  if has_cmd curl; then
    host="$(curl -4 --noproxy '*' -fsSL --max-time 5 https://api.ip.sb/ip 2>/dev/null || true)"
    [ -n "${host}" ] || host="$(curl -4 --noproxy '*' -fsSL --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
    [ -n "${host}" ] || host="$(curl -4 --noproxy '*' -fsSL --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  elif has_cmd wget; then
    host="$(wget -4 -qO- --timeout=5 https://api.ip.sb/ip 2>/dev/null || true)"
    [ -n "${host}" ] || host="$(wget -4 -qO- --timeout=5 https://ifconfig.me/ip 2>/dev/null || true)"
    [ -n "${host}" ] || host="$(wget -4 -qO- --timeout=5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  fi

  host="$(printf '%s' "${host}" | tr -d '\r\n[:space:]')"

  # 再兜底
  if [ -z "${host}" ]; then
    host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    host="$(printf '%s' "${host}" | tr -d '\r\n[:space:]')"
  fi

  [ -z "${host}" ] && host="127.0.0.1"
  printf '%s\n' "${host}"
}

anytls_rand_port() {
  python3 - <<'PY'
import random
print(random.randint(20000, 50000))
PY
}

anytls_rand_password() {
  python3 - <<'PY'
import secrets, base64
raw = secrets.token_bytes(18)
print(base64.urlsafe_b64encode(raw).decode().rstrip('='))
PY
}

anytls_rand_short_id() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
}

anytls_meta_file_by_tag() {
  local tag="$1"
  mkdir -p "${INBOUND_META_DIR}"
  printf '%s/%s.json\n' "${INBOUND_META_DIR}" "${tag}"
}

save_anytls_meta() {
  local tag="$1"
  local mode="$2"                  # tls / reality
  local listen="$3"
  local listen_port="$4"
  local connect_host="$5"
  local user_name="$6"
  local password="$7"
  local server_name="$8"
  local cert_mode="$9"
  local certificate_path="${10}"
  local key_path="${11}"
  local reality_public_key="${12}"
  local reality_private_key="${13}"
  local reality_short_id="${14}"
  local handshake_server="${15}"
  local handshake_port="${16}"
  local utls_fingerprint="${17:-chrome}"

  local meta_file
  meta_file="$(anytls_meta_file_by_tag "${tag}")"

  python3 - "${meta_file}" \
    "${tag}" "${mode}" "${listen}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${password}" "${server_name}" "${cert_mode}" \
    "${certificate_path}" "${key_path}" \
    "${reality_public_key}" "${reality_private_key}" "${reality_short_id}" \
    "${handshake_server}" "${handshake_port}" "${utls_fingerprint}" <<'PY'
import json, sys

(
  path, tag, mode, listen, listen_port, connect_host,
  user_name, password, server_name, cert_mode,
  certificate_path, key_path,
  reality_public_key, reality_private_key, reality_short_id,
  handshake_server, handshake_port, utls_fingerprint
) = sys.argv[1:]

data = {
  "protocol": "anytls",
  "tag": tag,
  "mode": mode,
  "listen": listen,
  "listen_port": int(listen_port),
  "connect_host": connect_host,
  "user_name": user_name,
  "password": password,
  "server_name": server_name,
  "cert_mode": cert_mode,
  "certificate_path": certificate_path,
  "key_path": key_path,
  "reality_enabled": mode == "reality",
  "reality_public_key": reality_public_key,
  "reality_private_key": reality_private_key,
  "reality_short_id": reality_short_id,
  "handshake_server": handshake_server,
  "handshake_port": int(handshake_port) if handshake_port else 443,
  "utls_fingerprint": utls_fingerprint
}

with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, ensure_ascii=False, indent=2)
PY
}

generate_anytls_self_signed_cert() {
  local tag="$1"
  local sni="$2"

  mkdir -p "${CONFIG_DIR}/certs"

  local crt="${CONFIG_DIR}/certs/${tag}.crt"
  local key="${CONFIG_DIR}/certs/${tag}.key"

  if ! has_cmd openssl; then
    err "缺少 openssl，无法生成自签证书"
    return 1
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${crt}" \
    -days 3650 \
    -subj "/CN=${sni}" >/dev/null 2>&1 || return 1

  printf '%s|%s\n' "${crt}" "${key}"
}

generate_anytls_reality_keypair() {
  local out priv pub

  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法生成 Reality 密钥"
    return 1
  fi

  out="$(sing-box generate reality-keypair 2>/dev/null)" || return 1
  priv="$(printf '%s\n' "${out}" | awk -F': ' '/Private/ {print $2; exit}')"
  pub="$(printf '%s\n' "${out}" | awk -F': ' '/Public/  {print $2; exit}')"

  if [ -z "${priv}" ] || [ -z "${pub}" ]; then
    return 1
  fi

  printf '%s|%s\n' "${priv}" "${pub}"
}

deploy_anytls_tls() {
  need_root

  local cert_mode="$1"  # 1=正式证书 2=自签证书
  local tag listen listen_port user_name password connect_host server_name
  local certificate_path="" key_path="" tmp_file

  tag="$(prompt_default "请输入 AnyTLS 实例标签" "anytls-$(date +%H%M%S)")"
  listen="$(prompt_default "请输入监听地址" "0.0.0.0")"
  listen_port="$(prompt_default "请输入 AnyTLS 监听端口" "$(anytls_rand_port)")"
  user_name="$(prompt_default "请输入 AnyTLS 用户备注" "anytls-user1")"
  password="$(prompt_default "请输入 AnyTLS 密码" "$(anytls_rand_password)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "$(detect_default_connect_host)")"
  server_name="$(prompt_required "请输入客户端 server_name / SNI（证书域名）")"

  if [ "${cert_mode}" = "1" ]; then
    certificate_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
    key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
  else
    local cert_pair
    cert_pair="$(generate_anytls_self_signed_cert "${tag}" "${server_name}")" || {
      err "生成自签证书失败"
      pause_enter
      return 1
    }
    certificate_path="${cert_pair%%|*}"
    key_path="${cert_pair##*|}"
  fi

  tmp_file="${TMP_DIR}/config.anytls.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" "${listen}" "${listen_port}" "${user_name}" "${password}" "${certificate_path}" "${key_path}" <<'PY'
import json, sys

cfg_path, tag, listen, listen_port, user_name, password, certificate_path, key_path = sys.argv[1:]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

obj = {
  "type": "anytls",
  "tag": tag,
  "listen": listen,
  "listen_port": int(listen_port),
  "users": [
    {
      "name": user_name,
      "password": password
    }
  ],
  "tls": {
    "enabled": True,
    "certificate_path": certificate_path,
    "key_path": key_path
  }
}

replaced = False
for i, ib in enumerate(inbounds):
  if ib.get("tag") == tag:
    inbounds[i] = obj
    replaced = True
    break

if not replaced:
  inbounds.append(obj)

with open(cfg_path, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 AnyTLS 配置失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_anytls_meta \
    "${tag}" "tls" "${listen}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${password}" "${server_name}" "${cert_mode}" \
    "${certificate_path}" "${key_path}" \
    "" "" "" "" "443" "chrome"

  ok "AnyTLS 部署完成"
  echo
  echo "------ 客户端关键参数 ------"
  echo "实例标签    : ${tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "密码        : ${password}"
  echo "SNI         : ${server_name}"
  echo "证书模式    : $([ "${cert_mode}" = "1" ] && echo 正式证书 || echo 自签证书)"
  echo "----------------------------"
  echo

  local meta_file
  meta_file="$(anytls_meta_file_by_tag "${tag}")"
  echo "------ AnyTLS 客户端 sing-box JSON ------"
  build_anytls_singbox_json_from_meta "${meta_file}" || true
  echo "----------------------------------------"
  echo

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    local backend
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "tcp"; then
          ok "已放行 ${listen_port}/tcp"
        else
          err "放行 ${listen_port}/tcp 失败"
        fi
      fi
    fi
  fi

  pause_enter
}

deploy_anytls_reality() {
  need_root

  local tag listen listen_port user_name password connect_host server_name
  local handshake_server handshake_port short_id keypair private_key public_key tmp_file

  tag="$(prompt_default "请输入 AnyTLS 实例标签" "anytls-$(date +%H%M%S)")"
  listen="$(prompt_default "请输入监听地址" "0.0.0.0")"
  listen_port="$(prompt_default "请输入 AnyTLS 监听端口" "$(anytls_rand_port)")"
  user_name="$(prompt_default "请输入 AnyTLS 用户备注" "anytls-user1")"
  password="$(prompt_default "请输入 AnyTLS 密码" "$(anytls_rand_password)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "$(detect_default_connect_host)")"
  server_name="$(prompt_required "请输入客户端 server_name / SNI")"
  handshake_server="$(prompt_default "请输入 Reality 握手域名" "${server_name}")"
  handshake_port="$(prompt_default "请输入 Reality 握手端口" "443")"
  short_id="$(prompt_default "请输入 Reality short_id" "$(anytls_rand_short_id)")"

  keypair="$(generate_anytls_reality_keypair)" || {
    err "生成 Reality 密钥失败"
    pause_enter
    return 1
  }
  private_key="${keypair%%|*}"
  public_key="${keypair##*|}"

  tmp_file="${TMP_DIR}/config.anytls.reality.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" "${listen}" "${listen_port}" "${user_name}" "${password}" "${handshake_server}" "${handshake_port}" "${private_key}" "${short_id}" <<'PY'
import json, sys

(
  cfg_path, tag, listen, listen_port, user_name, password,
  handshake_server, handshake_port, private_key, short_id
) = sys.argv[1:]

cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

obj = {
  "type": "anytls",
  "tag": tag,
  "listen": listen,
  "listen_port": int(listen_port),
  "users": [
    {
      "name": user_name,
      "password": password
    }
  ],
  "tls": {
    "enabled": True,
    "reality": {
      "enabled": True,
      "handshake": {
        "server": handshake_server,
        "server_port": int(handshake_port)
      },
      "private_key": private_key,
      "short_id": [short_id]
    }
  }
}

replaced = False
for i, ib in enumerate(inbounds):
  if ib.get("tag") == tag:
    inbounds[i] = obj
    replaced = True
    break

if not replaced:
  inbounds.append(obj)

with open(cfg_path, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 AnyTLS + Reality 配置失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_anytls_meta \
    "${tag}" "reality" "${listen}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${password}" "${server_name}" "0" \
    "" "" \
    "${public_key}" "${private_key}" "${short_id}" "${handshake_server}" "${handshake_port}" "chrome"

  ok "AnyTLS + Reality 部署完成"
  echo
  echo "------ 客户端关键参数 ------"
  echo "实例标签    : ${tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "密码        : ${password}"
  echo "SNI         : ${server_name}"
  echo "Public Key  : ${public_key}"
  echo "Short ID    : ${short_id}"
  echo "握手域名    : ${handshake_server}:${handshake_port}"
  echo "uTLS 指纹   : chrome"
  echo "----------------------------"
  echo

  local meta_file
  meta_file="$(anytls_meta_file_by_tag "${tag}")"
  echo "------ AnyTLS + Reality 客户端 sing-box JSON ------"
  build_anytls_singbox_json_from_meta "${meta_file}" || true
  echo "--------------------------------------------------"
  echo

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    local backend
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "tcp"; then
          ok "已放行 ${listen_port}/tcp"
        else
          err "放行 ${listen_port}/tcp 失败"
        fi
      fi
    fi
  fi

  pause_enter
}

menu_deploy_anytls() {
  while true; do
    clear
    echo "======================================"
    echo "             AnyTLS 入站"
    echo "======================================"
    echo "1. AnyTLS（正式证书）"
    echo "2. AnyTLS（自签证书）"
    echo "3. AnyTLS + Reality"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) deploy_anytls_tls "1" ;;
      2) deploy_anytls_tls "2" ;;
      3) deploy_anytls_reality ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

vless_meta_file_by_tag() {
  local tag="$1"
  mkdir -p "${INBOUND_META_DIR}"
  printf '%s/%s.json\n' "${INBOUND_META_DIR}" "${tag}"
}

save_vless_meta() {
  local tag="$1"
  local mode="$2"                  # tls / reality
  local listen="$3"
  local listen_port="$4"
  local connect_host="$5"
  local user_name="$6"
  local user_uuid="$7"
  local flow="$8"
  local server_name="$9"
  local cert_mode="${10}"
  local certificate_path="${11}"
  local key_path="${12}"
  local reality_public_key="${13}"
  local reality_private_key="${14}"
  local reality_short_id="${15}"
  local handshake_server="${16}"
  local handshake_port="${17}"

  local meta_file
  meta_file="$(vless_meta_file_by_tag "${tag}")"

  python3 - "${meta_file}" \
    "${tag}" "${mode}" "${listen}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${user_uuid}" "${flow}" "${server_name}" "${cert_mode}" \
    "${certificate_path}" "${key_path}" \
    "${reality_public_key}" "${reality_private_key}" "${reality_short_id}" \
    "${handshake_server}" "${handshake_port}" <<'PY'
import json, sys

(
  path, tag, mode, listen, listen_port, connect_host,
  user_name, user_uuid, flow, server_name, cert_mode,
  certificate_path, key_path,
  reality_public_key, reality_private_key, reality_short_id,
  handshake_server, handshake_port
) = sys.argv[1:]

data = {
  "protocol": "vless",
  "tag": tag,
  "mode": mode,
  "listen": listen,
  "listen_port": int(listen_port),
  "connect_host": connect_host,
  "user_name": user_name,
  "user_uuid": user_uuid,
  "flow": flow,
  "server_name": server_name,
  "cert_mode": cert_mode,
  "certificate_path": certificate_path,
  "key_path": key_path,
  "reality_public_key": reality_public_key,
  "reality_private_key": reality_private_key,
  "reality_short_id": reality_short_id,
  "handshake_server": handshake_server,
  "handshake_port": int(handshake_port) if handshake_port else 443
}

with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, ensure_ascii=False, indent=2)
PY
}

generate_vless_self_signed_cert() {
  local tag="$1"
  local sni="$2"

  mkdir -p "${CONFIG_DIR}/certs"

  local crt="${CONFIG_DIR}/certs/${tag}.crt"
  local key="${CONFIG_DIR}/certs/${tag}.key"

  if ! has_cmd openssl; then
    err "缺少 openssl，无法生成自签证书"
    return 1
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${crt}" \
    -days 3650 \
    -subj "/CN=${sni}" >/dev/null 2>&1 || return 1

  printf '%s|%s\n' "${crt}" "${key}"
}

menu_deploy_vless() {
  while true; do
    clear
    echo "======================================"
    echo "              VLESS 入站"
    echo "======================================"
    echo "1. VLESS + TLS（正式证书）"
    echo "2. VLESS + TLS（自签证书）"
    echo "3. VLESS + Reality"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) deploy_vless_tls "1" ;;
      2) deploy_vless_tls "2" ;;
      3) deploy_vless_reality ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

deploy_vless_tls() {
  need_root

  local cert_mode="$1"   # 1=正式证书 2=自签证书
  local vless_tag listen listen_port user_name user_uuid connect_host server_name
  local certificate_path="" key_path="" tmp_file

  vless_tag="$(prompt_default "请输入 VLESS 实例标签" "vless-$(date +%H%M%S)")"
  listen="$(prompt_default "请输入监听地址" "0.0.0.0")"
  listen_port="$(prompt_default "请输入 VLESS 监听端口" "$(random_port)")"
  user_name="$(prompt_default "请输入 VLESS 用户备注" "vless-user1")"
  user_uuid="$(prompt_default "请输入 VLESS UUID" "$(gen_uuid)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "$(detect_default_connect_host)")"
  server_name="$(prompt_required "请输入客户端 server_name / SNI（证书域名）")"

  if [ "${cert_mode}" = "1" ]; then
    certificate_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
    key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
  else
    local cert_pair
    cert_pair="$(generate_vless_self_signed_cert "${vless_tag}" "${server_name}")" || {
      err "生成自签证书失败"
      pause_enter
      return 1
    }
    certificate_path="${cert_pair%%|*}"
    key_path="${cert_pair##*|}"
  fi

  tmp_file="${TMP_DIR}/config.vless.tls.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${vless_tag}" "${listen}" "${listen_port}" "${user_name}" "${user_uuid}" "${certificate_path}" "${key_path}" <<'PY'
import json, sys

cfg_path, tag, listen, listen_port, user_name, user_uuid, certificate_path, key_path = sys.argv[1:]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

obj = {
  "type": "vless",
  "tag": tag,
  "listen": listen,
  "listen_port": int(listen_port),
  "users": [
    {
      "name": user_name,
      "uuid": user_uuid
    }
  ],
  "tls": {
    "enabled": True,
    "certificate_path": certificate_path,
    "key_path": key_path
  }
}

for i, ib in enumerate(inbounds):
  if ib.get("tag") == tag:
    inbounds[i] = obj
    break
else:
  inbounds.append(obj)

with open(cfg_path, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 VLESS + TLS 配置失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  save_vless_meta \
    "${vless_tag}" "tls" "${listen}" "${listen_port}" "${connect_host}" \
    "${user_name}" "${user_uuid}" "" "${server_name}" "${cert_mode}" \
    "${certificate_path}" "${key_path}" \
    "" "" "" "" "443"

  ok "VLESS + TLS 部署完成"
  echo
  echo "------ 客户端关键参数 ------"
  echo "实例标签    : ${vless_tag}"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "UUID        : ${user_uuid}"
  echo "传输        : tcp"
  echo "TLS         : tls"
  echo "SNI         : ${server_name}"
  echo "备注        : ${user_name}"
  echo "----------------------------"
  echo

  local meta_file vless_uri
  meta_file="$(vless_meta_file_by_tag "${vless_tag}")"
  vless_uri="$(build_vless_uri_from_meta "${meta_file}" "${user_name}" "${user_uuid}" 2>/dev/null || true)"
  show_uri_and_qr "VLESS URI" "${vless_uri}"

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    local backend
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "tcp"; then
          ok "已放行 ${listen_port}/tcp"
        else
          err "放行 ${listen_port}/tcp 失败"
        fi
      fi
    fi
  fi

  pause_enter
}

menu_inbound_management() {
  while true; do
    clear
    echo "======================================"
    echo "              入站管理"
    echo "======================================"
    echo "1. 部署 VLESS"
    echo "2. 部署 VMess"
    echo "3. 部署 AnyTLS"
    echo "4. 部署 TUIC"
    echo "5. 部署 Hysteria2"
    echo "6. 查看入站实例"
    echo "7. 删除入站实例"
    echo "8. 导出配置"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-8]: " choice
    case "${choice:-}" in
      1) menu_deploy_vless ;;
      2) menu_deploy_vmess ;;
      3) menu_deploy_anytls ;;
      4) menu_deploy_tuic ;;
      5) menu_deploy_hysteria2 ;;
      6) show_current_inbounds ;;
      7) delete_inbound_instance ;;
      8) menu_export_client ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
