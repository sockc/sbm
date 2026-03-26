#!/usr/bin/env bash

detect_firewall_backend() {
  if has_cmd ufw; then
    echo "ufw"
    return 0
  fi
  if has_cmd firewall-cmd; then
    echo "firewalld"
    return 0
  fi
  if has_cmd iptables; then
    echo "iptables"
    return 0
  fi
  echo "none"
}

get_current_vless_port() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    return 1
  fi

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        print(ib.get("listen_port", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

detect_ssh_port() {
  if has_cmd sshd; then
    sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'
    return 0
  fi

  awk '
    $1=="Port" && $2 ~ /^[0-9]+$/ {print $2; found=1; exit}
    END {if (!found) print 22}
  ' /etc/ssh/sshd_config 2>/dev/null
}

prompt_fw_port() {
  local port
  while true; do
    port="$(prompt_default "请输入端口" "443")"
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

prompt_fw_proto() {
  local proto
  while true; do
    proto="$(prompt_default "请输入协议" "tcp")"
    case "$proto" in
      tcp|udp)
        printf '%s\n' "$proto"
        return 0
        ;;
      *)
        echo "输入无效：协议只能是 tcp 或 udp"
        ;;
    esac
  done
}

show_firewall_status() {
  local backend
  backend="$(detect_firewall_backend)"

  echo "防火墙后端: ${backend}"
  echo

  case "$backend" in
    ufw)
      ufw status verbose || true
      ;;
    firewalld)
      firewall-cmd --state 2>/dev/null || true
      echo
      firewall-cmd --list-ports 2>/dev/null || true
      ;;
    iptables)
      iptables -S INPUT 2>/dev/null || true
      ;;
    none)
      echo "未检测到 ufw / firewalld / iptables"
      ;;
  esac
}

fw_open_port() {
  local backend="$1"
  local port="$2"
  local proto="$3"

  case "$backend" in
    ufw)
      ufw allow "${port}/${proto}"
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${port}/${proto}" &&
      firewall-cmd --reload
      ;;
    iptables)
      iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null ||
      iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
      ;;
    *)
      return 1
      ;;
  esac
}

fw_close_port() {
  local backend="$1"
  local port="$2"
  local proto="$3"

  case "$backend" in
    ufw)
      ufw delete allow "${port}/${proto}"
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="${port}/${proto}" &&
      firewall-cmd --reload
      ;;
    iptables)
      while iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
      done
      ;;
    *)
      return 1
      ;;
  esac
}

allow_current_vless_port() {
  need_root

  local backend port
  backend="$(detect_firewall_backend)"
  port="$(get_current_vless_port || true)"

  if [ -z "$port" ]; then
    err "未检测到当前 VLESS + Reality 监听端口，请先部署"
    pause_enter
    return 1
  fi

  if [ "$backend" = "none" ]; then
    err "未检测到受支持的防火墙后端"
    pause_enter
    return 1
  fi

  echo "当前检测到 Reality 监听端口: ${port}/tcp"
  if ! confirm_default_yes "确认放行该端口吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if fw_open_port "$backend" "$port" "tcp"; then
    ok "已放行 ${port}/tcp"
  else
    err "放行失败"
  fi

  pause_enter
}

allow_ssh_port() {
  need_root

  local backend ssh_port
  backend="$(detect_firewall_backend)"
  ssh_port="$(detect_ssh_port)"

  if [ -z "$ssh_port" ]; then
    ssh_port="22"
  fi

  if [ "$backend" = "none" ]; then
    err "未检测到受支持的防火墙后端"
    pause_enter
    return 1
  fi

  echo "当前检测到 SSH 端口: ${ssh_port}/tcp"
  if ! confirm_default_yes "确认放行 SSH 端口吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if fw_open_port "$backend" "$ssh_port" "tcp"; then
    ok "已放行 ${ssh_port}/tcp"
  else
    err "放行失败"
  fi

  pause_enter
}

allow_custom_port() {
  need_root

  local backend port proto
  backend="$(detect_firewall_backend)"

  if [ "$backend" = "none" ]; then
    err "未检测到受支持的防火墙后端"
    pause_enter
    return 1
  fi

  port="$(prompt_fw_port)"
  proto="$(prompt_fw_proto)"

  echo "准备放行: ${port}/${proto}"
  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if fw_open_port "$backend" "$port" "$proto"; then
    ok "已放行 ${port}/${proto}"
  else
    err "放行失败"
  fi

  pause_enter
}

close_custom_port() {
  need_root

  local backend port proto
  backend="$(detect_firewall_backend)"

  if [ "$backend" = "none" ]; then
    err "未检测到受支持的防火墙后端"
    pause_enter
    return 1
  fi

  port="$(prompt_fw_port)"
  proto="$(prompt_fw_proto)"

  echo "准备关闭: ${port}/${proto}"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if fw_close_port "$backend" "$port" "$proto"; then
    ok "已关闭 ${port}/${proto}"
  else
    err "关闭失败"
  fi

  pause_enter
}

toggle_firewall() {
  local backend
  backend="$(detect_firewall_backend)"

  if [ "${backend}" = "none" ]; then
    err "未检测到可用防火墙（ufw / firewalld / iptables）"
    pause_enter
    return 1
  fi

  case "${backend}" in
    ufw)
      if ufw status 2>/dev/null | grep -qi "Status: active"; then
        if confirm_default_yes "当前 ufw 已开启，是否关闭？"; then
          ufw disable
          ok "ufw 已关闭"
        fi
      else
        if confirm_default_yes "当前 ufw 未开启，是否启用？"; then
          ufw --force enable
          ok "ufw 已开启"
        fi
      fi
      ;;
    firewalld)
      if systemctl is-active firewalld >/dev/null 2>&1; then
        if confirm_default_yes "当前 firewalld 已开启，是否关闭？"; then
          systemctl stop firewalld
          systemctl disable firewalld >/dev/null 2>&1 || true
          ok "firewalld 已关闭"
        fi
      else
        if confirm_default_yes "当前 firewalld 未开启，是否启用？"; then
          systemctl enable --now firewalld
          ok "firewalld 已开启"
        fi
      fi
      ;;
    iptables)
      warn "检测到的是 iptables，通常不建议做一键开关。"
      echo "请通过“放行自定义端口 / 关闭自定义端口”管理规则。"
      ;;
    *)
      err "暂不支持的防火墙后端：${backend}"
      ;;
  esac

  pause_enter
}

menu_firewall_management() {
  while true; do
    clear
    echo "======================================"
    echo "            防火墙管理"
    echo "======================================"
    echo "1. 开启/关闭防火墙"
    echo "2. 查看防火墙状态"
    echo "3. 放行 SSH 端口"
    echo "4. 放行自定义端口"
    echo "5. 关闭自定义端口"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-5]: " choice
    case "${choice:-}" in
      1) toggle_firewall ;;
      2) show_firewall_status; pause_enter ;;
      3) allow_ssh_port ;;
      4) allow_custom_port ;;
      5) close_custom_port ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
