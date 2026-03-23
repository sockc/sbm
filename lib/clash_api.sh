#!/usr/bin/env bash

require_clash_api_env() {
  require_config_file || return 1
  require_python3 || return 1
  mkdir -p "${TMP_DIR}"
}

gen_api_secret() {
  if has_cmd openssl; then
    openssl rand -hex 16
    return 0
  fi

  if has_cmd python3; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
    return 0
  fi

  echo "change-me-$(date +%s)"
}

get_clash_api_field() {
  local field="$1"
  python3 - "${CONFIG_DIR}/config.json" "$field" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
field = sys.argv[2]

value = (
    cfg.get("experimental", {})
       .get("clash_api", {})
       .get(field, "")
)

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(",".join(str(x) for x in value))
else:
    print(value)
PY
}

apply_clash_api_config() {
  local tmp_file="$1"

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

  return 0
}

show_clash_api_status() {
  require_clash_api_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
clash = cfg.get("experimental", {}).get("clash_api", {})

controller = clash.get("external_controller", "")
ui = clash.get("external_ui", "")
secret = clash.get("secret", "")

enabled = bool(controller)

print(f"状态              : {'已开启' if enabled else '已关闭'}")
print(f"external_controller: {controller or '<空>'}")
print(f"external_ui        : {ui or '<空>'}")
print(f"secret             : {'已设置' if secret else '<空>'}")

if enabled:
    print(f"API 地址           : http://{controller}")
    if ui:
        print(f"UI 地址            : http://{controller}/ui")
PY

  echo
  pause_enter
}

enable_clash_api() {
  require_clash_api_env || return 1

  local current_controller current_secret controller secret tmp_file
  current_controller="$(get_clash_api_field "external_controller")"
  current_secret="$(get_clash_api_field "secret")"

  controller="$(prompt_default "请输入 external_controller" "${current_controller:-127.0.0.1:9090}")"
  secret="${current_secret}"

  if [ -z "${secret}" ] && [[ "${controller}" == 0.0.0.0:* ]]; then
    secret="$(gen_api_secret)"
    echo "检测到监听到 0.0.0.0，已自动生成 secret：${secret}"
    echo
  fi

  tmp_file="${TMP_DIR}/config.clash-api.enable.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$controller" "$secret" <<'PY'
import json, sys

path, controller, secret = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path, 'r', encoding='utf-8'))

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})

clash["external_controller"] = controller
if secret:
    clash["secret"] = secret

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "开启 Clash API 失败"
    pause_enter
    return 1
  fi

  if apply_clash_api_config "${tmp_file}"; then
    ok "Clash API 已开启"
  fi

  pause_enter
}

disable_clash_api() {
  require_clash_api_env || return 1

  local tmp_file
  tmp_file="${TMP_DIR}/config.clash-api.disable.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" <<'PY'
import json, sys

path = sys.argv[1]
cfg = json.load(open(path, 'r', encoding='utf-8'))

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})
clash["external_controller"] = ""

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "关闭 Clash API 失败"
    pause_enter
    return 1
  fi

  if apply_clash_api_config "${tmp_file}"; then
    ok "Clash API 已关闭"
  fi

  pause_enter
}

set_clash_api_controller() {
  require_clash_api_env || return 1

  local current controller tmp_file
  current="$(get_clash_api_field "external_controller")"
  controller="$(prompt_default "请输入 external_controller" "${current:-127.0.0.1:9090}")"

  tmp_file="${TMP_DIR}/config.clash-api.controller.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$controller" <<'PY'
import json, sys

path, controller = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, 'r', encoding='utf-8'))

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})
clash["external_controller"] = controller

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "设置监听地址失败"
    pause_enter
    return 1
  fi

  if apply_clash_api_config "${tmp_file}"; then
    ok "external_controller 已更新为：${controller}"
  fi

  pause_enter
}

set_clash_api_secret() {
  require_clash_api_env || return 1

  local current secret tmp_file
  current="$(get_clash_api_field "secret")"
  secret="$(prompt_default "请输入 API Secret" "${current:-$(gen_api_secret)}")"

  tmp_file="${TMP_DIR}/config.clash-api.secret.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$secret" <<'PY'
import json, sys

path, secret = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, 'r', encoding='utf-8'))

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})
clash["secret"] = secret

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "设置 API Secret 失败"
    pause_enter
    return 1
  fi

  if apply_clash_api_config "${tmp_file}"; then
    ok "API Secret 已更新"
  fi

  pause_enter
}

set_clash_api_ui_dir() {
  require_clash_api_env || return 1

  local current ui_dir tmp_file
  current="$(get_clash_api_field "external_ui")"
  read -r -p "请输入 external_ui 目录，留空表示清空 [当前: ${current:-<空>}] : " ui_dir

  tmp_file="${TMP_DIR}/config.clash-api.ui.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$ui_dir" <<'PY'
import json, sys

path, ui_dir = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, 'r', encoding='utf-8'))

exp = cfg.setdefault("experimental", {})
clash = exp.setdefault("clash_api", {})
clash["external_ui"] = ui_dir

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "设置 external_ui 失败"
    pause_enter
    return 1
  fi

  if apply_clash_api_config "${tmp_file}"; then
    if [ -n "${ui_dir}" ]; then
      ok "external_ui 已更新为：${ui_dir}"
    else
      ok "external_ui 已清空"
    fi
  fi

  pause_enter
}

menu_clash_api_management() {
  while true; do
    clear
    echo "======================================"
    echo "           Clash API 管理"
    echo "======================================"
    echo "1. 开启 Clash API"
    echo "2. 关闭 Clash API"
    echo "3. 查看 Clash API 状态"
    echo "4. 设置监听地址"
    echo "5. 设置 API Secret"
    echo "6. 设置外部 UI 目录"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) enable_clash_api ;;
      2) disable_clash_api ;;
      3) show_clash_api_status ;;
      4) set_clash_api_controller ;;
      5) set_clash_api_secret ;;
      6) set_clash_api_ui_dir ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
