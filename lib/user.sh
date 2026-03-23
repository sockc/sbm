#!/usr/bin/env bash

require_user_manage_env() {
  require_config_file || return 1
  require_python3 || return 1
}

default_next_user_name() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
count = 0

for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        count = len(ib.get("users", []))
        break

print(f"user{count + 1}")
PY
}

show_vless_users() {
  require_user_manage_env || return 1

  echo "当前用户："
  echo "编号 用户备注         UUID"
  echo "----------------------------------------------"
  show_vless_users_simple
  echo "----------------------------------------------"
}

add_vless_user() {
  require_user_manage_env || return 1

  mkdir -p "${TMP_DIR}"

  local user_name user_uuid tmp_file
  user_name="$(prompt_default "请输入用户备注" "$(default_next_user_name)")"
  user_uuid="$(prompt_default "请输入 UUID" "$(gen_uuid)")"
  tmp_file="${TMP_DIR}/config.add-user.json"

  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$user_name" "$user_uuid" <<'PY'
import json, sys

path, name, uuid = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path, 'r', encoding='utf-8'))

target = None
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        target = ib
        break

if target is None:
    print("未找到 vless-reality-in 入站", file=sys.stderr)
    raise SystemExit(1)

users = target.setdefault("users", [])

for u in users:
    if u.get("name") == name:
        print(f"用户备注已存在: {name}", file=sys.stderr)
        raise SystemExit(1)
    if u.get("uuid") == uuid:
        print(f"UUID 已存在: {uuid}", file=sys.stderr)
        raise SystemExit(1)

users.append({
    "name": name,
    "uuid": uuid,
    "flow": "xtls-rprx-vision"
})

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "新增用户失败"
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

  ok "用户新增成功：${user_name}"
  echo
  echo "可到 导出客户端配置 菜单里导出链接"
  echo
  pause_enter
}

delete_vless_user() {
  require_user_manage_env || return 1

  mkdir -p "${TMP_DIR}"

  show_vless_users
  echo

  local idx tmp_file
  idx="$(prompt_required "请输入要删除的用户编号")"
  tmp_file="${TMP_DIR}/config.del-user.json"

  if ! confirm_default_no "确认删除该用户吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$idx" <<'PY'
import json, sys

path, idx = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(path, 'r', encoding='utf-8'))

target = None
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        target = ib
        break

if target is None:
    print("未找到 vless-reality-in 入站", file=sys.stderr)
    raise SystemExit(1)

users = target.get("users", [])

if len(users) <= 1:
    print("至少保留一个用户，不能删除最后一个", file=sys.stderr)
    raise SystemExit(1)

if idx < 1 or idx > len(users):
    print("编号超出范围", file=sys.stderr)
    raise SystemExit(1)

users.pop(idx - 1)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "删除用户失败"
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

  ok "用户删除成功"
  pause_enter
}

menu_user_management() {
  while true; do
    clear
    echo "======================================"
    echo "             用户管理"
    echo "======================================"
    echo "1. 新增用户"
    echo "2. 删除用户"
    echo "3. 查看用户"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) add_vless_user ;;
      2) delete_vless_user ;;
      3) show_vless_users; pause_enter ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
