#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR=${DEVICE_ONBOARD_BIN_DIR:-}
CONFIG_DIR=${DEVICE_ONBOARD_CONFIG_DIR:-"$HOME/.config/device-onboard"}
STATE_FILE="$CONFIG_DIR/config"
KEY_DIR=${DEVICE_ONBOARD_KEY_DIR:-"$HOME/.ssh/device-onboard"}

usage() {
    cat <<'EOF'
用法：sh install.sh [--repair]

首次运行会安装本地命令并进入设备接入设置；再次运行只更新本地命令（不重新接入）。
  --repair   不重新接入：按状态文件重写双方 ~/.ssh/config 的标记块，并把服务器侧的
             设备档案/提示块按当前版本重铺一遍（别名规则变了、新增支持的 harness、
             落点改了 —— 都用它迁移，不用重新接一次）

想彻底拆掉这台设备的接入：device-uninstall（装了什么就删什么）。

支持平台：macOS、Termux（Android）。
环境变量：
  DEVICE_ONBOARD_BIN_DIR            本地命令安装目录（默认 Termux: $PREFIX/bin；macOS: /usr/local/bin）
  DEVICE_ONBOARD_CONFIG_DIR         本地配置目录
  DEVICE_ONBOARD_KEY_DIR            本地密钥目录
  DEVICE_ONBOARD_DEVICE_SSH_PORT    本机 sshd 端口（macOS 默认 22，Termux 默认 8022）
  DEVICE_ONBOARD_REVERSE_PORT_START 反向端口起点（默认 2230，避开手工占用的低位端口）
  DEVICE_ONBOARD_REVERSE_PORT_END   反向端口终点（默认 2299）
  DEVICE_ONBOARD_AGENTS_MD          设为 0 跳过服务器 ~/.codex/AGENTS.md 的设备会话块（默认开启）
  DEVICE_ONBOARD_DSH_MD             设为 0 跳过服务器 ~/.dsh/AGENTS.md 的设备登记块（默认开启）
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

REPAIR=0
case "${1:-}" in
    ''|--)     : ;;
    --help|-h) usage; exit 0 ;;
    --repair)  REPAIR=1 ;;
    *)         die "未知参数：$1（用法见 sh install.sh --help）" ;;
esac
# 平台差异全部收在 detect_platform 里，主流程不区分平台。
PLATFORM=
DEVICE_SSH_PORT=
DEVICE_DEFAULT_NAME=
DEVICE_NEEDS_WAKE_LOCK=0

detect_platform() {
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then
        PLATFORM=termux
        # Termux 无法绑定特权端口，sshd 默认在 8022。
        DEVICE_SSH_PORT=${DEVICE_ONBOARD_DEVICE_SSH_PORT:-8022}
        DEVICE_DEFAULT_NAME=$(getprop ro.product.model 2>/dev/null || true)
        [ -n "$DEVICE_DEFAULT_NAME" ] || DEVICE_DEFAULT_NAME=termux
        DEVICE_NEEDS_WAKE_LOCK=1
    elif [ "$(uname -s)" = "Darwin" ]; then
        PLATFORM=macos
        DEVICE_SSH_PORT=${DEVICE_ONBOARD_DEVICE_SSH_PORT:-22}
        DEVICE_DEFAULT_NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || true)
        [ -n "$DEVICE_DEFAULT_NAME" ] || DEVICE_DEFAULT_NAME=device
    else
        die "不支持的平台：首版只支持 macOS 和 Termux。"
    fi
}

# Termux 上 sshd 就是一个命令，直接起：已经在跑的话它会报“端口被占用”然后退出，无害。
# 这里刻意不做端口探测 —— 按设计文档，“验证必须端到端”，端口在听不等于转发能通。
# macOS 的“远程登录”需要图形界面与管理员权限，脚本无法代劳，只能提示。
ensure_device_sshd() {
    sshd >/dev/null 2>&1 || true
    printf '\n已确保 sshd 在运行（端口 %s）。\n' "$device_port"
}

# 清掉 ~/.ssh/config 里所有 device-onboard 标记块（包括以前跑坏留下的）。
# 必须在发起任何 ssh 之前执行：一个坏块会让之后每一次 ssh 都拒绝启动。
strip_device_onboard_blocks() {
    config="$HOME/.ssh/config"
    [ -f "$config" ] || return 0
    grep -q '^# >>> device-onboard:.* BEGIN$' "$config" 2>/dev/null || return 0
    tmp=$(mktemp)
    awk '
        /^# >>> device-onboard:.* BEGIN$/ { skip = 1; next }
        /^# <<< device-onboard:.* END$/   { skip = 0; next }
        !skip { print }
    ' "$config" > "$tmp"
    cp -p "$config" "$config.device-onboard.bak"
    mv "$tmp" "$config"
    chmod 600 "$config"
    printf '已清理 ~/.ssh/config 里旧的 device-onboard 区块（备份在 config.device-onboard.bak）。\n'
}

# 命令装在本来就处于 PATH 里的目录，否则装完敲不出来：
#   Termux → $PREFIX/bin（Termux 的标准位置，必在 PATH 里）
#   macOS  → /usr/local/bin（系统标准位置）；不可写再退回 ~/.local/bin
default_bin_dir() {
    if [ "$PLATFORM" = "termux" ] && [ -n "${PREFIX:-}" ] && [ -w "${PREFIX}/bin" ]; then
        printf '%s' "${PREFIX}/bin"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        printf '%s' /usr/local/bin
    else
        printf '%s' "$HOME/.local/bin"
    fi
}

detect_platform
[ -n "$BIN_DIR" ] || BIN_DIR=$(default_bin_dir)
command -v ssh >/dev/null 2>&1 || die "找不到 ssh。"
command -v ssh-keygen >/dev/null 2>&1 || die "找不到 ssh-keygen。"
[ -n "$DEVICE_SSH_PORT" ] || die "无法确定设备 SSH 端口。"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$KEY_DIR"
chmod 700 "$CONFIG_DIR" "$KEY_DIR"
copy_command() {
    # 不用 install(1)：Termux 基础环境不保证有这个命令。
    cp -f "$1" "$2"
    chmod 755 "$2"
}
copy_command "$PROJECT_DIR/bin/device-tunnel" "$BIN_DIR/device-tunnel"
copy_command "$PROJECT_DIR/bin/device-harness" "$BIN_DIR/device-harness"
copy_command "$PROJECT_DIR/bin/device-uninstall" "$BIN_DIR/device-uninstall"

# 装的目录若不在 PATH 里，明说怎么加 —— 别让人对着 command not found 发懵。
case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *)
        printf '提示：%s 不在 PATH 里，新开的终端可能敲不到 device-tunnel。\n' "$BIN_DIR"
        printf '      在 shell 配置里加一行：export PATH="%s:$PATH"\n' "$BIN_DIR"
        ;;
esac

# ---------- ssh config 的标记块：全项目唯一一份模板 ----------
# 设备侧只写一个 Host：进服务器的入口，别名就叫 `server`。每台设备只对一台服务器，
# 再把设备名后缀贴上去纯属噪音，敲起来还长。
# 反向隧道**不再单独占一个 Host**：端口从状态文件读、-R 在 device-tunnel 里现场拼。
# 写进 ssh config 等于同一个端口存两份（config 一份、状态文件一份），一旦分叉症状
# 还很隐蔽 —— 隧道绑在旧端口、台账登记的是新端口。
# 服务器侧仍写 onboard-device-<id>：那是给服务器上的 agent 用的，它得有个名字能直接连。
local_ssh_block() {
    _b="# >>> device-onboard:$device_id BEGIN"
    _e="# <<< device-onboard:$device_id END"
    cat <<EOF
$_b
Host $server_alias
    HostName $server_host
    User $server_user
    Port $server_port
    IdentityFile $device_key
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
$_e
EOF
}

remote_ssh_block() {
    _b="# >>> device-onboard:$device_id BEGIN"
    _e="# <<< device-onboard:$device_id END"
    cat <<EOF
$_b
Host $device_alias
    HostName 127.0.0.1
    User $device_user
    Port $reverse_port
    IdentityFile ~/.ssh/device-onboard/${device_id}-server
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
$_e
EOF
}

# 到服务器的 ssh 统一走这里：server_host / server_user / server_port / device_key
# 在进入向导后设好（device-uninstall 里有它自己的一份）。
server_ssh() {
    ssh -i "$device_key" -o IdentitiesOnly=yes -p "$server_port" "$server_user@$server_host" "$@"
}

# 只动自己的标记块：块内整体重写，块外一个字节不碰，改前备份。
write_local_ssh_block() {
    _cfg="$HOME/.ssh/config"
    _b="# >>> device-onboard:$device_id BEGIN"
    _e="# <<< device-onboard:$device_id END"
    mkdir -p "$HOME/.ssh"
    _tmp=$(mktemp) || die "无法创建临时文件。"
    if [ -f "$_cfg" ]; then
        awk -v b="$_b" -v e="$_e" '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}' "$_cfg" > "$_tmp"
        cp "$_cfg" "$_cfg.device-onboard.bak"
        # 撞名必须明说：ssh 以先匹配到的 Host 为准，我们的块在文件末尾，
        # 撞了就永远轮不到 —— 不报错，但行为完全不是用户以为的那个。
        if awk -v a="$server_alias" '
            /^[ \t]*[Hh]ost[ \t]/ { for (i = 2; i <= NF; i++) if ($i == a) hit = 1 }
            END { exit hit ? 0 : 1 }' "$_tmp"; then
            printf '⚠️ %s 里已经有 Host %s（在 device-onboard 区块之外）。\n' "$_cfg" "$server_alias"
            printf '   ssh 会先用你手写的那份，本项目的连接不会生效。先改掉你那份，再重跑 sh install.sh。\n'
        fi
    fi
    local_ssh_block >> "$_tmp"
    mv "$_tmp" "$_cfg"
    chmod 600 "$_cfg"
}

write_remote_ssh_block() {
    _b="# >>> device-onboard:$device_id BEGIN"
    _e="# <<< device-onboard:$device_id END"
    remote_ssh_block | server_ssh "set -eu; file=\"\$HOME/.ssh/config\"; tmp=\"\$(mktemp)\"; mkdir -p \"\$HOME/.ssh\"; if [ -f \"\$file\" ]; then awk -v begin='$_b' -v end='$_e' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' \"\$file\" > \"\$tmp\"; cp \"\$file\" \"\$file.device-onboard.bak\"; else : > \"\$tmp\"; fi; cat >> \"\$tmp\"; mv \"\$tmp\" \"\$file\"; chmod 600 \"\$file\""
}


# ---------- --repair：按状态文件重写双方的标记块 ----------
# 存在的理由：别名规则会演进（去掉 onboard-tunnel-*、把服务器入口改名 server），
# 而「已有配置」那条路径刻意不碰 ~/.ssh/config —— 于是老设备上的旧块会一直留着。
# --repair 补这个口：不重新接入、不动密钥、不重发公钥，只把标记块换成当前版本的样子。
repair_ssh_blocks() {
    device_id=${DEVICE_ID:-}
    device_name=${DEVICE_NAME:-}
    server_host=${SERVER_HOST:-}
    server_user=${SERVER_USER:-}
    server_port=${SERVER_PORT:-}
    device_port=${DEVICE_PORT:-}
    reverse_port=${REVERSE_PORT:-}
    device_user=${DEVICE_USER:-}
    device_key=${DEVICE_KEY:-}
    server_alias=server
    device_alias="onboard-device-$device_id"

    [ -n "$device_id" ]   || die "状态文件里没有 DEVICE_ID。"
    [ -n "$device_name" ] || device_name=$device_id
    [ -n "$server_host" ] || die "状态文件里没有 SERVER_HOST。"
    [ -n "$server_user" ] || die "状态文件里没有 SERVER_USER。"
    [ -n "$server_port" ] || die "状态文件里没有 SERVER_PORT。"
    [ -n "$device_user" ] || die "状态文件里没有 DEVICE_USER。"
    [ -n "$device_key" ]  || die "状态文件里没有 DEVICE_KEY。"
    [ -f "$device_key" ]  || die "设备密钥不在了：${device_key}（只有重跑接入才能重建）。"
    # 端口要进 ssh config：非数字会让之后所有 ssh 直接罢工。
    case "$reverse_port" in ''|*[!0-9]*) die "状态文件里的 REVERSE_PORT 不是数字：'$reverse_port'。" ;; esac
    case "$device_port"  in ''|*[!0-9]*) die "状态文件里的 DEVICE_PORT 不是数字：'$device_port'。" ;; esac

    printf '\n按状态文件重写 ssh config 标记块（设备 %s）…\n' "$device_id"
    write_local_ssh_block
    printf '✅ 设备侧：Host %s（进服务器）\n' "$server_alias"
    if write_remote_ssh_block; then
        printf '✅ 服务器侧：Host %s（服务器回连设备）\n' "$device_alias"
    else
        printf '⚠️ 服务器侧写入失败（连不上？），已跳过 —— 设备侧不受影响。\n' >&2
    fi
    # 顺手把服务器侧的设备档案/提示块也按当前版本重铺一遍：落点变了、或者新增了
    # 支持的 harness（比如 dsh），就不必为此重新接一次。
    printf '\n刷新服务器侧的设备档案与提示块…\n'
    install_server_view

    # 状态文件里的别名是配置块的「不完整副本」，一并纠正 —— 否则下一次
    # sh install.sh 还会照着旧别名打印用法提示，指到一个已经不存在的 Host。
    if [ -f "$STATE_FILE" ]; then
        _tmp_state=$(mktemp) || die "无法创建临时文件。"
        grep -v -e '^SERVER_HOST_ALIAS=' -e '^TUNNEL_HOST_ALIAS=' -e '^DEVICE_HOST_ALIAS=' "$STATE_FILE" > "$_tmp_state" || true
        printf 'SERVER_HOST_ALIAS=%s\nDEVICE_HOST_ALIAS=%s\n' "$server_alias" "$device_alias" >> "$_tmp_state"
        chmod 600 "$_tmp_state"
        mv "$_tmp_state" "$STATE_FILE"
        printf '✅ 状态文件已同步别名：%s / %s\n' "$server_alias" "$device_alias"
    fi
}

# ---------- 「已有配置」：重跑只更新命令，不重新接入 ----------
# 这条路径绝不能碰 ~/.ssh/config：配置块是「产物」，状态文件才是「源」。
# 清掉却重建不出来，就把已经接好的设备弄瘸了。要重写块就用 --repair。
# ---------- 服务器侧：设备视图（同路径挂载 + shell 转发），取代原来的 skill/AGENTS 提示 ----------
# 落地的四样东西（都在 /opt/device-onboard，靠 sudo 装）：
#   real-sh     一份私有的 POSIX 壳副本 —— 垫片的 shebang 只能指向它，
#               因为 /bin/sh 在会话命名空间里会被 bind 成垫片自己（否则 ELOOP）
#   shim/*      转发垫片（sh/bash/zsh 三个名字），把命令送进设备
#   device-view 会话级启动器：建命名空间 → 挂同路径 → 起 harness
# 以及一个挂载点：设备的家目录，按**相同绝对路径**建在服务器上。
# 老方案（SKILL.md / AGENTS.md / CLAUDE.md / ~/.dsh/AGENTS.md 的提示块）就地清掉 ——
# 留着会让 agent 继续被叫去 "ssh onboard-device-x"，和新方案打架。
install_server_view() {
    _script=$(cat <<SV_HEAD
set -u
sudo -n true 2>/dev/null || { echo NO_SUDO; exit 0; }
ROOT=/opt/device-onboard
if ! command -v sshfs >/dev/null 2>&1; then
    sudo -n apt-get install -y -qq sshfs >/dev/null 2>&1 || { echo NO_SSHFS; exit 0; }
fi
command -v sshfs >/dev/null 2>&1 || { echo NO_SSHFS; exit 0; }
sudo -n mkdir -p "\$ROOT/shim" >/dev/null 2>&1 || { echo FAIL_MKDIR; exit 0; }
sudo -n chown -R "\$(id -un):\$(id -gn)" "\$ROOT" 2>/dev/null
cp /bin/dash "\$ROOT/real-sh"
cat > "\$ROOT/shim/bash" <<'SHIM'
#!/opt/device-onboard/real-sh
# 把「跑一条命令」转发到设备上执行。只在这个会话的命名空间里生效。
set -u
ALIAS=\${DEVICE_ONBOARD_VIEW_ALIAS:?device-view 没有传别名}
squote() { printf "'%s'" "\$(printf '%s' "\$1" | sed "s/'/'\\\\\\\\''/g")"; }
shell=\${0##*/}
cmd=
for a in "\$@"; do cmd="\$cmd \$(squote "\$a")"; done
exec ssh -T -o BatchMode=yes -o ControlMaster=auto -o ControlPersist=300 \\
     -o "ControlPath=/tmp/device-onboard-view-%C" \\
     "\$ALIAS" "cd \$(squote "\${PWD:-/}") 2>/dev/null; exec \$shell\$cmd"
SHIM
cp "\$ROOT/shim/bash" "\$ROOT/shim/sh"
cp "\$ROOT/shim/bash" "\$ROOT/shim/zsh"
echo 'IyEvYmluL3NoCiMgZGV2aWNlLXZpZXcg4oCU4oCUIOWcqOacjeWKoeWZqOS4iue7meOAjOi/nOeoi+S8muivneOAjeW8gOS4gOS4quiuvuWkh+inhuWbvuOAggojCiMg5LiJ5Lu25LqL77yMKirlhajpg73lj6rlnKjov5nkuKrkvJror53oh6rlt7HnmoTlkb3lkI3nqbrpl7Tph4znlJ/mlYgqKu+8jOS8muivnee7k+adn+WwseS4gOi1t+a2iOWkse+8mgojICAg4pGgIOaKiuiuvuWkh+WutuebruW9leaMieOAjOebuOWQjOe7neWvuei3r+W+hOOAjeaMgui/m+adpe+8iHNzaGZzIOi1sOWPjeWQkemap+mBk++8iQojICAg4pGhIOaKiiAvdXNyL2Jpbi97YmFzaCx6c2h9IOaNouaIkOi9rOWPkeWIsOiuvuWkh+eahOWeq+eJhwojICAg4pGiIOWcqOi/meS4quinhuWbvumHjOaJp+ihjOe7meWumuWRveS7pO+8iGhhcm5lc3PvvIkKIwojIOeUqOazle+8iOWcqOacjeWKoeWZqOS4iui3ke+8ie+8mgojICAgZGV2aWNlLXZpZXcgWy0tYWxpYXMgPOWbnui/niBIb3N0IOWIq+WQjT5dIFstQyA855uu5b2VPl0gLS0gPOWRveS7pOKApj4KIwojIOmcgOimge+8mnNzaGZz44CBL2Rldi9mdXNl44CB5pS+6KGM55qEIHVucHJpdmlsZWdlZCB1c2VybnPvvJvmjILovb3ngrnopoHkuovlhYjnlLEgaW5zdGFsbC5zaCDlu7rlpb3jgIIKc2V0IC1ldQoKUk9PVD0ke0RFVklDRV9PTkJPQVJEX1ZJRVdfUk9PVDotL29wdC9kZXZpY2Utb25ib2FyZH0KQUxJQVM9CkRJUj0Kd2hpbGUgWyAiJCMiIC1ndCAwIF07IGRvCiAgICBjYXNlICIkMSIgaW4KICAgICAgICAtLWFsaWFzKSBBTElBUz0kezI6Py0tYWxpYXMg5ZCO6Z2i6KaB6Lef5Yir5ZCNfTsgc2hpZnQgMiA7OwogICAgICAgIC1DKSAgICAgIERJUj0kezI6Py1DIOWQjumdouimgei3n+ebruW9lX07IHNoaWZ0IDIgOzsKICAgICAgICAtLSkgICAgICBzaGlmdDsgYnJlYWsgOzsKICAgICAgICAqKSAgICAgICBicmVhayA7OwogICAgZXNhYwpkb25lClsgIiQjIiAtZ3QgMCBdIHx8IHsgcHJpbnRmICfplJnor6/vvJpkZXZpY2UtdmlldyAtLSA85ZG95Luk4oCmPlxuJyA+JjI7IGV4aXQgMjsgfQpbIC1uICIkQUxJQVMiIF0gfHwgQUxJQVM9JHtERVZJQ0VfT05CT0FSRF9ERVZJQ0VfQUxJQVM6LX0KWyAtbiAiJEFMSUFTIiBdIHx8IHsgcHJpbnRmICfplJnor6/vvJrmsqHmnIkgLS1hbGlhc++8jOS5n+ayoeaciSBERVZJQ0VfT05CT0FSRF9ERVZJQ0VfQUxJQVPjgIJcbicgPiYyOyBleGl0IDI7IH0KCmZvciBmIGluICIkUk9PVC9yZWFsLXNoIiAiJFJPT1Qvc2hpbS9iYXNoIiAiJFJPT1Qvc2hpbS96c2giOyBkbwogICAgWyAteCAiJGYiIF0gfHwgeyBwcmludGYgJ+mUmeivr++8mue8uuWwkSAlc++8jOWFiOi3kSBpbnN0YWxsLnNo44CCXG4nICIkZiIgPiYyOyBleGl0IDE7IH0KZG9uZQpjb21tYW5kIC12IHNzaGZzID4vZGV2L251bGwgMj4mMSB8fCB7IHByaW50ZiAn6ZSZ6K+v77ya5pyN5Yqh5Zmo5LiK5rKh5pyJIHNzaGZz77yIc3VkbyBhcHQtZ2V0IGluc3RhbGwgLXkgc3NoZnPvvInjgIJcbicgPiYyOyBleGl0IDE7IH0KCiMg5oyC6L2954K5ID0g6K6+5aSH55qE5a6255uu5b2V77yI5ZCM6Lev5b6E77yJ44CC6Zeu6K6+5aSH5LiA5qyh77yM5LiN54yc44CCCkRFVklDRV9IT01FPSQoc3NoIC1vIEJhdGNoTW9kZT15ZXMgLW8gQ29ubmVjdFRpbWVvdXQ9MTAgIiRBTElBUyIgJ3ByaW50ZiAlcyAiJEhPTUUiJyAyPi9kZXYvbnVsbCkgfHwgewogICAgcHJpbnRmICfplJnor6/vvJrov57kuI3kuIrorr7lpIfvvIglc++8ieKAlOKAlCDmo4Dmn6Xlj43lkJHpmqfpgZPmmK/lkKblnKjot5HjgIJcbicgIiRBTElBUyIgPiYyOyBleGl0IDE7IH0KWyAtbiAiJERFVklDRV9IT01FIiBdIHx8IHsgcHJpbnRmICfplJnor6/vvJrlj5bkuI3liLDorr7lpIfnmoTlrrbnm67lvZXjgIJcbicgPiYyOyBleGl0IDE7IH0KWyAtbiAiJERJUiIgXSB8fCBESVI9JERFVklDRV9IT01FCgpleHBvcnQgREVWSUNFX09OQk9BUkRfVklFV19BTElBUz0kQUxJQVMKZXhlYyB1bnNoYXJlIC1Vcm0gLS1tYXAtcm9vdC11c2VyIHNoIC1zIC0tICIkUk9PVCIgIiRBTElBUyIgIiRERVZJQ0VfSE9NRSIgIiRESVIiICIkQCIgPDwnSU5ORVInCnNldCAtZXUKUk9PVD0kMTsgQUxJQVM9JDI7IE1OVD0kMzsgQ1dEPSQ0OyBzaGlmdCA0ClJFQUxfSE9NRT0kSE9NRQoKIyDikaAg6K6pIGdldHB3dWlkKDApIOeahOWutuebruW9leaMh+WQkeecn+WunueUqOaIt+eahOWutgojICAgIO+8iG5zIOmHjOaIkeS7rOaYryB1aWQgMO+8jOWQpuWImSBzc2gg5Lya5Y67IC9yb290IOaJviBjb25maWcgLyBrbm93bl9ob3N0cyAvIOengemSpe+8iQpta2RpciAtcCAvdG1wL2Rvdmlldy4kJApzZWQgJ3N8Xlwocm9vdDp4OjA6MDpyb290OlwpL3Jvb3Q6fFwxJyIkUkVBTF9IT01FIic6fCcgL2V0Yy9wYXNzd2QgPiAvdG1wL2Rvdmlldy4kJC9wYXNzd2QKbW91bnQgLS1iaW5kIC90bXAvZG92aWV3LiQkL3Bhc3N3ZCAvZXRjL3Bhc3N3ZAoKIyDikaEgc2hlbGwg5pu/5o2i77ya5Y+q5b2x5ZON5pys5ZG95ZCN56m66Ze044CC5a6/5Li75LiK55qEIC91c3IvYmluL2Jhc2gg5LiA5Liq5a2X6IqC6YO95rKh5Yqo44CCCiMgICAg5Lik5p2h6Lev6YO96KaB5aC177ya5oyJ5ZCN5a2X5LuOIFBBVEgg5om+55qE77yIY2xhdWRlIOeUqCBzaCAtY++8ie+8jOWSjOi1sOe7neWvuei3r+W+hOeahO+8iGNvZGV4IOeUqCAvdXNyL2Jpbi9iYXNoIC1sY++8ieOAggpmb3IgcyBpbiBiYXNoIHpzaDsgZG8KICAgIFsgLWUgIi91c3IvYmluLyRzIiBdICYmIG1vdW50IC0tYmluZCAiJFJPT1Qvc2hpbS8kcyIgIi91c3IvYmluLyRzIgpkb25lClBBVEg9IiRST09UL3NoaW06JFBBVEgiOyBleHBvcnQgUEFUSApjZCAiJFJFQUxfSE9NRSIgMj4vZGV2L251bGwgfHwgdHJ1ZQoKIyDikaEg5ZCM6Lev5b6E5oyC6L29Cm1rZGlyIC1wICIkTU5UIgpzc2hmcyAtbyByZWNvbm5lY3QsU2VydmVyQWxpdmVJbnRlcnZhbD0xMCxTZXJ2ZXJBbGl2ZUNvdW50TWF4PTMgLW8gYXV0b191bm1vdW50IFwKICAgICAgIiRBTElBUzokTU5UIiAiJE1OVCIgJgpTRlNfUElEPSQhCmNsZWFudXAoKSB7CiAgICB1bW91bnQgIiRNTlQiIDI+L2Rldi9udWxsIHx8IGZ1c2VybW91bnQzIC11ICIkTU5UIiAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgICBraWxsICIkU0ZTX1BJRCIgMj4vZGV2L251bGwgfHwgdHJ1ZQp9CnRyYXAgY2xlYW51cCBFWElUIElOVCBURVJNCgojIOWwsee7quS/oeWPt++8mueci+Wug+aYr+S4jeaYr+ecn+eahOaMguS4iuS6hu+8jOS4jeeci+i/m+eoi+WcqOS4jeWcqAppPTAKd2hpbGUgWyAiJGkiIC1sdCAxMDAgXTsgZG8KICAgIG1vdW50cG9pbnQgLXEgIiRNTlQiICYmIGJyZWFrCiAgICBraWxsIC0wICIkU0ZTX1BJRCIgMj4vZGV2L251bGwgfHwgeyBwcmludGYgJ+mUmeivr++8mnNzaGZzIOmAgOWHuuS6hu+8jOaMgui9veWksei0peOAglxuJyA+JjI7IGV4aXQgMTsgfQogICAgc2xlZXAgMC4xOyBpPSQoKGkgKyAxKSkKZG9uZQptb3VudHBvaW50IC1xICIkTU5UIiB8fCB7IHByaW50ZiAn6ZSZ6K+v77ya562J5LiN5Yiw5oyC6L295bCx5L2N77yIJXPvvInjgIJcbicgIiRNTlQiID4mMjsgZXhpdCAxOyB9CgojIOKRoiDlnKjorr7lpIfpgqPkuIDkvqfnmoTlkIzot6/lvoTnm67lvZXph4zot5EKY2QgIiRDV0QiIDI+L2Rldi9udWxsIHx8IGNkICIkTU5UIgoiJEAiCklOTkVSCg==' | base64 -d > "\$ROOT/device-view"
chmod 755 "\$ROOT/real-sh" "\$ROOT/shim/bash" "\$ROOT/shim/sh" "\$ROOT/shim/zsh" "\$ROOT/device-view"
# 挂载点：设备家目录的同路径（设备侧跑 install.sh，所以 \$HOME 就是它）
sudo -n mkdir -p "$HOME" >/dev/null 2>&1 && sudo -n chown "\$(id -un):\$(id -gn)" "$HOME" 2>/dev/null
# 清掉老方案留下的提示块
strip() {
    f="\$1"; b="\$2"; e="\$3"
    [ -f "\$f" ] || return 0
    grep -qF "\$b" "\$f" 2>/dev/null || return 0
    t=\$(mktemp); awk -v b="\$b" -v e="\$e" '\$0==b{skip=1;next} \$0==e{skip=0;next} !skip{print}' "\$f" > "\$t" && mv "\$t" "\$f"
}
for id in $device_id; do
  strip "\$HOME/.codex/AGENTS.md" '<!-- DEVICE-ONBOARD-AGENTS BEGIN -->' '<!-- DEVICE-ONBOARD-AGENTS END -->'
  strip "\$HOME/.claude/CLAUDE.md" '<!-- DEVICE-ONBOARD-CLAUDE BEGIN -->' '<!-- DEVICE-ONBOARD-CLAUDE END -->'
  strip "\$HOME/.dsh/AGENTS.md" "<!-- DEVICE-ONBOARD:\$id BEGIN -->" "<!-- DEVICE-ONBOARD:\$id END -->"
  for f in "\$HOME/.codex/skills/device-onboard/SKILL.md" "\$HOME/.claude/skills/device-onboard/SKILL.md"; do
    strip "\$f" "<!-- DEVICE-ONBOARD:\$id BEGIN -->" "<!-- DEVICE-ONBOARD:\$id END -->"
    [ -f "\$f" ] && ! grep -q '^<!-- DEVICE-ONBOARD:' "\$f" && rm -f "\$f"
  done
done
echo INSTALLED
SV_HEAD
)
    _out=$(printf '%s\n' "$_script" | server_ssh 'sh -s' 2>&1 || true)
    case "$_out" in
        *INSTALLED*) printf '✅ 服务器侧设备视图已就位（/opt/device-onboard，挂载点 %s）\n' "$HOME" ;;
        *NO_SUDO*)   printf '⚠️ 服务器上没有免密 sudo，装不了设备视图；会话会退回「普通远程会话」。\n   要启用：先在服务器上执行一次 sudo -v，或用 device-harness --no-device-view 显式关掉。\n' >&2 ;;
        *NO_SSHFS*)  printf '⚠️ 服务器上装不了 sshfs（sudo apt-get install -y sshfs 失败），设备视图将不可用。\n' >&2 ;;
        *)           printf '⚠️ 写服务器侧设备视图失败，会话会退回「普通远程会话」。\n   输出：%s\n' "$_out" >&2 ;;
    esac
    return 0
}

if [ -f "$STATE_FILE" ]; then
    printf '本地命令已更新。已有设备配置，跳过首次接入。\n'
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    if [ "$REPAIR" = 1 ]; then
        repair_ssh_blocks
        exit 0
    fi
    if ! grep -qF "# >>> device-onboard:$DEVICE_ID BEGIN" "$HOME/.ssh/config" 2>/dev/null; then
        printf '\n⚠️ %s 里找不到本设备（%s）的配置块，device-tunnel 会解析不到主机。\n' "$HOME/.ssh/config" "$DEVICE_ID"
        printf '   修复：sh install.sh --repair 只重写配置块（不动密钥、不重新接入）；\n'
        printf '         或者彻底重接：device-uninstall 之后重跑 sh install.sh\n'
    fi
    printf '日常命令：device-harness（一键：隧道 + harness）、device-tunnel；在服务器上跑命令：ssh %s <命令>\n' "$SERVER_HOST_ALIAS"
    printf '想换别名/重写配置块：sh install.sh --repair；想彻底拆掉：device-uninstall\n'
    exit 0
fi

if [ "$REPAIR" = 1 ]; then
    die "--repair 需要已有接入配置（$STATE_FILE 不存在）。首次接入直接跑 sh install.sh。"
fi

# ---------- 失败回滚（仅首次接入路径） ----------
# 设计裁决：按标记撤销本次新增内容 + 用备份还原已有配置，不引入事务日志/状态机。
# 任何一步失败（die、set -e、Ctrl-C）都由 EXIT trap 收尾；成功时先置 INSTALL_OK=1 跳过回滚。
ROLLBACK_ARMED=0
ROLLBACK_DONE=0
INSTALL_OK=0
DEVICE_KEY_CREATED=0
SERVER_KEY_CREATED=0
SKILL_WAS_NEW=0
device_id=
device_key=
tunnel_pid=
probe_log=

cleanup_tunnel() {
    if [ -n "${tunnel_pid:-}" ]; then
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
    if [ -n "${probe_log:-}" ]; then
        rm -f "$probe_log" 2>/dev/null || true
    fi
}

rollback_note() { printf '  %s\n' "$*"; }

# 只去掉本设备的块；返回 0 表示确实去掉了。
strip_local_device_block() {
    _cfg="$HOME/.ssh/config"
    [ -f "$_cfg" ] || return 1
    _begin="# >>> device-onboard:$device_id BEGIN"
    grep -qF "$_begin" "$_cfg" 2>/dev/null || return 1
    _tmp=$(mktemp) || return 1
    awk -v b="$_begin" -v e="# <<< device-onboard:$device_id END" \
        '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}' "$_cfg" > "$_tmp"
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$_cfg"
    return 0
}

rollback_local_config() {
    _cfg="$HOME/.ssh/config"
    if strip_local_device_block; then
        rollback_note "已从 ~/.ssh/config 去掉本设备（${device_id}）的配置块。"
    else
        rollback_note "本机 ~/.ssh/config 中没有本设备的配置块（无需去掉）。"
    fi
    if [ -f "$_cfg.device-onboard.bak" ]; then
        if cp -p "$_cfg.device-onboard.bak" "$_cfg" 2>/dev/null; then
            chmod 600 "$_cfg" 2>/dev/null || true
            rollback_note "已用备份还原 ~/.ssh/config。"
        else
            rollback_note "警告：还原 ~/.ssh/config 备份失败。"
        fi
    fi
}

rollback_local_authorized_keys() {
    _ak="$HOME/.ssh/authorized_keys"
    [ -f "$_ak" ] || return 0
    grep -qF "device-onboard:$device_id" "$_ak" 2>/dev/null || return 0
    _tmp="$_ak.rollback.$$"
    if grep -vF "device-onboard:$device_id" "$_ak" > "$_tmp" 2>/dev/null; then
        chmod 600 "$_tmp" 2>/dev/null || true
        mv "$_tmp" "$_ak"
        rollback_note "已从本机 authorized_keys 去掉本设备的密钥行。"
    else
        rm -f "$_tmp" 2>/dev/null || true
        rollback_note "警告：清理本机 authorized_keys 失败。"
    fi
}

rollback_local_key() {
    if [ "$DEVICE_KEY_CREATED" = 1 ] && [ -n "$device_key" ]; then
        rm -f "$device_key" "$device_key.pub" 2>/dev/null || true
        rollback_note "已删除本次生成的设备密钥（${device_key}）。"
    fi
}

# 远端回滚脚本通过 stdin 管道送过去，避免多层转义把命令拼错。
rollback_server() {
    if [ -z "$device_id" ] || [ ! -f "$device_key" ] || ! command -v server_ssh >/dev/null 2>&1; then
        rollback_note "本机设备密钥或服务器连接不可用，跳过服务器端回滚（请登录服务器手动检查）。"
        return 0
    fi
    _out=$(cat <<ROLLBACK_EOF | server_ssh 'sh -s' 2>&1
set +e
cfg="\$HOME/.ssh/config"
if [ -f "\$cfg.device-onboard.bak" ]; then
    cp -p "\$cfg.device-onboard.bak" "\$cfg" 2>/dev/null && chmod 600 "\$cfg" 2>/dev/null && echo RESTORED_SSH_CONFIG
fi
if [ -f "\$cfg" ] && grep -qF "# >>> device-onboard:$device_id BEGIN" "\$cfg" 2>/dev/null; then
    t=\$(mktemp)
    awk -v b="# >>> device-onboard:$device_id BEGIN" -v e="# <<< device-onboard:$device_id END" '\$0==b{skip=1;next} \$0==e{skip=0;next} !skip{print}' "\$cfg" > "\$t"
    mv "\$t" "\$cfg" 2>/dev/null; chmod 600 "\$cfg" 2>/dev/null
    echo STRIPPED_SSH_CONFIG
fi
ak="\$HOME/.ssh/authorized_keys"
if [ -f "\$ak" ] && grep -qF "device-onboard:$device_id" "\$ak" 2>/dev/null; then
    # 用 awk 而不是 grep -v：每行都匹配时 grep -v 返回 1，后面的 mv 就不会执行 ——
    # 文件原样留着，回滚却报「已撤回」。（这里也不能出现反引号：未引号 heredoc）
    awk -v pat="device-onboard:$device_id" 'index(\$0, pat) == 0' "\$ak" > "\$ak.rollback" && mv "\$ak.rollback" "\$ak" && chmod 600 "\$ak" 2>/dev/null && echo REMOVED_AUTHORIZED_KEY
fi
# 记忆文件（~/.codex/AGENTS.md、~/.claude/CLAUDE.md）刻意不回滚：用户裁决，
# 提示块是「无害的说明书」，留着比半路摘掉更安全。
for skill in "\$HOME/.codex/skills/device-onboard/SKILL.md" "\$HOME/.claude/skills/device-onboard/SKILL.md"; do
    if [ "$SKILL_WAS_NEW" = 1 ]; then
        if [ -f "\$skill" ]; then rm -f "\$skill" && echo REMOVED_SKILL_FILE; fi
    elif [ -f "\$skill" ] && grep -qF "<!-- DEVICE-ONBOARD:$device_id BEGIN -->" "\$skill" 2>/dev/null; then
        t=\$(mktemp)
        awk -v b="<!-- DEVICE-ONBOARD:$device_id BEGIN -->" -v e="<!-- DEVICE-ONBOARD:$device_id END -->" '\$0==b{skip=1;next} \$0==e{skip=0;next} !skip{print}' "\$skill" > "\$t"
        mv "\$t" "\$skill" 2>/dev/null; chmod 600 "\$skill" 2>/dev/null
        echo STRIPPED_SKILL_BLOCK
    fi
done
if [ "$SERVER_KEY_CREATED" = 1 ]; then
    rm -f "\$HOME/.ssh/device-onboard/${device_id}-server" "\$HOME/.ssh/device-onboard/${device_id}-server.pub" 2>/dev/null && echo REMOVED_SERVER_KEY
fi
ROLLBACK_EOF
)
    if [ -n "$_out" ]; then
        rollback_note "服务器端回滚返回："
        printf '%s\n' "$_out"
    else
        rollback_note "警告：服务器端回滚无输出（可能连接失败），请登录服务器手动检查。"
    fi
}

perform_rollback() {
    ROLLBACK_DONE=1
    printf '\n接入未完成，开始回滚本次改动……\n'
    rollback_server
    rollback_local_config
    rollback_local_authorized_keys
    rollback_local_key
    if [ -f "$CONFIG_DIR/server-key.pub" ]; then
        rm -f "$CONFIG_DIR/server-key.pub" 2>/dev/null || true
        rollback_note "已删除本次取回的服务器公钥副本。"
    fi
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE" 2>/dev/null || true
        rollback_note "已删除本地状态文件。"
    fi
    printf '回滚完成。可能未撤净：服务器主机指纹记录、ssh-agent 中的密钥、失败点之前的远端临时文件。\n'
}

on_exit() {
    _status=$?
    trap - EXIT INT TERM
    set +e
    cleanup_tunnel
    if [ "$ROLLBACK_ARMED" = 1 ] && [ "$INSTALL_OK" != 1 ] && [ "$ROLLBACK_DONE" != 1 ]; then
        perform_rollback
        _status=1
    fi
    exit "$_status"
}
# ------------------------------------------------

# 只有真要重新接入时才动配置：先清掉自己以前留下的块（可能带着坏值），再做体检。
# 顺序不能反 —— 坏块会让体检直接报错。
strip_device_onboard_blocks

# 已经进入首次接入：从此任何失败都由 EXIT trap 回滚本次改动。
ROLLBACK_ARMED=1
trap 'on_exit' EXIT INT TERM

# 早发现早报错：~/.ssh/config 里若有坏行，之后每一次 ssh 都会失败，
# 而报错指向的是那一行 —— 很容易让人误以为是本次操作搞坏的。
if [ -f "$HOME/.ssh/config" ] && ! ssh -G -o BatchMode=yes localhost >/dev/null 2>&1; then
    printf '警告：当前的 ~/.ssh/config 无法正常解析，请先修好它，否则后面所有 ssh 都会失败。\n' >&2
    printf '      查看具体报错：ssh -G localhost\n' >&2
fi

printf '\n设备接入设置\n\n'
printf '1) 配置设备与服务器的 SSH 连接\n'
printf '0) 退出\n\n'
printf '请选择：'
read -r choice
# 用户在菜单直接退出：本次没有新增任何接入产物，视为正常结束，不走回滚
# （否则会还原备份，把 strip 刚清掉的旧坏块又装回去）。
[ "$choice" = "1" ] || { INSTALL_OK=1; exit 0; }

default_name=$DEVICE_DEFAULT_NAME
printf '设备名称 [%s]：' "$default_name"
read -r device_name
device_name=${device_name:-$default_name}
[ -n "$device_name" ] || die "设备名称不能为空。"

printf '服务器地址（IP 或域名）：'
read -r server_host
[ -n "$server_host" ] || die "服务器地址不能为空。"
printf '服务器 SSH 用户名：'
read -r server_user
[ -n "$server_user" ] || die "服务器用户名不能为空。"
printf '服务器 SSH 端口 [22]：'
read -r server_port
server_port=${server_port:-22}
case "$server_port" in *[!0-9]*|'') die "服务器端口必须是数字。";; esac

device_user=$(id -un)
device_port=$DEVICE_SSH_PORT
device_id=$(printf '%s' "$device_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
device_id=${device_id#-}; device_id=${device_id%-}
[ -n "$device_id" ] || die "设备名称无法生成有效 ID。"
server_target="$server_user@$server_host"
device_key="$KEY_DIR/${device_id}-device"
server_key_relative=".ssh/device-onboard/${device_id}-server"
server_pub_relative="$server_key_relative.pub"

if [ "$PLATFORM" = "termux" ]; then
    ensure_device_sshd
else
    printf '\n请确认 macOS 已开启“远程登录”，否则服务器无法回连本机。\n'
fi

mkdir -p "$HOME/.ssh" "$KEY_DIR"
chmod 700 "$HOME/.ssh" "$KEY_DIR"
if [ ! -f "$device_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$device_key" -C "device-onboard:$device_id"
    DEVICE_KEY_CREATED=1
fi
chmod 600 "$device_key"

device_pub=$(cat "$device_key.pub")
printf '\n首次 SSH 连接将由系统提示确认主机指纹或输入密码。\n'
printf '%s\n' "$device_pub" | ssh -p "$server_port" "$server_target" 'set -eu; umask 077; mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; key=$(cat); grep -qxF "$key" "$HOME/.ssh/authorized_keys" 2>/dev/null || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"'

# server_ssh() 定义在文件开头：这里的 server_host / server_user / server_port /
# device_key 已经由向导设好，函数体直接取这些变量。

# 服务器端回连密钥是不是本次新建的 —— 回滚时只删本次生成的东西。
if server_ssh "test -f \"\$HOME/$server_key_relative\"" 2>/dev/null; then
    SERVER_KEY_CREATED=0
else
    SERVER_KEY_CREATED=1
fi

server_ssh "umask 077; mkdir -p \"\$HOME/.ssh/device-onboard\"; key=\"\$HOME/$server_key_relative\"; if [ ! -f \"\$key\" ]; then ssh-keygen -q -t ed25519 -N '' -f \"\$key\" -C 'device-onboard:$device_id'; fi; cat \"\$key.pub\"" > "$CONFIG_DIR/server-key.pub"
chmod 600 "$CONFIG_DIR/server-key.pub"
server_pub=$(cat "$CONFIG_DIR/server-key.pub")
grep -qxF "$server_pub" "$HOME/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$server_pub" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

reverse_port=

# Termux（Android）会在后台回收进程，建立隧道前先申请唤醒锁。
if [ "$DEVICE_NEEDS_WAKE_LOCK" = 1 ]; then
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1 || true
fi

# 反向端口搜索区间：起点刻意避开手工占用的低位端口（2222/2223）。
reverse_port_start=${DEVICE_ONBOARD_REVERSE_PORT_START:-2230}
reverse_port_end=${DEVICE_ONBOARD_REVERSE_PORT_END:-2299}

# 反向端口必须「按设备固定」，不能「谁先来谁拿」。
# 因为在服务器眼里，每台设备是一个 [127.0.0.1]:<端口> 的 ssh 主机，而 known_hosts 的键
# 里带着端口。两台设备先后用同一个端口，后到的那台就会被旧指纹挡住：
#     Host key verification failed（WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED）
# 试探「端口是否空闲」只能反映安装那一刻谁在听 —— 所以先读服务器档案：
#   本设备登记过的端口 → 优先复用（指纹长期有效）
#   别的设备登记过的端口 → 直接跳过（哪怕现在没人连着）
skill_file_remote='$HOME/.codex/skills/device-onboard/SKILL.md'
archive_dump=$(server_ssh "cat \"$skill_file_remote\" 2>/dev/null" 2>/dev/null || true)

own_registered_port=$(printf '%s\n' "$archive_dump" | awk -v id="$device_id" '
    $0 == "<!-- DEVICE-ONBOARD:" id " BEGIN -->" { in_own = 1; next }
    $0 == "<!-- DEVICE-ONBOARD:" id " END -->"   { in_own = 0; next }
    in_own && $1 == "reverse_port:" && $2 ~ /^[0-9]+$/ { print $2; exit }')

registered_ports=$(printf '%s\n' "$archive_dump" | awk -v id="$device_id" '
    /^<!-- DEVICE-ONBOARD:.* BEGIN -->$/ { cur = $2; sub(/^DEVICE-ONBOARD:/, "", cur); in_block = 1; next }
    /^<!-- DEVICE-ONBOARD:.* END -->$/   { in_block = 0; next }
    in_block && $1 == "reverse_port:" && $2 ~ /^[0-9]+$/ && cur != id { print $2 }' | tr '\n' ' ')

# 台账来源之二：服务器 ssh config 里各设备块的 Port。
# 清掉档案不该等于丢掉端口分配 —— 否则某台「睡着了」（隧道没开）的设备登记过的端口
# 就没人保护，新设备会把它抢走，之后两台在服务器上争同一个 [127.0.0.1]:<端口> 指纹。
# 只取「别的设备」的登记：本设备自己的登记以档案为准（config 里那份可能正是上一次
# 错误分配的遗留，拿它当依据会把错误固化下来）。
config_ports=$(server_ssh "awk '/^Host onboard-device-/{d=\$2} /^[[:space:]]*Port[[:space:]]/{if(d!=\"\"){sub(/^onboard-device-/,\"\",d); print d\" \"\$2; d=\"\"}}' \"\$HOME/.ssh/config\" 2>/dev/null" 2>/dev/null || true)
registered_ports="$registered_ports$(printf '%s\n' "$config_ports" | awk -v id="$device_id" '$1 != id && $2 ~ /^[0-9]+$/ { print $2 }' | tr '\n' ' ')"

port_registered_to_other_device() {
    case " $registered_ports " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# 服务器上这个端口现在有人在听吗？（没有 ss 就当没人听，退回「绑一下试试」。）
port_in_use_on_server() {
    _out=$(server_ssh "ss -ltn \"sport = :$1\" 2>/dev/null | tail -n +2" 2>/dev/null || true)
    [ -n "$_out" ]
}

# 真跑一次「服务器 → 隧道 → 本机」的握手。
# 端口绑上只说明转发建立成功，不等于通道真的通 —— 所以要真连回来。
reverse_forward_works() {
    probe_port=$1
    out=$(server_ssh "ssh -p $probe_port -i \"\$HOME/.ssh/device-onboard/${device_id}-server\" \
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 ${device_user}@127.0.0.1 'printf %s DEVICE-ONBOARD-E2E-OK'" 2>&1) || true
    case "$out" in
        *DEVICE-ONBOARD-E2E-OK*) e2e_last_error=; return 0 ;;
        *) e2e_last_error=$out; return 1 ;;
    esac
}

# Termux 上 /tmp 不可写（Android 限制），必须用 ${TMPDIR}；再不行退回配置目录。
probe_log_dir=${TMPDIR:-/tmp}
if [ ! -d "$probe_log_dir" ] || [ ! -w "$probe_log_dir" ]; then
    probe_log_dir=$CONFIG_DIR
fi
probe_log="$probe_log_dir/device-onboard-tunnel.$$.log"

port=$reverse_port_start
# 候选顺序：本设备登记过的端口排最前（复用 → known_hosts 里的指纹一直有效），
# 其余按区间顺序跟上；已被别的设备登记的端口根本不进候选名单。
port_candidates=
if [ -n "$own_registered_port" ]; then
    port_candidates=$own_registered_port
fi
while [ "$port" -le "$reverse_port_end" ]; do
    case " $port_candidates " in
        *" $port "*) ;;
        *) port_candidates="${port_candidates:+$port_candidates }$port" ;;
    esac
    port=$((port + 1))
done

for port in $port_candidates; do
    if port_registered_to_other_device "$port"; then
        printf '跳过端口 %s：已登记给其它设备（避免两台设备在服务器上争同一个 [127.0.0.1]:%s 指纹）。\n' "$port" "$port"
        continue
    fi
    # 端口上已经有人在听：先问一句「这是不是本设备自己的隧道」。
    # 是 → 直接复用。重跑安装时本设备的隧道往往还开着，这时去 bind 必然失败
    #      （端口被自己占着），旧逻辑会一路顺位到别人的端口，既丢身份又可能撞指纹。
    # 不是 → 让开，那是别人的隧道，不该抢。
    if port_in_use_on_server "$port"; then
        if reverse_forward_works "$port"; then
            reverse_port=$port
            printf '端口 %s 上已有本设备的隧道在跑，直接复用（不重新绑定）。\n' "$port"
            break
        fi
        printf '跳过端口 %s：已有人在听，且反向握手确认不是本设备。\n' "$port"
        continue
    fi
    ssh -i "$device_key" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=8 -p "$server_port" -R "$port:localhost:$device_port" -N "$server_target" >"$probe_log" 2>&1 &
    tunnel_pid=$!
    sleep 1
    if kill -0 "$tunnel_pid" 2>/dev/null; then
        # 端口绑上了。但「绑上」不等于「通了」—— 真握手一次再定。
        if reverse_forward_works "$port"; then
            reverse_port=$port
            break
        fi
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
        tunnel_pid=
        printf '\n端口 %s 的转发绑上了，但反向握手失败：\n%s\n' "$port" "$e2e_last_error" >&2
        die "反向通道不通 —— 换端口没用（端口不是原因）。请检查目标机 sshd 是否在跑、服务器的公钥是否装进目标机。"
    fi
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=
done
if [ -z "$reverse_port" ]; then
    printf '探测隧道时的最后几行报错：\n' >&2
    tail -3 "${probe_log:-/dev/null}" 2>/dev/null >&2 || true
    die "无法在 $reverse_port_start-$reverse_port_end 中找到可用反向端口。"
fi

# 写进 ssh config 的端口必须是纯数字：写成空值或带杂字符，ssh 会直接罢工
# （Bad forwarding specification），而且会让之后所有 ssh 全部失败。
case "$reverse_port" in
    ''|*[!0-9]*) die "反向端口不是有效数字：'$reverse_port'；为避免写坏 ~/.ssh/config，已中止。" ;;
esac
case "$device_port" in
    ''|*[!0-9]*) die "本机 sshd 端口不是有效数字：'$device_port'；为避免写坏 ~/.ssh/config，已中止。" ;;
esac

server_alias=server
device_alias="onboard-device-$device_id"

write_local_ssh_block
write_remote_ssh_block

install_server_view

cat > "$STATE_FILE" <<EOF
DEVICE_ID=$device_id
DEVICE_NAME=$device_name
DEVICE_USER=$device_user
SERVER_HOST=$server_host
SERVER_USER=$server_user
SERVER_PORT=$server_port
DEVICE_PORT=$device_port
REVERSE_PORT=$reverse_port
SERVER_HOST_ALIAS=$server_alias
DEVICE_HOST_ALIAS=$device_alias
DEVICE_KEY=$device_key
BIN_DIR=$BIN_DIR
EOF
chmod 600 "$STATE_FILE"
INSTALL_OK=1
cleanup_tunnel
trap - EXIT INT TERM

printf '\n✅ 设备接入完成。\n'
printf '普通服务器：ssh %s\n' "$server_alias"
printf '一键（隧道 + harness）：device-harness\n'
printf '换 harness：device-harness <命令>（默认 codex，例如 device-harness claude）\n'
printf '网页 harness：device-harness dsh（在设备浏览器里用服务器上的 dsh web）\n'
printf '反向隧道：device-tunnel\n'
printf '在服务器上跑 Harness：ssh %s codex\n' "$server_alias"
printf '更新工具：重跑 sh install.sh（只更新本地命令）；重写配置块：sh install.sh --repair\n'
printf '彻底卸载：device-uninstall\n'
