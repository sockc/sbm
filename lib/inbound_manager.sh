#!/usr/bin/env bash

# Inbound instance management extensions for SBM 0.2.6.x.
# Keeps protocol deployment code in inbound.sh while centralising runtime
# status, port conflict checks and safe edits here.

inbound_transport_for_type() {
  case "$1" in
    hysteria2|tuic) printf '%s\n' "udp" ;;
    *) printf '%s\n' "tcp" ;;
  esac
}

config_port_conflict() {
  local port="$1"
  local network="$2"
  local exclude_tag="${3:-}"

  [ -f "${CONFIG_DIR}/config.json" ] || return 1

  python3 - "${CONFIG_DIR}/config.json" "${port}" "${network}" "${exclude_tag}" <<'PY'
import json, sys

path, port, network, exclude_tag = sys.argv[1:]
port = int(port)

try:
    cfg = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    raise SystemExit(1)

def networks_for(ib):
    typ = str(ib.get("type", "") or "")
    if typ in ("hysteria2", "tuic"):
        return {"udp"}
    if typ == "direct":
        raw = str(ib.get("network", "") or "tcp,udp").lower()
        if raw in ("both", "tcp+udp", "tcp,udp", ""):
            return {"tcp", "udp"}
        return {x.strip() for x in raw.replace("+", ",").split(",") if x.strip()}
    return {"tcp"}

wanted = {"tcp", "udp"} if network in ("both", "tcp+udp") else {network}
for ib in cfg.get("inbounds", []):
    tag = str(ib.get("tag", "") or "")
    if exclude_tag and tag == exclude_tag:
        continue
    try:
        ib_port = int(ib.get("listen_port", 0) or 0)
    except Exception:
        continue
    if ib_port != port:
        continue
    if networks_for(ib) & wanted:
        typ = str(ib.get("type", "") or "unknown")
        print(f"{tag or '<未设置>'}\t{typ}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

system_port_conflict() {
  local port="$1"
  local network="$2"
  local exclude_tag="${3:-}"
  local proto output matches

  has_cmd ss || return 1

  for proto in tcp udp; do
    case "${network}" in
      tcp) [ "${proto}" = "tcp" ] || continue ;;
      udp) [ "${proto}" = "udp" ] || continue ;;
      both|tcp+udp) ;;
      *) continue ;;
    esac

    if [ "${proto}" = "tcp" ]; then
      output="$(ss -H -lntp 2>/dev/null || true)"
    else
      output="$(ss -H -lnup 2>/dev/null || true)"
    fi

    matches="$(printf '%s\n' "${output}" | grep -E ":${port}([[:space:]]|$)" || true)"
    [ -n "${matches}" ] || continue

    # When editing an existing instance, ignore only listeners owned by sing-box.
    if [ -n "${exclude_tag}" ]; then
      local external
      external="$(printf '%s\n' "${matches}" | grep -v 'sing-box' || true)"
      [ -z "${external}" ] && continue
      matches="${external}"
    fi

    printf '%s\t%s\n' "${proto}" "$(printf '%s\n' "${matches}" | head -n1)"
    return 0
  done

  return 1
}

check_port_available() {
  local port="$1"
  local network="$2"
  local exclude_tag="${3:-}"
  local conflict

  conflict="$(config_port_conflict "${port}" "${network}" "${exclude_tag}" 2>/dev/null || true)"
  if [ -n "${conflict}" ]; then
    local ctag ctype
    IFS=$'\t' read -r ctag ctype <<<"${conflict}"
    err "端口 ${port}/${network} 已被 sing-box 入站占用：${ctag}（${ctype}）" >&2
    return 1
  fi

  conflict="$(system_port_conflict "${port}" "${network}" "${exclude_tag}" 2>/dev/null || true)"
  if [ -n "${conflict}" ]; then
    local proto detail
    IFS=$'\t' read -r proto detail <<<"${conflict}"
    err "端口 ${port}/${proto} 已被系统进程占用" >&2
    [ -n "${detail}" ] && echo "占用信息：${detail}" >&2
    return 1
  fi

  return 0
}

prompt_available_port() {
  local prompt="$1"
  local default_port="$2"
  local network="$3"
  local exclude_tag="${4:-}"
  local port

  while true; do
    port="$(prompt_port_default "${prompt}" "${default_port}")"
    if check_port_available "${port}" "${network}" "${exclude_tag}"; then
      printf '%s\n' "${port}"
      return 0
    fi
    echo "请更换端口。" >&2
  done
}

inbound_port_is_listening() {
  local network="$1"
  local port="$2"
  local output

  [ -n "${port}" ] || return 1
  has_cmd ss || return 2

  if [ "${network}" = "udp" ]; then
    output="$(ss -H -lnu 2>/dev/null || true)"
  else
    output="$(ss -H -lnt 2>/dev/null || true)"
  fi

  printf '%s\n' "${output}" | grep -Eq ":${port}([[:space:]]|$)"
}

managed_inbound_rows_v2() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
supported = {"vless", "hysteria2", "vmess", "tuic", "anytls"}

def label_for(ib):
    typ = str(ib.get("type", "") or "")
    tls = ib.get("tls", {}) or {}
    reality = (tls.get("reality", {}) or {}).get("enabled") is True
    if typ == "vless":
        return "VLESS Reality" if reality else ("VLESS TLS" if tls.get("enabled") else "VLESS")
    if typ == "hysteria2":
        return "Hysteria2"
    if typ == "vmess":
        return "VMess TLS" if tls.get("enabled") else "VMess"
    if typ == "tuic":
        return "TUIC"
    if typ == "anytls":
        return "AnyTLS Reality" if reality else "AnyTLS"
    return typ or "<未知>"

n = 0
for ib in cfg.get("inbounds", []):
    typ = str(ib.get("type", "") or "")
    tag = str(ib.get("tag", "") or "")
    if typ not in supported or not tag:
        continue

    n += 1
    listen = str(ib.get("listen", "") or "")
    port = str(ib.get("listen_port", "") or "")
    if ":" in listen and not listen.startswith("["):
        endpoint = f"[{listen}]:{port}" if port else f"[{listen}]"
    else:
        endpoint = f"{listen}:{port}" if port else (listen or "<空>")

    network = "udp" if typ in ("hysteria2", "tuic") else "tcp"
    print(f"{n}\t{tag}\t{typ}\t{label_for(ib)}\t{endpoint}\t{network}\t{port}")
PY
}

inbound_runtime_status() {
  local network="$1"
  local port="$2"
  local service_state="$3"
  local config_ok="$4"
  local rc

  if [ "${config_ok}" != "true" ]; then
    printf '%s\n' "配置异常"
    return 0
  fi
  if [ "${service_state}" != "active" ]; then
    printf '%s\n' "服务停止"
    return 0
  fi

  if inbound_port_is_listening "${network}" "${port}"; then
    rc=0
  else
    rc=$?
  fi

  if [ "${rc}" -eq 0 ]; then
    printf '%s\n' "正常"
  elif [ "${rc}" -eq 2 ]; then
    printf '%s\n' "未知"
  else
    printf '%s\n' "未监听"
  fi
}

show_managed_inbound_list() {
  local service_state="inactive"
  local config_ok="false"

  if command -v systemctl >/dev/null 2>&1; then
    service_state="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  fi

  if check_config_file "${CONFIG_DIR}/config.json" >/dev/null 2>&1; then
    config_ok="true"
  fi

  echo "当前入站实例："
  echo "编号 标签                     类型              监听地址                 状态"
  echo "--------------------------------------------------------------------------------------"

  local found=0
  while IFS=$'\t' read -r n tag _type label endpoint network port; do
    [ -z "${n}" ] && continue
    found=1
    local status
    status="$(inbound_runtime_status "${network}" "${port}" "${service_state}" "${config_ok}")"
    printf '%-4s %-24s %-17s %-24s %s\n' "${n}" "${tag}" "${label}" "${endpoint}" "${status}"
  done < <(managed_inbound_rows_v2)

  if [ "${found}" -eq 0 ]; then
    echo "<暂无 SBM 管理的入站实例>"
  fi

  echo "--------------------------------------------------------------------------------------"
  echo "sing-box 服务：${service_state:-unknown}"
}

get_inbound_edit_info() {
  local tag="$1"

  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
ib = next((x for x in cfg.get("inbounds", []) if str(x.get("tag", "") or "") == tag), None)
if ib is None:
    raise SystemExit(1)

typ = str(ib.get("type", "") or "")
tls = ib.get("tls", {}) or {}
reality = tls.get("reality", {}) or {}
handshake = reality.get("handshake", {}) or {}
users = ib.get("users", [])

print(typ)
print(str(ib.get("listen_port", "") or ""))
print("true" if tls.get("enabled") is True else "false")
print("true" if reality.get("enabled") is True else "false")
print(str(tls.get("server_name", "") or ""))
print(str(tls.get("certificate_path", "") or ""))
print(str(tls.get("key_path", "") or ""))
print(str(handshake.get("server", "") or ""))
print(str(handshake.get("server_port", "") or ""))
print(str(len(users) if isinstance(users, list) else 0))
PY
}

get_inbound_meta_field() {
  local tag="$1"
  local field="$2"
  local meta_file

  meta_file="$(inbound_meta_file_by_tag "${tag}")"
  [ -f "${meta_file}" ] || return 1

  python3 - "${meta_file}" "${field}" <<'PY'
import json, sys

try:
    data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    raise SystemExit(1)

value = data.get(sys.argv[2], "")
if value is None:
    value = ""
print(value)
PY
}

show_inbound_instance_detail() {
  local tag="$1"
  local service_state="inactive" config_ok="false"

  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
ib = next((x for x in cfg.get("inbounds", []) if str(x.get("tag", "") or "") == tag), None)
if ib is None:
    raise SystemExit(1)

typ = str(ib.get("type", "") or "")
listen = str(ib.get("listen", "") or "")
port = str(ib.get("listen_port", "") or "")
endpoint = f"[{listen}]:{port}" if ":" in listen and not listen.startswith("[") else f"{listen}:{port}"

tls = ib.get("tls", {}) or {}
reality = (tls.get("reality", {}) or {}).get("enabled") is True
if typ == "vless":
    label = "VLESS Reality" if reality else ("VLESS TLS" if tls.get("enabled") else "VLESS")
elif typ == "hysteria2":
    label = "Hysteria2"
elif typ == "vmess":
    label = "VMess TLS" if tls.get("enabled") else "VMess"
elif typ == "tuic":
    label = "TUIC"
elif typ == "anytls":
    label = "AnyTLS Reality" if reality else "AnyTLS"
else:
    label = typ

users = ib.get("users", [])
auth_count = len(users) if isinstance(users, list) else 0
server_name = str(tls.get("server_name", "") or "")
transport = ib.get("transport", {}) or {}
transport_type = str(transport.get("type", "") or "")

print(f"实例标签 : {tag}")
print(f"协议类型 : {label}")
print(f"监听地址 : {endpoint}")
print(f"认证数量 : {auth_count}")
if transport_type:
    print(f"传输方式 : {transport_type}")
if server_name:
    print(f"SNI      : {server_name}")
PY

  local meta_file sni
  meta_file="$(inbound_meta_file_by_tag "${tag}")"
  if [ -f "${meta_file}" ]; then
    echo "客户端信息: 已保存"
    sni="$(get_inbound_meta_field "${tag}" "server_name" 2>/dev/null || true)"
    [ -n "${sni}" ] && echo "客户端 SNI: ${sni}"
  else
    echo "客户端信息: 缺少元数据"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    service_state="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  fi
  if check_config_file "${CONFIG_DIR}/config.json" >/dev/null 2>&1; then
    config_ok="true"
  fi

  local typ port network status
  mapfile -t _edit_info < <(get_inbound_edit_info "${tag}")
  typ="${_edit_info[0]:-}"
  port="${_edit_info[1]:-}"
  network="$(inbound_transport_for_type "${typ}")"
  status="$(inbound_runtime_status "${network}" "${port}" "${service_state}" "${config_ok}")"
  echo "运行状态 : ${status}"
}

apply_inbound_edit() {
  local tag="$1"
  local operation="$2"
  local value1="${3:-}"
  local value2="${4:-}"
  local value3="${5:-}"

  local tmp_cfg meta_file tmp_meta=""
  tmp_cfg="${TMP_DIR}/config.edit-inbound.json"
  meta_file="$(inbound_meta_file_by_tag "${tag}")"

  cp -f "${CONFIG_DIR}/config.json" "${tmp_cfg}" || return 1
  if [ -f "${meta_file}" ]; then
    tmp_meta="${TMP_DIR}/meta.edit-inbound.json"
    cp -p "${meta_file}" "${tmp_meta}" || {
      rm -f -- "${tmp_cfg}"
      return 1
    }
  fi

  if ! python3 - "${tmp_cfg}" "${tmp_meta}" "${tag}" "${operation}" "${value1}" "${value2}" "${value3}" <<'PY'
import json, os, sys

cfg_path, meta_path, tag, op, v1, v2, v3 = sys.argv[1:]
cfg = json.load(open(cfg_path, "r", encoding="utf-8"))
ib = next((x for x in cfg.get("inbounds", []) if str(x.get("tag", "") or "") == tag), None)
if ib is None:
    raise SystemExit("未找到目标入站")

typ = str(ib.get("type", "") or "")
tls = ib.setdefault("tls", {}) if op in ("sni", "handshake", "reality_keys", "certificate") else (ib.get("tls", {}) or {})

meta = None
if meta_path and os.path.exists(meta_path):
    try:
        meta = json.load(open(meta_path, "r", encoding="utf-8"))
    except Exception:
        meta = None

if op == "port":
    ib["listen_port"] = int(v1)
    if meta is not None:
        meta["listen_port"] = int(v1)

elif op == "sni":
    if "server_name" in tls:
        tls["server_name"] = v1
    if meta is not None:
        meta["server_name"] = v1

elif op == "credential":
    users = ib.get("users", [])
    if not isinstance(users, list) or len(users) != 1:
        raise SystemExit("实例不是单凭证配置，为避免误伤旧多用户配置，已拒绝自动重生成")

    user = users[0]
    if typ in ("vless", "vmess", "tuic"):
        user["uuid"] = v1
        if meta is not None:
            if typ == "vless":
                meta["user_uuid"] = v1
                if "uuid" in meta:
                    meta["uuid"] = v1
            else:
                meta["uuid"] = v1
    elif typ in ("hysteria2", "anytls"):
        user["password"] = v1
        if meta is not None:
            meta["password"] = v1
    else:
        raise SystemExit("当前协议不支持重生成认证信息")

elif op == "handshake":
    reality = tls.get("reality", {}) or {}
    if reality.get("enabled") is not True:
        raise SystemExit("当前实例不是 Reality")
    handshake = reality.setdefault("handshake", {})
    handshake["server"] = v1
    handshake["server_port"] = int(v2)
    if meta is not None:
        meta["handshake_server"] = v1
        meta["handshake_port"] = int(v2)

elif op == "reality_keys":
    reality = tls.get("reality", {}) or {}
    if reality.get("enabled") is not True:
        raise SystemExit("当前实例不是 Reality")
    reality["private_key"] = v1
    reality["short_id"] = [v3]
    if meta is not None:
        meta["reality_private_key"] = v1
        meta["reality_public_key"] = v2
        meta["reality_short_id"] = v3
        if "private_key" in meta:
            meta["private_key"] = v1
        if "public_key" in meta:
            meta["public_key"] = v2
        if "short_id" in meta:
            meta["short_id"] = v3

elif op == "certificate":
    if tls.get("enabled") is not True:
        raise SystemExit("当前实例未启用 TLS")
    reality = tls.get("reality", {}) or {}
    if reality.get("enabled") is True:
        raise SystemExit("Reality 实例不使用证书路径")
    tls["certificate_path"] = v1
    tls["key_path"] = v2
    if meta is not None:
        meta["certificate_path"] = v1
        meta["key_path"] = v2

else:
    raise SystemExit("未知修改操作")

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)

if meta is not None:
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
PY
  then
    err "修改实例失败"
    rm -f -- "${tmp_cfg}" "${tmp_meta}"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_cfg}"; then
    err "修改后的配置校验失败，未写入正式配置"
    rm -f -- "${tmp_cfg}" "${tmp_meta}"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_cfg}"

  if ! restart_singbox_service; then
    err "服务重启失败；配置已尝试自动回滚，客户端元数据保持原样"
    rm -f -- "${tmp_cfg}" "${tmp_meta}"
    pause_enter
    return 1
  fi

  if [ -n "${tmp_meta}" ] && [ -f "${tmp_meta}" ]; then
    install -m 600 "${tmp_meta}" "${meta_file}"
  fi

  rm -f -- "${tmp_cfg}" "${tmp_meta}"
  ok "实例修改完成：${tag}"
  return 0
}

edit_inbound_port() {
  local tag="$1"
  local typ="$2"
  local current_port network new_port rc

  current_port="$(get_inbound_edit_info "${tag}" | sed -n '2p')"
  network="$(inbound_transport_for_type "${typ}")"
  new_port="$(prompt_available_port "请输入新的监听端口" "${current_port}" "${network}" "${tag}")" || return 1

  if [ "${new_port}" = "${current_port}" ]; then
    warn "端口没有变化"
    pause_enter
    return 0
  fi

  echo "监听端口：${current_port} -> ${new_port}/${network}"
  if ! confirm_default_yes "确认修改并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "port" "${new_port}"
  rc=$?
  [ "${rc}" -eq 0 ] && pause_enter
  return "${rc}"
}

edit_inbound_sni() {
  local tag="$1"
  local current_sni new_sni rc

  current_sni="$(get_inbound_meta_field "${tag}" "server_name" 2>/dev/null || true)"
  if [ -z "${current_sni}" ]; then
    current_sni="$(get_inbound_edit_info "${tag}" | sed -n '5p')"
  fi

  new_sni="$(prompt_default "请输入新的客户端 SNI" "${current_sni}")"
  if [ -z "${new_sni}" ]; then
    err "SNI 不能为空"
    pause_enter
    return 1
  fi

  if [ "${new_sni}" = "${current_sni}" ]; then
    warn "SNI 没有变化"
    pause_enter
    return 0
  fi

  warn "如果当前使用 TLS 证书，请确认新 SNI 与证书匹配。"
  if ! confirm_default_yes "确认修改 SNI 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "sni" "${new_sni}"
  rc=$?
  [ "${rc}" -eq 0 ] && pause_enter
  return "${rc}"
}

regenerate_inbound_credential() {
  local tag="$1"
  local typ="$2"
  local value label rc

  case "${typ}" in
    vless|vmess|tuic)
      value="$(gen_uuid_value)"
      label="UUID"
      ;;
    hysteria2)
      value="$(gen_password)"
      label="密码"
      ;;
    anytls)
      value="$(anytls_rand_password)"
      label="密码"
      ;;
    *)
      err "当前协议不支持重生成认证信息"
      pause_enter
      return 1
      ;;
  esac

  echo "将为实例 ${tag} 重新生成${label}。"
  warn "修改后，使用旧认证信息的客户端会立即失效。"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "credential" "${value}"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo
    echo "新的${label}：${value}"
    echo "请重新导出客户端配置。"
    pause_enter
  fi
  return "${rc}"
}

edit_reality_handshake() {
  local tag="$1"
  local current_host current_port new_host new_port rc
  mapfile -t _edit_info < <(get_inbound_edit_info "${tag}")
  current_host="${_edit_info[7]:-}"
  current_port="${_edit_info[8]:-443}"

  new_host="$(prompt_default "请输入 Reality 握手目标域名" "${current_host}")"
  if [ -z "${new_host}" ]; then
    err "握手目标不能为空"
    pause_enter
    return 1
  fi
  new_port="$(prompt_port_default "请输入 Reality 握手目标端口" "${current_port}")"

  if ! confirm_default_yes "确认修改 Reality 握手目标吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "handshake" "${new_host}" "${new_port}"
  rc=$?
  [ "${rc}" -eq 0 ] && pause_enter
  return "${rc}"
}

regenerate_reality_keys() {
  local tag="$1"
  local pair private_key public_key short_id rc

  pair="$(gen_reality_keypair)" || {
    pause_enter
    return 1
  }
  private_key="${pair%%|*}"
  public_key="${pair##*|}"
  short_id="$(gen_short_id)"

  warn "重新生成 Reality 密钥后，现有客户端配置会立即失效。"
  if ! confirm_default_no "确认重新生成 Reality 密钥和 Short ID 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "reality_keys" "${private_key}" "${public_key}" "${short_id}"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo
    echo "新的 Public Key : ${public_key}"
    echo "新的 Short ID   : ${short_id}"
    echo "请重新导出客户端配置。"
    pause_enter
  fi
  return "${rc}"
}

edit_inbound_certificate() {
  local tag="$1"
  local current_cert current_key new_cert new_key rc
  mapfile -t _edit_info < <(get_inbound_edit_info "${tag}")
  current_cert="${_edit_info[5]:-}"
  current_key="${_edit_info[6]:-}"

  new_cert="$(prompt_default "请输入新的 certificate_path" "${current_cert}")"
  new_key="$(prompt_default "请输入新的 key_path" "${current_key}")"

  if [ ! -f "${new_cert}" ]; then
    err "证书文件不存在：${new_cert}"
    pause_enter
    return 1
  fi
  if [ ! -f "${new_key}" ]; then
    err "私钥文件不存在：${new_key}"
    pause_enter
    return 1
  fi

  if ! confirm_default_yes "确认替换证书路径并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_inbound_edit "${tag}" "certificate" "${new_cert}" "${new_key}"
  rc=$?
  [ "${rc}" -eq 0 ] && pause_enter
  return "${rc}"
}

menu_modify_inbound_instance() {
  local tag="$1"
  local typ="$2"

  while true; do
    local tls_enabled reality_enabled credential_label
    mapfile -t _edit_info < <(get_inbound_edit_info "${tag}") || {
      err "实例已不存在：${tag}"
      pause_enter
      return
    }
    tls_enabled="${_edit_info[2]:-false}"
    reality_enabled="${_edit_info[3]:-false}"

    case "${typ}" in
      vless|vmess|tuic) credential_label="重新生成 UUID" ;;
      hysteria2|anytls) credential_label="重新生成密码" ;;
      *) credential_label="重新生成认证信息" ;;
    esac

    clear
    echo "======================================"
    echo "              修改实例"
    echo "======================================"
    echo "实例：${tag}"
    echo
    echo "1. 修改监听端口"
    echo "2. ${credential_label}"
    if [ "${tls_enabled}" = "true" ]; then
      echo "3. 修改客户端 SNI"
    fi
    if [ "${reality_enabled}" = "true" ]; then
      echo "4. 修改 Reality 握手目标"
      echo "5. 重新生成 Reality 密钥"
    elif [ "${tls_enabled}" = "true" ]; then
      echo "4. 修改 TLS 证书路径"
    fi
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择: " choice
    case "${choice:-}" in
      1) edit_inbound_port "${tag}" "${typ}" ;;
      2) regenerate_inbound_credential "${tag}" "${typ}" ;;
      3)
        if [ "${tls_enabled}" = "true" ]; then
          edit_inbound_sni "${tag}"
        else
          echo "无效选项"; sleep 1
        fi
        ;;
      4)
        if [ "${reality_enabled}" = "true" ]; then
          edit_reality_handshake "${tag}"
        elif [ "${tls_enabled}" = "true" ]; then
          edit_inbound_certificate "${tag}"
        else
          echo "无效选项"; sleep 1
        fi
        ;;
      5)
        if [ "${reality_enabled}" = "true" ]; then
          regenerate_reality_keys "${tag}"
        else
          echo "无效选项"; sleep 1
        fi
        ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

# Override the 0.2.5 selected-instance menu. Multi-user compatibility remains
# readable in config/export code, but it is no longer exposed as a normal UI.
menu_inbound_instance_detail() {
  local tag="$1"
  local typ="$2"

  while true; do
    clear
    echo "======================================"
    echo "            入站实例管理"
    echo "======================================"
    show_inbound_instance_detail "${tag}" || {
      err "实例已不存在：${tag}"
      pause_enter
      return
    }
    echo "--------------------------------------"
    echo "1. 查看详情"
    echo "2. 导出客户端配置"
    echo "3. 修改实例"
    echo "4. 删除实例"
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1)
        clear
        echo "======================================"
        echo "              实例详情"
        echo "======================================"
        show_inbound_instance_detail "${tag}"
        pause_enter
        ;;
      2)
        export_inbound_instance_by_tag "${tag}" "${typ}"
        ;;
      3)
        menu_modify_inbound_instance "${tag}" "${typ}"
        ;;
      4)
        delete_inbound_instance_by_tag "${tag}"
        return
        ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
