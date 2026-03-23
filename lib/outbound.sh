#!/usr/bin/env bash

require_outbound_manage_env() {
  require_config_file || return 1
  require_python3 || return 1
}

prompt_outbound_port() {
  local port
  while true; do
    port="$(prompt_default "请输入上游端口" "443")"
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

default_next_outbound_tag() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys, re

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
nums = []

for ob in cfg.get("outbounds", []):
    tag = ob.get("tag", "")
    m = re.fullmatch(r"proxy(\d+)", tag)
    if m:
        nums.append(int(m.group(1)))

n = 1
while n in nums:
    n += 1

print(f"proxy{n}")
PY
}

list_vmess_outbounds_rows() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
final = cfg.get("route", {}).get("final", "direct")

rows = []
for ob in cfg.get("outbounds", []):
    if ob.get("type") != "vmess":
        continue
    rows.append({
        "tag": ob.get("tag", ""),
        "server": ob.get("server", ""),
        "server_port": ob.get("server_port", ""),
        "security": ob.get("security", ""),
        "is_default": "*" if ob.get("tag") == final else ""
    })

for i, row in enumerate(rows, 1):
    print(f"{i}\t{row['tag']}\t{row['server']}\t{row['server_port']}\t{row['security']}\t{row['is_default']}")
PY
}

show_vmess_outbounds() {
  require_outbound_manage_env || return 1

  local found=0
  local current_final
  current_final="$(python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
print(cfg.get("route", {}).get("final", "direct"))
PY
)"

  echo "当前默认出站: ${current_final}"
  echo "编号 标签            服务器               端口    加密        默认"
  echo "------------------------------------------------------------------"

  while IFS=$'\t' read -r idx tag server port security mark; do
    [ -z "${idx}" ] && continue
    found=1
    printf '%-4s %-15s %-20s %-7s %-10s %s\n' "$idx" "$tag" "$server" "$port" "$security" "$mark"
  done < <(list_vmess_outbounds_rows)

  if [ "$found" -eq 0 ]; then
    echo "暂无 VMess 上游"
  fi

  echo "------------------------------------------------------------------"
}

get_vmess_outbound_tag_by_index() {
  local idx="$1"
  python3 - "${CONFIG_DIR}/config.json" "$idx" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = int(sys.argv[2])

items = [ob for ob in cfg.get("outbounds", []) if ob.get("type") == "vmess"]

if idx < 1 or idx > len(items):
    print("索引越界", file=sys.stderr)
    raise SystemExit(1)

print(items[idx - 1].get("tag", ""))
PY
}

add_vmess_outbound() {
  require_outbound_manage_env || return 1
  mkdir -p "${TMP_DIR}"

  local tag server server_port uuid security alter_id network set_default tmp_file
  local use_tls insecure server_name packet_encoding

  tag="$(prompt_default "请输入上游标签" "$(default_next_outbound_tag)")"
  server="$(prompt_required "请输入上游服务器地址")"
  server_port="$(prompt_outbound_port)"
  uuid="$(prompt_required "请输入上游 UUID")"
  security="$(prompt_default "请输入 VMess security" "none")"
  alter_id="$(prompt_default "请输入 alter_id" "0")"
  network="$(prompt_default "请输入 network" "tcp")"

  if confirm_default_no "启用 TLS 吗？"; then
    use_tls="true"
    server_name="$(prompt_default "请输入 TLS server_name" "$server")"
    if confirm_default_no "允许不校验证书 insecure 吗？"; then
      insecure="true"
    else
      insecure="false"
    fi
  else
    use_tls="false"
    server_name=""
    insecure="false"
  fi

  if [ "$network" = "udp" ]; then
    packet_encoding="$(prompt_default "请输入 packet_encoding" "xudp")"
  else
    packet_encoding=""
  fi

  if confirm_default_yes "设为默认出站吗？"; then
    set_default="true"
  else
    set_default="false"
  fi

  echo
  echo "========== 上游预览 =========="
  echo "标签            : ${tag}"
  echo "服务器          : ${server}"
  echo "端口            : ${server_port}"
  echo "UUID            : ${uuid}"
  echo "security        : ${security}"
  echo "alter_id        : ${alter_id}"
  echo "network         : ${network}"
  echo "TLS             : ${use_tls}"
  [ "$use_tls" = "true" ] && echo "server_name     : ${server_name}"
  [ "$use_tls" = "true" ] && echo "insecure        : ${insecure}"
  [ -n "$packet_encoding" ] && echo "packet_encoding : ${packet_encoding}"
  echo "设为默认出站    : ${set_default}"
  echo "=============================="
  echo

  if ! confirm_default_yes "确认添加该 VMess 上游吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.add-vmess-outbound.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$tag" "$server" "$server_port" "$uuid" "$security" "$alter_id" "$network" "$use_tls" "$server_name" "$insecure" "$packet_encoding" "$set_default" <<'PY'
import json, sys

(
    path, tag, server, server_port, uuid, security, alter_id, network,
    use_tls, server_name, insecure, packet_encoding, set_default
) = sys.argv[1:]

server_port = int(server_port)
alter_id = int(alter_id)
use_tls = (use_tls == "true")
insecure = (insecure == "true")
set_default = (set_default == "true")

cfg = json.load(open(path, 'r', encoding='utf-8'))
outbounds = cfg.setdefault("outbounds", [])

for ob in outbounds:
    if ob.get("tag") == tag:
        print(f"出站标签已存在: {tag}", file=sys.stderr)
        raise SystemExit(1)

new_ob = {
    "type": "vmess",
    "tag": tag,
    "server": server,
    "server_port": server_port,
    "uuid": uuid,
    "security": security,
    "alter_id": alter_id,
    "network": network
}

if use_tls:
    new_ob["tls"] = {
        "enabled": True,
        "server_name": server_name,
        "insecure": insecure
    }

if packet_encoding:
    new_ob["packet_encoding"] = packet_encoding

outbounds.append(new_ob)

route = cfg.setdefault("route", {})
route.setdefault("final", "direct")
if set_default:
    route["final"] = tag

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "添加上游失败"
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
    err "服务重启失败"
    pause_enter
    return 1
  fi

  ok "VMess 上游添加成功：${tag}"
  pause_enter
}

delete_vmess_outbound() {
  require_outbound_manage_env || return 1
  mkdir -p "${TMP_DIR}"

  show_vmess_outbounds
  echo

  local idx tmp_file
  idx="$(prompt_required "请输入要删除的上游编号")"

  if ! confirm_default_no "确认删除该上游吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.del-vmess-outbound.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$idx" <<'PY'
import json, sys

path, idx = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(path, 'r', encoding='utf-8'))

outbounds = cfg.get("outbounds", [])
vmess_indexes = [i for i, ob in enumerate(outbounds) if ob.get("type") == "vmess"]

if idx < 1 or idx > len(vmess_indexes):
    print("编号超出范围", file=sys.stderr)
    raise SystemExit(1)

real_idx = vmess_indexes[idx - 1]
removed_tag = outbounds[real_idx].get("tag", "")
outbounds.pop(real_idx)

route = cfg.setdefault("route", {})
if route.get("final") == removed_tag:
    route["final"] = "direct"

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "删除上游失败"
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
    err "服务重启失败"
    pause_enter
    return 1
  fi

  ok "VMess 上游删除成功"
  pause_enter
}

set_default_outbound() {
  require_outbound_manage_env || return 1
  mkdir -p "${TMP_DIR}"

  show_vmess_outbounds
  echo
  echo "输入 0 表示切回 direct"
  echo

  local idx tag tmp_file
  idx="$(prompt_default "请输入要设为默认出站的编号" "0")"

  if [ "$idx" = "0" ]; then
    tag="direct"
  else
    tag="$(get_vmess_outbound_tag_by_index "$idx")" || {
      err "读取上游标签失败"
      pause_enter
      return 1
    }
  fi

  tmp_file="${TMP_DIR}/config.set-final.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$tag" <<'PY'
import json, sys

path, tag = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, 'r', encoding='utf-8'))
cfg.setdefault("route", {})["final"] = tag

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "设置默认出站失败"
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
    err "服务重启失败"
    pause_enter
    return 1
  fi

  ok "默认出站已切换为：${tag}"
  pause_enter
}

menu_outbound_management() {
  while true; do
    clear
    echo "======================================"
    echo "             出站管理"
    echo "======================================"
    echo "1. 添加 VMess 上游"
    echo "2. 删除 VMess 上游"
    echo "3. 查看上游"
    echo "4. 设置默认出站"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) add_vmess_outbound ;;
      2) delete_vmess_outbound ;;
      3) show_vmess_outbounds; pause_enter ;;
      4) set_default_outbound ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
