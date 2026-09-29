#!/usr/bin/env bash

require_user_manage_env() {
  require_config_file || return 1
  require_python3 || return 1
}

list_vless_instance_rows() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
n = 0
for ib in cfg.get("inbounds", []):
    if ib.get("type") != "vless":
        continue
    n += 1
    tls = ib.get("tls", {}) or {}
    reality = (tls.get("reality", {}) or {}).get("enabled") is True
    mode = "Reality" if reality else ("TLS" if tls.get("enabled") else "Plain")
    print(f"{n}\t{ib.get('tag','')}\t{mode}\t{len(ib.get('users', []))}")
PY
}

get_vless_tag_by_index() {
  local idx="$1"
  python3 - "${CONFIG_DIR}/config.json" "${idx}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
idx = int(sys.argv[2])
rows = [ib for ib in cfg.get("inbounds", []) if ib.get("type") == "vless"]
if idx < 1 or idx > len(rows):
    raise SystemExit(1)
print(rows[idx - 1].get("tag", ""))
PY
}

select_vless_instance() {
  local prompt="${1:-请输入 VLESS 实例编号}"
  local idx tag

  echo "编号 实例标签                    模式      用户数" >&2
  echo "--------------------------------------------------------" >&2
  list_vless_instance_rows | while IFS=$'\t' read -r n t mode count; do
    printf '%-4s %-27s %-9s %s\n' "${n}" "${t}" "${mode}" "${count}" >&2
  done
  echo "--------------------------------------------------------" >&2

  if ! list_vless_instance_rows | grep -q .; then
    err "当前没有 VLESS 入站实例" >&2
    return 1
  fi

  idx="$(prompt_required "${prompt}")"
  tag="$(get_vless_tag_by_index "${idx}")" || {
    err "VLESS 实例编号无效" >&2
    return 1
  }

  [ -n "${tag}" ] || return 1
  printf '%s\n' "${tag}"
}

show_vless_users_by_tag() {
  local tag="$1"
  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == tag:
        users = ib.get("users", [])
        for i, u in enumerate(users, 1):
            uuid = str(u.get("uuid", ""))
            masked = uuid if len(uuid) <= 13 else uuid[:8] + "…" + uuid[-4:]
            print(f"{i}\t{u.get('name','')}\t{masked}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

show_vless_users_for_tag() {
  local tag="$1"
  require_user_manage_env || return 1

  echo
  echo "实例：${tag}"
  echo "编号 用户备注               UUID"
  echo "--------------------------------------------------------"
  local found=0
  while IFS=$'\t' read -r n name uuid; do
    [ -z "${n}" ] && continue
    found=1
    printf '%-4s %-22s %s\n' "${n}" "${name}" "${uuid}"
  done < <(show_vless_users_by_tag "${tag}")
  if [ "${found}" -eq 0 ]; then
    echo "<暂无用户>"
  fi
  echo "--------------------------------------------------------"
}

show_vless_users() {
  require_user_manage_env || return 1

  local tag
  tag="$(select_vless_instance "请输入要查看的 VLESS 实例编号")" || return 1
  show_vless_users_for_tag "${tag}"
}

default_next_user_name_for_tag() {
  local tag="$1"
  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == tag:
        print(f"user{len(ib.get('users', [])) + 1}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

add_vless_user_for_tag() {
  local tag="$1"
  require_user_manage_env || return 1

  local user_name user_uuid tmp_file
  user_name="$(prompt_default "请输入用户备注" "$(default_next_user_name_for_tag "${tag}")")"
  user_uuid="$(prompt_default "请输入 UUID" "$(gen_uuid)")"
  tmp_file="${TMP_DIR}/config.add-user.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" "${user_name}" "${user_uuid}" <<'PY'
import json, sys
path, tag, name, uuid = sys.argv[1:]
cfg = json.load(open(path, "r", encoding="utf-8"))

target = next((x for x in cfg.get("inbounds", []) if x.get("type") == "vless" and x.get("tag") == tag), None)
if target is None:
    raise SystemExit("未找到目标 VLESS 入站")

users = target.setdefault("users", [])
if any(u.get("name") == name for u in users):
    raise SystemExit(f"用户备注已存在: {name}")
if any(u.get("uuid") == uuid for u in users):
    raise SystemExit(f"UUID 已存在: {uuid}")

flow = next((str(u.get("flow", "") or "") for u in users if u.get("flow")), "")
reality = ((target.get("tls", {}) or {}).get("reality", {}) or {}).get("enabled") is True
if not flow and reality:
    flow = "xtls-rprx-vision"

new_user = {"name": name, "uuid": uuid}
if flow:
    new_user["flow"] = flow
users.append(new_user)

with open(path, "w", encoding="utf-8") as f:
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
    err "服务重启失败；如存在上一份配置，已尝试自动回滚"
    pause_enter
    return 1
  fi

  ok "用户新增成功：${user_name}（实例 ${tag}）"
  pause_enter
}

add_vless_user() {
  require_user_manage_env || return 1

  local tag
  tag="$(select_vless_instance "请输入要新增用户的 VLESS 实例编号")" || {
    pause_enter
    return 1
  }

  add_vless_user_for_tag "${tag}"
}

delete_vless_user_for_tag() {
  local tag="$1"
  require_user_manage_env || return 1

  echo
  show_vless_users_for_tag "${tag}"
  echo

  local idx tmp_file
  idx="$(prompt_required "请输入要删除的用户编号")"
  if ! confirm_default_no "确认删除该用户吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.del-user.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" "${idx}" <<'PY'
import json, sys
path, tag, idx = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path, "r", encoding="utf-8"))

target = next((x for x in cfg.get("inbounds", []) if x.get("type") == "vless" and x.get("tag") == tag), None)
if target is None:
    raise SystemExit("未找到目标 VLESS 入站")

users = target.get("users", [])
if len(users) <= 1:
    raise SystemExit("至少保留一个用户，不能删除最后一个")
if idx < 1 or idx > len(users):
    raise SystemExit("编号超出范围")

users.pop(idx - 1)
with open(path, "w", encoding="utf-8") as f:
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
    err "服务重启失败；如存在上一份配置，已尝试自动回滚"
    pause_enter
    return 1
  fi

  ok "用户删除成功（实例 ${tag}）"
  pause_enter
}

delete_vless_user() {
  require_user_manage_env || return 1

  local tag
  tag="$(select_vless_instance "请输入要删除用户的 VLESS 实例编号")" || {
    pause_enter
    return 1
  }

  delete_vless_user_for_tag "${tag}"
}

menu_vless_user_management_for_tag() {
  local tag="$1"

  while true; do
    clear
    echo "======================================"
    echo "          VLESS 用户管理"
    echo "======================================"
    echo "实例：${tag}"
    echo
    show_vless_users_for_tag "${tag}"
    echo
    echo "1. 新增用户"
    echo "2. 删除用户"
    echo "3. 刷新用户列表"
    echo "0. 返回"
    echo

    local choice
    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) add_vless_user_for_tag "${tag}" ;;
      2) delete_vless_user_for_tag "${tag}" ;;
      3) ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_user_management() {
  while true; do
    clear
    echo "======================================"
    echo "          VLESS 用户管理"
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
