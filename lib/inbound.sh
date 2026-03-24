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

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP"

  reality_tag="$(prompt_default "请输入 Reality 实例标签" "$(next_inbound_tag_by_prefix "reality")")"
  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_listen_port)"
  user_name="$(prompt_default "请输入用户备注" "${reality_tag}")"
  user_uuid="$(prompt_default "请输入 UUID" "$(gen_uuid_value)")"
  server_name="$(prompt_default "请输入伪装域名 server_name" "www.cloudflare.com")"
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

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == reality_tag:
        inbounds[i] = reality_obj
        replaced = True
        break

if not replaced:
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

  save_reality_meta \
    "${reality_tag}" "${connect_host}" "${listen_port}" "${user_name}" "${user_uuid}" \
    "${flow}" "${server_name}" "${handshake_server}" "${handshake_port}" \
    "${public_key}" "${private_key}" "${short_id}" "${tcp_fast_open}"

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
    tag = ib.get("tag", "")
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

print(inbounds[idx - 1].get("tag", ""))
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

  local idx tag tmp_file meta_file
  idx="$(prompt_required "请输入要删除的入站编号")"
  tag="$(get_inbound_tag_by_index "${idx}")" || {
    err "编号无效"
    pause_enter
    return 1
  }

  echo "准备删除入站实例：${tag}"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.delete-inbound.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" <<'PY'
import json, sys

path_cfg, target_tag = sys.argv[1], sys.argv[2]
cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.get("inbounds", [])

new_inbounds = [ib for ib in inbounds if ib.get("tag") != target_tag]
if len(new_inbounds) == len(inbounds):
    raise SystemExit(1)

cfg["inbounds"] = new_inbounds

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

  meta_file="$(inbound_meta_file_by_tag "${tag}")"
  rm -f "${meta_file}"
  delete_legacy_inbound_meta_by_tag "${tag}"

  ok "已删除入站实例：${tag}"
  pause_enter
}

save_hy2_meta() {
  local connect_host="$1"
  local listen_port="$2"
  local user_name="$3"
  local password="$4"
  local server_name="$5"
  local obfs_password="$6"
  local up_mbps="$7"
  local down_mbps="$8"
  local cert_mode="$9"

  cat > "${BASE_DIR}/hy2-meta.json" <<JSON
{
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

  chmod 600 "${BASE_DIR}/hy2-meta.json" 2>/dev/null || true
}

deploy_hysteria2() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"

  local listen_addr listen_port user_name password
  local cert_path key_path connect_host server_name
  local up_mbps down_mbps obfs_password use_obfs
  local cert_mode default_host tmp_file backend

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_port_default "请输入 Hysteria2 监听端口" "8443")"
  user_name="$(prompt_default "请输入 Hysteria2 用户备注" "hy2-user1")"
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
    local cert_pair
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
    "${listen_addr}" "${listen_port}" "${user_name}" "${password}" \
    "${cert_path}" "${key_path}" "${up_mbps}" "${down_mbps}" \
    "${use_obfs}" "${obfs_password}" <<'PY'
import json, sys

(
    path, listen_addr, listen_port, user_name, password,
    cert_path, key_path, up_mbps, down_mbps,
    use_obfs, obfs_password
) = sys.argv[1:]

cfg = json.load(open(path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

hy2_obj = {
    "type": "hysteria2",
    "tag": "hy2-in",
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
    if ib.get("tag") == "hy2-in":
        inbounds[i] = hy2_obj
        replaced = True
        break

if not replaced:
    inbounds.append(hy2_obj)

with open(path, 'w', encoding='utf-8') as f:
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

  save_hy2_meta "${connect_host}" "${listen_port}" "${user_name}" "${password}" "${server_name}" "${obfs_password}" "${up_mbps}" "${down_mbps}" "${cert_mode}"
  
  ok "Hysteria2 部署完成"
  echo
  echo "------ Hysteria2 客户端关键参数 ------"
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

  pause_enter
}

menu_deploy_vmess() {
  deploy_vmess
}

save_tuic_meta() {
  local connect_host="$1"
  local listen_port="$2"
  local user_name="$3"
  local uuid="$4"
  local password="$5"
  local server_name="$6"
  local congestion_control="$7"
  local zero_rtt_handshake="$8"
  local heartbeat="$9"
  local cert_mode="${10}"

  cat > "${BASE_DIR}/tuic-meta.json" <<JSON
{
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

  chmod 600 "${BASE_DIR}/tuic-meta.json" 2>/dev/null || true
}

deploy_tuic() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"

  local listen_addr listen_port user_name uuid password
  local connect_host server_name cert_path key_path cert_mode
  local congestion_control zero_rtt_choice zero_rtt_handshake
  local heartbeat default_host tmp_file backend cert_pair

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_port_default "请输入 TUIC 监听端口" "443")"
  user_name="$(prompt_default "请输入 TUIC 用户备注" "tuic-user1")"
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
    "${listen_addr}" "${listen_port}" "${user_name}" "${uuid}" "${password}" \
    "${cert_path}" "${key_path}" "${congestion_control}" "${zero_rtt_handshake}" "${heartbeat}" <<'PY'
import json, sys

(
    path_cfg, listen_addr, listen_port, user_name, uuid, password,
    cert_path, key_path, congestion_control, zero_rtt_handshake, heartbeat
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

tuic_obj = {
    "type": "tuic",
    "tag": "tuic-in",
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
    if ib.get("tag") == "tuic-in":
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

  save_tuic_meta "${connect_host}" "${listen_port}" "${user_name}" "${uuid}" "${password}" "${server_name}" "${congestion_control}" "${zero_rtt_handshake}" "${heartbeat}" "${cert_mode}"

  ok "TUIC 部署完成"
  echo
  echo "------ TUIC 客户端关键参数 ------"
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

  pause_enter
}

menu_deploy_tuic() {
  deploy_tuic
}

menu_inbound_management() {
  while true; do
    clear
    echo "======================================"
    echo "              入站管理"
    echo "======================================"
    echo "1. 部署/重装 VLESS + Reality"
    echo "2. 部署/重装 Hysteria2"
    echo "3. 部署/重装 VMess"
    echo "4. 部署/重装 TUIC"
    echo "5. 查看当前入站实例"
    echo "6. 删除指定入站实例"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) menu_deploy_vless_reality ;;
      2) menu_deploy_hysteria2 ;;
      3) menu_deploy_vmess ;;
      4) menu_deploy_tuic ;;
      5) show_current_inbounds ;;
      6) delete_inbound_instance ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
