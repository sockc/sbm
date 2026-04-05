#!/usr/bin/env bash

require_clash_api_env() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    err "未找到 ${CONFIG_DIR}/config.json，请先部署入站实例"
    return 1
  fi
  if ! has_cmd python3; then
    err "缺少 python3，无法处理 JSON"
    return 1
  fi
}

gen_api_secret() {
  if has_cmd openssl; then
    openssl rand -hex 16
    return 0
  fi

  python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
}

get_clash_api_runtime() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
clash = cfg.get("experimental", {}).get("clash_api", {})
print(clash.get("external_controller", ""))
print(clash.get("secret", ""))
PY
}

load_clash_api_current() {
  mapfile -t _clash_api_vals < <(
    python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
clash = cfg.get("experimental", {}).get("clash_api", {})

enabled = "true" if clash else "false"
controller = clash.get("external_controller", "")
ui_dir = clash.get("external_ui", "")
ui_url = clash.get("external_ui_download_url", "")
ui_detour = clash.get("external_ui_download_detour", "")
secret = clash.get("secret", "")
default_mode = clash.get("default_mode", "")
allow_origin = ",".join(clash.get("access_control_allow_origin", [])) if isinstance(clash.get("access_control_allow_origin"), list) else ""
allow_private = "true" if clash.get("access_control_allow_private_network", False) else "false"

print(enabled)
print(controller)
print(ui_dir)
print(ui_url)
print(ui_detour)
print(secret)
print(default_mode)
print(allow_origin)
print(allow_private)
PY
  )

  CLASH_API_ENABLED="${_clash_api_vals[0]:-false}"
  CLASH_API_CONTROLLER="${_clash_api_vals[1]:-}"
  CLASH_API_UI_DIR="${_clash_api_vals[2]:-}"
  CLASH_API_UI_URL="${_clash_api_vals[3]:-}"
  CLASH_API_UI_DETOUR="${_clash_api_vals[4]:-}"
  CLASH_API_SECRET="${_clash_api_vals[5]:-}"
  CLASH_API_DEFAULT_MODE="${_clash_api_vals[6]:-}"
  CLASH_API_ALLOW_ORIGIN="${_clash_api_vals[7]:-}"
  CLASH_API_ALLOW_PRIVATE="${_clash_api_vals[8]:-false}"
}

ui_preset_menu() {
  echo "请选择面板 UI："
  echo "1. Yacd-meta（兼容优先，默认）"
  echo "2. MetaCubeXD（功能更多）"
  echo "3. Zashboard（界面更新）"
  echo "4. 自定义 UI ZIP 地址"
}

choose_ui_preset() {
  local choice custom_url
  UI_PRESET_NAME=""
  UI_PRESET_URL=""

  ui_preset_menu
  read -r -p "请选择 [1-4]（默认 1）: " choice
  choice="${choice:-1}"

  case "${choice}" in
    1)
      UI_PRESET_NAME="Yacd-meta"
      UI_PRESET_URL=""
      ;;
    2)
      UI_PRESET_NAME="MetaCubeXD"
      UI_PRESET_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
      ;;
    3)
      UI_PRESET_NAME="Zashboard"
      UI_PRESET_URL="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
      ;;
    4)
      UI_PRESET_NAME="自定义"
      custom_url="$(prompt_required "请输入 UI ZIP 下载地址")"
      UI_PRESET_URL="${custom_url}"
      ;;
    *)
      warn "无效选项，已回退到 Yacd-meta"
      UI_PRESET_NAME="Yacd-meta"
      UI_PRESET_URL=""
      ;;
  esac
}

clear_clash_ui_dir() {
  local ui_dir="$1"
  [ -z "${ui_dir}" ] && ui_dir="dashboard"

  if [ -d "${CONFIG_DIR}/${ui_dir}" ]; then
    rm -rf "${CONFIG_DIR:?}/${ui_dir}"
  fi
}

controller_port() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
if not s:
    print("")
    raise SystemExit(0)
if s.startswith('['):
    # [::1]:9090
    p = s.rsplit(':', 1)[-1]
else:
    p = s.rsplit(':', 1)[-1]
print(p)
PY
}

apply_clash_api_settings() {
  local mode="$1"                      # enable / disable
  local controller="${2:-}"
  local ui_dir="${3:-dashboard}"
  local ui_url="${4:-}"
  local ui_detour="${5:-}"
  local secret="${6:-}"
  local default_mode="${7:-Rule}"
  local allow_origin="${8:-}"
  local allow_private="${9:-false}"

  local tmp_file
  tmp_file="${TMP_DIR}/config.clash-api.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${mode}" "${controller}" "${ui_dir}" "${ui_url}" "${ui_detour}" \
    "${secret}" "${default_mode}" "${allow_origin}" "${allow_private}" <<'PY'
import json, sys

(
    path_cfg, mode, controller, ui_dir, ui_url, ui_detour,
    secret, default_mode, allow_origin, allow_private
) = sys.argv[1:]

cfg = json.load(open(path_cfg, 'r', encoding='utf-8'))
exp = cfg.setdefault("experimental", {})

# 启用 selector / clash mode 持久化
cache = exp.setdefault("cache_file", {})
cache["enabled"] = True
cache["path"] = "cache.db"
cache["cache_id"] = "sbm"

if mode == "disable":
    exp.pop("clash_api", None)
else:
    clash = {}
    clash["external_controller"] = controller
    clash["external_ui"] = ui_dir

    if ui_url:
        clash["external_ui_download_url"] = ui_url
    if ui_detour:
        clash["external_ui_download_detour"] = ui_detour
    if secret:
        clash["secret"] = secret

    clash["default_mode"] = default_mode or "Rule"

    if allow_origin:
        clash["access_control_allow_origin"] = [x.strip() for x in allow_origin.split(",") if x.strip()]
    if str(allow_private).lower() == "true":
        clash["access_control_allow_private_network"] = True

    exp["clash_api"] = clash

with open(path_cfg, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 Clash API 配置失败"
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    return 1
  fi

  return 0
}

show_clash_api_status() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current

  echo "======================================"
  echo "           Clash API 状态"
  echo "======================================"

  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    echo "状态              : 未开启"
    echo "======================================"
    pause_enter
    return 0
  fi

  local ui_name="自定义/未知"
  case "${CLASH_API_UI_URL}" in
    "")
      ui_name="Yacd-meta（默认）"
      ;;
    "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip")
      ui_name="MetaCubeXD"
      ;;
    "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip")
      ui_name="Zashboard"
      ;;
  esac

  echo "状态              : 已开启"
  echo "监听地址          : ${CLASH_API_CONTROLLER:-<空>}"
  echo "UI 目录           : ${CLASH_API_UI_DIR:-<空>}"
  echo "UI 预设           : ${ui_name}"
  echo "UI 下载源         : ${CLASH_API_UI_URL:-默认(Yacd-meta)}"
  echo "UI 下载出口       : ${CLASH_API_UI_DETOUR:-默认出口}"
  if [ -n "${CLASH_API_SECRET}" ]; then
    echo "API Secret        : ${CLASH_API_SECRET}"
  else
    echo "API Secret        : 未设置"
  fi
  echo "默认模式          : ${CLASH_API_DEFAULT_MODE:-Rule}"
  echo "CORS 允许来源     : ${CLASH_API_ALLOW_ORIGIN:-*}"
  echo "允许私网访问      : ${CLASH_API_ALLOW_PRIVATE:-false}"

if [ -n "${CLASH_API_CONTROLLER}" ]; then
  local ctrl_host port
  ctrl_host="${CLASH_API_CONTROLLER%:*}"
  port="$(controller_port "${CLASH_API_CONTROLLER}")"

  if [ -n "${port}" ]; then
    case "${ctrl_host}" in
      127.0.0.1|localhost|::1|\[::1\])
        echo "UI 地址           : http://127.0.0.1:${port}/ui/"
        ;;
      0.0.0.0|::|\[::\])
        echo "UI 地址           : http://服务器IP:${port}/ui/"
        ;;
      *)
        echo "UI 地址           : http://${ctrl_host}:${port}/ui/"
        ;;
    esac
  fi
fi

  echo "======================================"
  pause_enter
}

auto_sync_sources_after_clash_api_enable() {
  if ! declare -F update_all_sources >/dev/null 2>&1; then
    warn "未找到 update_all_sources，跳过自动更新节点源"
    return 0
  fi

  if ! declare -F apply_all_sources_to_runtime >/dev/null 2>&1; then
    warn "未找到 apply_all_sources_to_runtime，跳过自动应用节点源"
    return 0
  fi

  local has_sources="false"

  # 优先检查 sources 目录里是否已有节点源文件
  if [ -d "${CONFIG_DIR}/sources" ] && find "${CONFIG_DIR}/sources" -maxdepth 1 -type f | grep -q .; then
    has_sources="true"
  fi

  # 再兼容一些脚本把节点源放在单独目录/缓存目录的情况
  if [ "${has_sources}" != "true" ] && [ -d "${BASE_DIR}/sources" ] && find "${BASE_DIR}/sources" -maxdepth 1 -type f | grep -q .; then
    has_sources="true"
  fi

  if [ "${has_sources}" != "true" ] && [ -d "${CONFIG_DIR}/node-cache" ] && find "${CONFIG_DIR}/node-cache" -maxdepth 1 -type f | grep -q .; then
    has_sources="true"
  fi

  if [ "${has_sources}" != "true" ]; then
    warn "当前没有检测到节点源文件，已跳过自动同步"
    return 0
  fi

  echo
  echo "正在自动同步节点源到当前策略组..."

  if ! update_all_sources; then
    warn "节点源更新失败，但面板已成功启用"
    return 0
  fi

  if ! apply_all_sources_to_runtime; then
    warn "节点源应用失败，但面板已成功启用"
    return 0
  fi

  ok "节点源已自动更新并应用到当前策略组"
  return 0
}

enable_clash_api_preset() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  auto_apply_policy_file_after_clash_api_enable() {
  if [ -z "${POLICY_GROUPS_FILE:-}" ]; then
    warn "未定义 POLICY_GROUPS_FILE，跳过自动应用策略文件"
    return 0
  fi

  if [ ! -f "${POLICY_GROUPS_FILE}" ]; then
    warn "未找到策略文件，跳过自动应用：${POLICY_GROUPS_FILE}"
    return 0
  fi

  if ! declare -F apply_policy_groups_file_silent >/dev/null 2>&1; then
    warn "未找到 apply_policy_groups_file_silent，跳过自动应用策略文件"
    return 0
  fi

  echo
  echo "正在自动应用策略文件..."

  if ! apply_policy_groups_file_silent; then
    warn "策略文件应用失败，但面板已成功启用"
    return 0
  fi

  ok "策略文件已自动应用"
  return 0
}

  local preset="$1" # local / public
  load_clash_api_current

  local controller secret ui_dir ui_url ui_detour default_mode allow_origin allow_private
  ui_dir="dashboard"
  ui_detour="direct"
  default_mode="${CLASH_API_DEFAULT_MODE:-Rule}"
  allow_origin="${CLASH_API_ALLOW_ORIGIN:-}"
  allow_private="${CLASH_API_ALLOW_PRIVATE:-false}"

  choose_ui_preset

  if [ "${preset}" = "local" ]; then
    controller="127.0.0.1:9090"
    secret="${CLASH_API_SECRET:-$(gen_api_secret)}"
  else
    controller="0.0.0.0:9066"
    secret="${CLASH_API_SECRET:-$(gen_api_secret)}"
  fi

  ui_url="${UI_PRESET_URL}"

  echo
  echo "========== Clash API 预览 =========="
  if [ "${preset}" = "local" ]; then
    echo "模式              : 本机面板"
  else
    echo "模式              : 公网面板"
  fi
  echo "监听地址          : ${controller}"
  echo "UI 目录           : ${ui_dir}"
  echo "UI 预设           : ${UI_PRESET_NAME}"
  echo "UI 下载源         : ${ui_url:-默认(Yacd-meta)}"
  echo "API Secret        : ${secret}"
  echo "默认模式          : ${default_mode:-Rule}"
  echo "===================================="
  echo

  if ! confirm_default_yes "确认启用并自动下载面板 UI 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  clear_clash_ui_dir "${ui_dir}"

  if ! apply_clash_api_settings "enable" "${controller}" "${ui_dir}" "${ui_url}" "${ui_detour}" "${secret}" "${default_mode}" "${allow_origin}" "${allow_private}"; then
    pause_enter
    return 1
  fi

  auto_sync_sources_after_clash_api_enable || true
  auto_apply_policy_file_after_clash_api_enable || true

  if [ "${preset}" = "public" ]; then
    local port backend
    port="$(controller_port "${controller}")"
    if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
      backend="$(detect_firewall_backend)"
      if [ "${backend}" != "none" ] && [ -n "${port}" ]; then
        if confirm_default_yes "是否一键放行 ${port}/tcp 到防火墙？"; then
          if fw_open_port "${backend}" "${port}" "tcp"; then
            ok "已放行 ${port}/tcp"
          else
            err "放行 ${port}/tcp 失败"
          fi
        fi
      fi
    fi
  fi

  ok "Clash API 已启用，面板将自动下载"
  pause_enter
}

disable_clash_api() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current
  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    warn "Clash API 当前未开启"
    pause_enter
    return 0
  fi

  if ! confirm_default_yes "确认关闭 Clash API 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! apply_clash_api_settings "disable"; then
    pause_enter
    return 1
  fi

  ok "Clash API 已关闭"
  pause_enter
}

change_clash_api_ui() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current
  if [ "${CLASH_API_ENABLED}" != "true" ]; then
    warn "请先启用 Clash API"
    pause_enter
    return 0
  fi

  choose_ui_preset

  if ! confirm_default_yes "确认切换面板 UI 并自动重新下载吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  clear_clash_ui_dir "${CLASH_API_UI_DIR:-dashboard}"

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${UI_PRESET_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${CLASH_API_SECRET}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "面板 UI 已切换为：${UI_PRESET_NAME}"
  pause_enter
}

set_clash_api_secret() {
  require_clash_api_env || {
    pause_enter
    return 1
  }

  load_clash_api_current

  local new_secret
  new_secret="$(prompt_default "请输入 API Secret（留空自动生成）" "$(gen_api_secret)")"

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER:-127.0.0.1:9090}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${new_secret}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "API Secret 已更新"
  pause_enter
}

set_clash_api_controller() {
  load_clash_api_current
  local controller
  controller="$(prompt_default "请输入监听地址 host:port" "${CLASH_API_CONTROLLER:-127.0.0.1:9090}")"

  if ! apply_clash_api_settings \
    "enable" \
    "${controller}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${CLASH_API_SECRET:-$(gen_api_secret)}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "监听地址已更新"
  pause_enter
}

set_clash_api_default_mode() {
  load_clash_api_current
  local choice mode

  echo "请选择默认模式："
  echo "1. Rule"
  echo "2. Global"
  echo "3. Direct"
  read -r -p "请选择 [1-3]（默认 1）: " choice
  case "${choice:-1}" in
    1) mode="Rule" ;;
    2) mode="Global" ;;
    3) mode="Direct" ;;
    *) mode="Rule" ;;
  esac

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER:-127.0.0.1:9090}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${CLASH_API_SECRET:-$(gen_api_secret)}" \
    "${mode}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "默认模式已更新为 ${mode}"
  pause_enter
}

set_clash_api_ui_detour() {
  load_clash_api_current
  local detour
  detour="$(prompt_default "请输入 UI 下载出口 tag（留空走默认出口）" "${CLASH_API_UI_DETOUR:-direct}")"

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER:-127.0.0.1:9090}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${detour}" \
    "${CLASH_API_SECRET:-$(gen_api_secret)}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "UI 下载出口已更新"
  pause_enter
}

set_clash_api_cors_origin() {
  load_clash_api_current
  local origin
  origin="$(prompt_default "请输入 CORS 允许来源（多个用英文逗号分隔，留空为 *）" "${CLASH_API_ALLOW_ORIGIN}")"

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER:-127.0.0.1:9090}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${CLASH_API_SECRET:-$(gen_api_secret)}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${origin}" \
    "${CLASH_API_ALLOW_PRIVATE:-false}"; then
    pause_enter
    return 1
  fi

  ok "CORS 允许来源已更新"
  pause_enter
}

set_clash_api_allow_private_network() {
  load_clash_api_current
  local allow_private="false"

  if confirm_default_no "允许来自私有网络的访问吗？"; then
    allow_private="true"
  fi

  if ! apply_clash_api_settings \
    "enable" \
    "${CLASH_API_CONTROLLER:-127.0.0.1:9090}" \
    "${CLASH_API_UI_DIR:-dashboard}" \
    "${CLASH_API_UI_URL}" \
    "${CLASH_API_UI_DETOUR:-direct}" \
    "${CLASH_API_SECRET:-$(gen_api_secret)}" \
    "${CLASH_API_DEFAULT_MODE:-Rule}" \
    "${CLASH_API_ALLOW_ORIGIN}" \
    "${allow_private}"; then
    pause_enter
    return 1
  fi

  ok "私网访问设置已更新"
  pause_enter
}

restore_clash_api_defaults() {
  load_clash_api_current
  local controller secret

  controller="${CLASH_API_CONTROLLER:-127.0.0.1:9090}"
  secret="${CLASH_API_SECRET:-$(gen_api_secret)}"

  if ! confirm_default_yes "确认恢复 Clash API 推荐默认值吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! apply_clash_api_settings \
    "enable" \
    "${controller}" \
    "dashboard" \
    "" \
    "direct" \
    "${secret}" \
    "Rule" \
    "" \
    "false"; then
    pause_enter
    return 1
  fi

  ok "已恢复推荐默认值"
  pause_enter
}

menu_clash_api_advanced() {
  while true; do
    clear
    echo "======================================"
    echo "           Clash API 高级设置"
    echo "======================================"
    echo "1. 设置监听地址"
    echo "2. 设置默认模式"
    echo "3. 设置 UI 下载出口"
    echo "4. 设置 CORS 允许来源"
    echo "5. 设置允许私网访问"
    echo "6. 恢复推荐默认值"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) set_clash_api_controller ;;
      2) set_clash_api_default_mode ;;
      3) set_clash_api_ui_detour ;;
      4) set_clash_api_cors_origin ;;
      5) set_clash_api_allow_private_network ;;
      6) restore_clash_api_defaults ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_clash_api_management() {
  while true; do
    clear
    echo "======================================"
    echo "           Clash API 管理"
    echo "======================================"
    echo "1. 一键启用本机面板"
    echo "2. 一键启用公网面板"
    echo "3. 关闭 Clash API"
    echo "4. 查看当前状态"
    echo "5. 更换面板 UI"
    echo "6. 设置 API Secret"
    echo "7. 高级设置"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-7]: " choice
    case "${choice:-}" in
      1) enable_clash_api_preset "local" ;;
      2) enable_clash_api_preset "public" ;;
      3) disable_clash_api ;;
      4) show_clash_api_status ;;
      5) change_clash_api_ui ;;
      6) set_clash_api_secret ;;
      7) menu_clash_api_advanced ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
