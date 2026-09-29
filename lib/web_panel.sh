#!/usr/bin/env bash

# User-facing Web Panel workflow for sing-box Clash API.
# Keeps the underlying Clash API functions intact while simplifying normal use.

web_panel_ui_name() {
  case "$1" in
    "") echo "Yacd-meta（默认）" ;;
    "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip") echo "MetaCubeXD" ;;
    "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip") echo "Zashboard" ;;
    *) echo "自定义" ;;
  esac
}

web_panel_access_label() {
  local mode
  mode="$(detect_clash_api_mode "$1")"
  case "${mode}" in
    本机面板) echo "仅本机" ;;
    局域网面板) echo "局域网" ;;
    Tailscale面板|"Tailscale 面板") echo "Tailscale" ;;
    公网面板) echo "公网" ;;
    自定义/公网) echo "自定义/公网" ;;
    自定义) echo "自定义" ;;
    *) echo "${mode}" ;;
  esac
}

web_panel_url() {
  local controller="$1"
  python3 - "${controller}" <<'PY'
import sys
s=(sys.argv[1] or "").strip()
if not s:
    print("")
    raise SystemExit(0)

if s.startswith("[") and "]:" in s:
    host=s.rsplit(":",1)[0].strip("[]")
    port=s.rsplit(":",1)[1]
else:
    host, sep, port=s.rpartition(":")
    if not sep:
        print("")
        raise SystemExit(0)

if host in ("127.0.0.1","localhost","::1"):
    print(f"http://127.0.0.1:{port}/ui/")
elif host in ("0.0.0.0","::"):
    print(f"http://服务器IP:{port}/ui/")
elif ":" in host:
    print(f"http://[{host}]:{port}/ui/")
else:
    print(f"http://{host}:{port}/ui/")
PY
}

show_web_panel_summary() {
  require_clash_api_env || return 1
  load_clash_api_current

  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    echo "状态      : 未启用"
    echo "访问方式  : <无>"
    echo "面板 UI   : <无>"
    echo "访问地址  : <无>"
    echo "API Secret: <无>"
    return 0
  fi

  local mode ui_name url
  mode="$(web_panel_access_label "${CLASH_API_CONTROLLER}")"
  ui_name="$(web_panel_ui_name "${CLASH_API_UI_URL}")"
  url="$(web_panel_url "${CLASH_API_CONTROLLER}")"

  echo "状态      : 已启用"
  echo "访问方式  : ${mode}"
  echo "监听      : ${CLASH_API_CONTROLLER:-<空>}"
  echo "面板 UI   : ${ui_name}"
  echo "访问地址  : ${url:-<无法生成>}"
  if [ -n "${CLASH_API_SECRET}" ]; then
    echo "API Secret: 已设置 ($(mask_secret "${CLASH_API_SECRET}"))"
  else
    echo "API Secret: 未设置"
  fi
}

show_clash_api_status() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current
  clear
  echo "======================================"
  echo "             Web 面板详情"
  echo "======================================"
  show_web_panel_summary

  if [ "${CLASH_API_ENABLED}" = "true" ]; then
    echo "--------------------------------------"
    echo "UI 目录       : ${CLASH_API_UI_DIR:-dashboard}"
    echo "UI 下载源     : ${CLASH_API_UI_URL:-默认(Yacd-meta)}"
    echo "UI 下载出口   : ${CLASH_API_UI_DETOUR:-默认出口}"
    echo "Clash API 模式: ${CLASH_API_DEFAULT_MODE:-Rule}"
    echo "CORS 来源     : ${CLASH_API_ALLOW_ORIGIN:-*}"
    echo "允许私网访问  : ${CLASH_API_ALLOW_PRIVATE:-false}"
  fi

  echo "======================================"
  pause_enter
}

web_panel_apply_access_mode() {
  local preset="$1"
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current

  local controller allow_private secret
  local ui_dir ui_url ui_detour default_mode allow_origin
  ui_dir="${CLASH_API_UI_DIR:-dashboard}"
  ui_url="${CLASH_API_UI_URL}"
  ui_detour="${CLASH_API_UI_DETOUR:-direct}"
  default_mode="${CLASH_API_DEFAULT_MODE:-Rule}"
  allow_origin="${CLASH_API_ALLOW_ORIGIN}"
  secret="${CLASH_API_SECRET:-$(gen_api_secret)}"
  allow_private="${CLASH_API_ALLOW_PRIVATE:-false}"

  case "${preset}" in
    local)
      controller="127.0.0.1:9090"
      allow_private="false"
      ;;
    lan)
      local lan_ip
      lan_ip="$(detect_lan_ip || true)"
      if [ -z "${lan_ip}" ]; then
        err "未检测到可用局域网 IP"
        pause_enter
        return 1
      fi
      controller="${lan_ip}:9090"
      allow_private="true"
      ;;
    tailscale)
      local ts_ip
      ts_ip="$(detect_tailscale_ip || true)"
      if [ -z "${ts_ip}" ]; then
        err "未检测到 Tailscale IPv4 地址，请先确认 tailscaled 已连接"
        pause_enter
        return 1
      fi
      controller="${ts_ip}:9090"
      allow_private="true"
      ;;
    public)
      controller="0.0.0.0:9066"
      allow_private="false"
      echo
      warn "公网模式会让 Web 面板监听所有网络接口。"
      warn "必须保留强 Secret，并建议配合防火墙限制来源 IP。"
      if ! confirm_default_no "确认启用公网访问吗？"; then
        warn "已取消"
        pause_enter
        return 0
      fi
      ;;
    *)
      err "未知访问方式：${preset}"
      pause_enter
      return 1
      ;;
  esac

  echo
  echo "访问方式："
  case "${preset}" in
    local) echo "仅本机 -> ${controller}" ;;
    lan) echo "局域网 -> ${controller}" ;;
    tailscale) echo "Tailscale -> ${controller}" ;;
    public) echo "公网 -> ${controller}" ;;
  esac
  echo "面板 UI ：$(web_panel_ui_name "${ui_url}")"
  echo "出站配置：保持不变"
  echo

  if ! confirm_default_yes "确认应用这个访问方式吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    clear_clash_ui_dir "${ui_dir}" || {
      pause_enter
      return 1
    }
  fi

  if ! apply_clash_api_settings \
    "enable" \
    "${controller}" \
    "${ui_dir}" \
    "${ui_url}" \
    "${ui_detour}" \
    "${secret}" \
    "${default_mode}" \
    "${allow_origin}" \
    "${allow_private}"; then
    pause_enter
    return 1
  fi

  if [ "${preset}" = "public" ]; then
    local port backend
    port="$(controller_port "${controller}")"
    if declare -F detect_firewall_backend >/dev/null 2>&1 &&
       declare -F fw_open_port >/dev/null 2>&1; then
      backend="$(detect_firewall_backend)"
      if [ "${backend}" != "none" ] && [ -n "${port}" ]; then
        if confirm_default_no "是否同时放行 ${port}/tcp 到防火墙？"; then
          fw_open_port "${backend}" "${port}" "tcp" ||
            warn "防火墙放行失败，请手动检查"
        fi
      fi
    fi
  fi

  ok "Web 面板访问方式已更新"
  pause_enter
}

menu_web_panel_access_mode() {
  while true; do
    clear
    echo "======================================"
    echo "           Web 面板访问方式"
    echo "======================================"
    load_clash_api_current
    if [ "${CLASH_API_ENABLED}" = "true" ]; then
      echo "当前：$(web_panel_access_label "${CLASH_API_CONTROLLER}")"
    else
      echo "当前：未启用"
    fi
    echo
    echo "1. 仅本机"
    echo "2. 局域网"
    echo "3. Tailscale"
    echo "4. 公网"
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) web_panel_apply_access_mode "local" ;;
      2) web_panel_apply_access_mode "lan" ;;
      3) web_panel_apply_access_mode "tailscale" ;;
      4) web_panel_apply_access_mode "public" ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

web_panel_regenerate_secret() {
  require_clash_api_env || {
    pause_enter
    return 1
  }
  load_clash_api_current

  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    warn "请先启用 Web 面板"
    pause_enter
    return 0
  fi

  local secret
  secret="$(gen_api_secret)"

  warn "重新生成 Secret 后，已保存旧 Secret 的浏览器/客户端需要重新填写。"
  if ! confirm_default_no "确认重新生成 API Secret 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${secret}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "API Secret 已重新生成"
  echo
  echo "新的 Secret：${secret}"
  echo "请保存好；状态页之后只会显示脱敏值。"
  pause_enter
}

web_panel_disable() {
  require_clash_api_env || {
    pause_enter
    return 1
  }
  load_clash_api_current

  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    warn "Web 面板当前未启用"
    pause_enter
    return 0
  fi

  if ! confirm_default_yes "确认关闭 Web 面板吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! apply_clash_api_settings "disable"; then
    pause_enter
    return 1
  fi

  ok "Web 面板已关闭"
  pause_enter
}

menu_clash_api_advanced() {
  while true; do
    clear
    echo "======================================"
    echo "          Web 面板高级设置"
    echo "======================================"
    echo "1. 自定义监听地址"
    echo "2. Clash API 默认模式"
    echo "3. UI 下载出口"
    echo "4. CORS 允许来源"
    echo "5. 允许私网访问"
    echo "6. 手动设置 API Secret"
    echo "7. 恢复推荐默认值"
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择 [0-7]: " choice
    case "${choice:-}" in
      1) set_clash_api_controller ;;
      2) set_clash_api_default_mode ;;
      3) set_clash_api_ui_detour ;;
      4) set_clash_api_cors_origin ;;
      5) set_clash_api_allow_private_network ;;
      6) set_clash_api_secret ;;
      7) restore_clash_api_defaults ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_clash_api_management() {
  while true; do
    clear
    echo "======================================"
    echo "              Web 面板"
    echo "======================================"
    show_web_panel_summary
    echo
    load_clash_api_current
    if [ "${CLASH_API_ENABLED}" = "true" ]; then
      echo "1. 修改访问方式"
    else
      echo "1. 启用 / 选择访问方式"
    fi
    echo "2. 更换面板 UI"
    echo "3. 重新生成 API Secret"
    echo "4. 查看详细状态"
    echo "5. 关闭 Web 面板"
    echo "6. 高级设置"
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) menu_web_panel_access_mode ;;
      2) change_clash_api_ui ;;
      3) web_panel_regenerate_secret ;;
      4) show_clash_api_status ;;
      5) web_panel_disable ;;
      6) menu_clash_api_advanced ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
