#!/usr/bin/env bash

REALM_BIN="${REALM_BIN:-/usr/local/bin/realm}"
REALM_ETC_DIR="${REALM_ETC_DIR:-/etc/realm}"
REALM_META_DIR="${REALM_META_DIR:-${BASE_DIR}/realm-meta}"

ensure_realm_dirs() {
  mkdir -p "${REALM_ETC_DIR}" "${REALM_META_DIR}" "${TMP_DIR}"
}

realm_tag_to_unit() {
  local tag="$1"
  printf 'realm-%s.service\n' "${tag}"
}

realm_tag_to_conf() {
  local tag="$1"
  printf '%s/%s.toml\n' "${REALM_ETC_DIR}" "${tag}"
}

realm_tag_to_meta() {
  local tag="$1"
  printf '%s/%s.json\n' "${REALM_META_DIR}" "${tag}"
}

prompt_realm_tag() {
  local tag default_tag="$1"
  while true; do
    tag="$(prompt_default "请输入 Realm 实例标签" "${default_tag}")"
    case "${tag}" in
      ''|*[!a-zA-Z0-9._-]*)
        echo "标签只能包含字母、数字、点、下划线、短横线"
        ;;
      *)
        printf '%s\n' "${tag}"
        return 0
        ;;
    esac
  done
}

next_realm_tag() {
  python3 - "${REALM_META_DIR}" <<'PY'
import os, re, sys
base = sys.argv[1]
nums = []
if os.path.isdir(base):
    for name in os.listdir(base):
        m = re.fullmatch(r"realm-(\d{3})\.json", name)
        if m:
            nums.append(int(m.group(1)))
n = 1
while n in nums:
    n += 1
print(f"realm-{n:03d}")
PY
}

detect_realm_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) printf '%s\n' "aarch64-unknown-linux-gnu" ;;
    *)
      return 1
      ;;
  esac
}

install_realm_latest() {
  need_root
  require_python3 || {
    pause_enter
    return 1
  }

  ensure_realm_dirs

  local target arch api_url download_url tmp_json tmp_tar tmp_dir
  target="$(detect_realm_arch)" || {
    err "当前架构暂未在脚本中适配：$(uname -m)"
    pause_enter
    return 1
  }

  if ! has_cmd curl && ! has_cmd wget; then
    err "缺少 curl/wget，无法下载 Realm"
    pause_enter
    return 1
  fi

  api_url="https://api.github.com/repos/zhboner/realm/releases/latest"
  tmp_json="${TMP_DIR}/realm-release.json"
  tmp_tar="${TMP_DIR}/realm.tar.gz"
  tmp_dir="${TMP_DIR}/realm-extract"

  if has_cmd curl; then
    curl -fsSL "${api_url}" -o "${tmp_json}" || {
      err "获取 Realm 最新版本信息失败"
      pause_enter
      return 1
    }
  else
    wget -qO "${tmp_json}" "${api_url}" || {
      err "获取 Realm 最新版本信息失败"
      pause_enter
      return 1
    }
  fi

  download_url="$(python3 - "${tmp_json}" "${target}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
target = sys.argv[2]
assets = data.get("assets", [])
for a in assets:
    url = str(a.get("browser_download_url", "") or "")
    name = str(a.get("name", "") or "")
    if target in name and name.endswith(".tar.gz"):
        print(url)
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || {
    err "未找到适配当前架构的 Realm 发布包：${target}"
    pause_enter
    return 1
  }

  if has_cmd curl; then
    curl -fsSL "${download_url}" -o "${tmp_tar}" || {
      err "下载 Realm 失败"
      pause_enter
      return 1
    }
  else
    wget -qO "${tmp_tar}" "${download_url}" || {
      err "下载 Realm 失败"
      pause_enter
      return 1
    }
  fi

  rm -rf "${tmp_dir}"
  mkdir -p "${tmp_dir}"

  tar -xzf "${tmp_tar}" -C "${tmp_dir}" || {
    err "解压 Realm 失败"
    pause_enter
    return 1
  }

  local realm_path
  realm_path="$(find "${tmp_dir}" -type f -name realm | head -n1)"

  if [ -z "${realm_path}" ] || [ ! -f "${realm_path}" ]; then
    err "解压后未找到 realm 可执行文件"
    pause_enter
    return 1
  fi

  install -m 0755 "${realm_path}" "${REALM_BIN}" || {
    err "安装 Realm 到 ${REALM_BIN} 失败"
    pause_enter
    return 1
  }

  ok "Realm 安装完成：${REALM_BIN}"
  "${REALM_BIN}" --version 2>/dev/null || true
  pause_enter
}

prompt_realm_listen_mode() {
  local choice
  while true; do
    echo >&2
    echo "请选择监听模式：" >&2
    echo "1. IPv4 only   （监听 0.0.0.0，仅 IPv4）" >&2
    echo "2. Dual stack  （监听 [::]，同时兼容 IPv4/IPv6，推荐）" >&2
    echo "3. IPv6 only   （监听 [::]，仅 IPv6）" >&2
    read -r -p "请选择 [1-3]（默认 2）: " choice

    case "${choice:-2}" in
      1)
        printf '%s\n' "ipv4"
        return 0
        ;;
      2)
        printf '%s\n' "dual"
        return 0
        ;;
      3)
        printf '%s\n' "ipv6"
        return 0
        ;;
      *)
        echo "无效选项：只能输入 1 / 2 / 3" >&2
        ;;
    esac
  done
}

prompt_realm_transport() {
  local choice
  while true; do
    echo >&2
    echo "请选择转发协议：" >&2
    echo "1. 仅 TCP   （适合网站、TLS、Reality、VMess WS 等）" >&2
    echo "2. 仅 UDP   （适合 Hysteria2、TUIC、部分游戏/语音）" >&2
    echo "3. TCP+UDP  （同时转发两种流量，通用）" >&2
    read -r -p "请选择 [1-3]（默认 1）: " choice

    case "${choice:-1}" in
      1)
        printf '%s\n' "tcp"
        return 0
        ;;
      2)
        printf '%s\n' "udp"
        return 0
        ;;
      3)
        printf '%s\n' "both"
        return 0
        ;;
      *)
        echo "无效选项：只能输入 1 / 2 / 3" >&2
        ;;
    esac
  done
}

resolve_realm_listen_conf() {
  local mode="$1"
  local port="$2"

  case "${mode}" in
    ipv4) printf '0.0.0.0:%s|false\n' "${port}" ;;
    dual) printf '[::]:%s|false\n' "${port}" ;;
    ipv6) printf '[::]:%s|true\n' "${port}" ;;
    *) return 1 ;;
  esac
}

format_realm_hostport() {
  local host="$1"
  local port="$2"

  python3 - "$host" "$port" <<'PY'
import sys, ipaddress
host = sys.argv[1].strip()
port = sys.argv[2].strip()
try:
    ip = ipaddress.ip_address(host)
    if ip.version == 6:
        print(f"[{host}]:{port}")
    else:
        print(f"{host}:{port}")
except Exception:
    print(f"{host}:{port}")
PY
}

write_realm_config() {
  local conf_path="$1"
  local listen_addr="$2"
  local remote_addr="$3"
  local transport="$4"
  local ipv6_only="$5"

  local no_tcp="false" use_udp="false"
  case "${transport}" in
    tcp)  no_tcp="false"; use_udp="false" ;;
    udp)  no_tcp="true" ; use_udp="true"  ;;
    both) no_tcp="false"; use_udp="true"  ;;
    *)    no_tcp="false"; use_udp="false" ;;
  esac

  cat > "${conf_path}" <<EOF
[log]
level = "warn"

[network]
no_tcp = ${no_tcp}
use_udp = ${use_udp}
ipv6_only = ${ipv6_only}

[[endpoints]]
listen = "${listen_addr}"
remote = "${remote_addr}"
EOF
}

write_realm_service() {
  local tag="$1"
  local conf_path="$2"
  local unit
  unit="/etc/systemd/system/$(realm_tag_to_unit "${tag}")"

  cat > "${unit}" <<EOF
[Unit]
Description=Realm Relay (${tag})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${conf_path}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

save_realm_meta() {
  local tag="$1"
  local listen_mode="$2"
  local listen_addr="$3"
  local listen_port="$4"
  local remote_host="$5"
  local remote_port="$6"
  local transport="$7"

  local meta_file
  meta_file="$(realm_tag_to_meta "${tag}")"

  cat > "${meta_file}" <<JSON
{
  "protocol": "realm-relay",
  "tag": "${tag}",
  "listen_mode": "${listen_mode}",
  "listen_addr": "${listen_addr}",
  "listen_port": ${listen_port},
  "remote_host": "${remote_host}",
  "remote_port": ${remote_port},
  "transport": "${transport}"
}
JSON
}

deploy_realm_relay() {
  need_root

  if [ ! -x "${REALM_BIN}" ]; then
    err "未检测到 Realm，请先安装"
    pause_enter
    return 1
  fi

  ensure_realm_dirs

  local tag listen_mode listen_port listen_info listen_addr ipv6_only
  local remote_host remote_port remote_addr transport
  local conf_path unit_name

  tag="$(prompt_realm_tag "$(next_realm_tag)")"
  listen_mode="$(prompt_realm_listen_mode)"
  listen_port="$(prompt_port_default "请输入 Realm 监听端口" "26845")"
  listen_info="$(resolve_realm_listen_conf "${listen_mode}" "${listen_port}")"
  listen_addr="${listen_info%%|*}"
  ipv6_only="${listen_info##*|}"

  remote_host="$(prompt_required "请输入后端目标地址（IPv4 / IPv6 / 域名）")"
  remote_port="$(prompt_port_default "请输入后端目标端口" "26845")"
  remote_addr="$(format_realm_hostport "${remote_host}" "${remote_port}")"

  transport="$(prompt_realm_transport)"

  echo
  echo "========== Realm 中转预览 =========="
  echo "实例标签       : ${tag}"
  echo "监听模式       : ${listen_mode}"
  echo "监听地址       : ${listen_addr}"
  echo "后端目标       : ${remote_addr}"
  echo "转发协议       : ${transport}"
  echo "===================================="
  echo

  if ! confirm_default_yes "确认写入并启动 Realm 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  conf_path="$(realm_tag_to_conf "${tag}")"
  write_realm_config "${conf_path}" "${listen_addr}" "${remote_addr}" "${transport}" "${ipv6_only}" || {
    err "写入 Realm 配置失败"
    pause_enter
    return 1
  }

  write_realm_service "${tag}" "${conf_path}" || {
    err "写入 systemd 服务失败"
    pause_enter
    return 1
  }

  systemctl daemon-reload
  systemctl enable --now "$(realm_tag_to_unit "${tag}")" || {
    err "启动 Realm 实例失败"
    pause_enter
    return 1
  }

  save_realm_meta "${tag}" "${listen_mode}" "${listen_addr}" "${listen_port}" "${remote_host}" "${remote_port}" "${transport}"

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    local backend
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      case "${transport}" in
        tcp)
          if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
            fw_open_port "${backend}" "${listen_port}" "tcp" && ok "已放行 ${listen_port}/tcp" || err "放行失败"
          fi
          ;;
        udp)
          if confirm_default_yes "是否一键放行 ${listen_port}/udp 到防火墙？"; then
            fw_open_port "${backend}" "${listen_port}" "udp" && ok "已放行 ${listen_port}/udp" || err "放行失败"
          fi
          ;;
        both)
          if confirm_default_yes "是否一键放行 ${listen_port}/tcp 到防火墙？"; then
            fw_open_port "${backend}" "${listen_port}" "tcp" && ok "已放行 ${listen_port}/tcp" || err "放行失败"
          fi
          if confirm_default_yes "是否一键放行 ${listen_port}/udp 到防火墙？"; then
            fw_open_port "${backend}" "${listen_port}" "udp" && ok "已放行 ${listen_port}/udp" || err "放行失败"
          fi
          ;;
      esac
    fi
  fi

  ok "Realm 中转实例已创建：${tag}"
  pause_enter
}

list_realm_instances() {
  ensure_realm_dirs
  python3 - "${REALM_META_DIR}" <<'PY'
import json, os, sys
base = sys.argv[1]
rows = []
if os.path.isdir(base):
    for name in sorted(os.listdir(base)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(base, name)
        try:
            data = json.load(open(path, 'r', encoding='utf-8'))
        except Exception:
            continue
        rows.append((
            data.get("tag",""),
            data.get("listen_mode",""),
            data.get("listen_addr",""),
            data.get("remote_host",""),
            data.get("remote_port",""),
            data.get("transport","")
        ))
for i, row in enumerate(rows, 1):
    print("\t".join([str(i), *[str(x) for x in row]]))
PY
}

get_realm_tag_by_index() {
  local idx="$1"
  python3 - "${REALM_META_DIR}" "${idx}" <<'PY'
import json, os, sys
base = sys.argv[1]
idx = int(sys.argv[2])
rows = []
if os.path.isdir(base):
    for name in sorted(os.listdir(base)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(base, name)
        try:
            data = json.load(open(path, 'r', encoding='utf-8'))
        except Exception:
            continue
        rows.append(str(data.get("tag","")))
if idx < 1 or idx > len(rows):
    raise SystemExit(1)
print(rows[idx-1])
PY
}

show_realm_instances() {
  ensure_realm_dirs

  echo "编号 标签                     监听模式    监听地址              目标地址                 协议        服务状态"
  echo "----------------------------------------------------------------------------------------------------------------"

  local found=0
  while IFS=$'\t' read -r idx tag listen_mode listen_addr remote_host remote_port transport; do
    [ -z "${idx}" ] && continue
    found=1
    local unit status
    unit="$(realm_tag_to_unit "${tag}")"
    status="$(systemctl is-active "${unit}" 2>/dev/null || echo inactive)"
    printf '%-4s %-24s %-10s %-20s %-24s %-10s %s\n' \
      "${idx}" "${tag}" "${listen_mode}" "${listen_addr}" "${remote_host}:${remote_port}" "${transport}" "${status}"
  done < <(list_realm_instances)

  if [ "${found}" -eq 0 ]; then
    echo "<暂无 Realm 中转实例>"
  fi

  echo "----------------------------------------------------------------------------------------------------------------"
  pause_enter
}

delete_realm_instance() {
  need_root
  ensure_realm_dirs

  show_realm_instances
  echo

  local idx tag conf_path meta_path unit_name
  idx="$(prompt_required "请输入要删除的 Realm 实例编号")"
  tag="$(get_realm_tag_by_index "${idx}")" || {
    err "编号无效"
    pause_enter
    return 1
  }

  if ! confirm_default_no "确认删除 Realm 实例 ${tag} 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  conf_path="$(realm_tag_to_conf "${tag}")"
  meta_path="$(realm_tag_to_meta "${tag}")"
  unit_name="$(realm_tag_to_unit "${tag}")"

  systemctl disable --now "${unit_name}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${unit_name}"
  systemctl daemon-reload

  rm -f "${conf_path}" "${meta_path}"

  ok "已删除 Realm 实例：${tag}"
  pause_enter
}

restart_realm_instance() {
  need_root
  ensure_realm_dirs

  show_realm_instances
  echo

  local idx tag unit_name
  idx="$(prompt_required "请输入要重启的 Realm 实例编号")"
  tag="$(get_realm_tag_by_index "${idx}")" || {
    err "编号无效"
    pause_enter
    return 1
  }

  unit_name="$(realm_tag_to_unit "${tag}")"
  systemctl restart "${unit_name}" || {
    err "重启失败：${tag}"
    pause_enter
    return 1
  }

  ok "已重启：${tag}"
  pause_enter
}

menu_realm_relay_management() {
  while true; do
    clear
    echo "======================================"
    echo "             Realm 中转"
    echo "======================================"
    echo "1. 安装 Realm"
    echo "2. 新建 Realm 中转"
    echo "3. 查看 Realm 中转状态"
    echo "4. 重启 Realm 实例"
    echo "5. 删除 Realm 实例"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-5]: " choice
    case "${choice:-}" in
      1) install_realm_latest ;;
      2) deploy_realm_relay ;;
      3) show_realm_instances ;;
      4) restart_realm_instance ;;
      5) delete_realm_instance ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
