#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR=${DEVICE_ONBOARD_BIN_DIR:-"$HOME/.local/bin"}
CONFIG_DIR=${DEVICE_ONBOARD_CONFIG_DIR:-"$HOME/.config/device-onboard"}
STATE_FILE="$CONFIG_DIR/config"
KEY_DIR=${DEVICE_ONBOARD_KEY_DIR:-"$HOME/.ssh/device-onboard"}

usage() {
    cat <<'EOF'
用法：sh install.sh

首次运行会安装本地命令并进入设备接入设置；再次运行只更新本地命令。
支持平台：macOS、Termux（Android）。
环境变量：
  DEVICE_ONBOARD_BIN_DIR            本地命令安装目录
  DEVICE_ONBOARD_CONFIG_DIR         本地配置目录
  DEVICE_ONBOARD_KEY_DIR            本地密钥目录
  DEVICE_ONBOARD_DEVICE_SSH_PORT    本机 sshd 端口（macOS 默认 22，Termux 默认 8022）
  DEVICE_ONBOARD_REVERSE_PORT_START 反向端口起点（默认 2230，避开手工占用的低位端口）
  DEVICE_ONBOARD_REVERSE_PORT_END   反向端口终点（默认 2299）
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "--help" ] && { usage; exit 0; }
[ "${1:-}" = "-h" ] && { usage; exit 0; }
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

detect_platform
command -v ssh >/dev/null 2>&1 || die "找不到 ssh。"
command -v ssh-keygen >/dev/null 2>&1 || die "找不到 ssh-keygen。"
[ -n "$DEVICE_SSH_PORT" ] || die "无法确定设备 SSH 端口。"

# 先清掉自己以前留下的块（可能带着坏值），再做体检 —— 顺序不能反。
strip_device_onboard_blocks

# 早发现早报错：~/.ssh/config 里若有坏行，之后每一次 ssh 都会失败，
# 而报错指向的是那一行 —— 很容易让人误以为是本次操作搞坏的。
if [ -f "$HOME/.ssh/config" ] && ! ssh -G -o BatchMode=yes localhost >/dev/null 2>&1; then
    printf '警告：当前的 ~/.ssh/config 无法正常解析，请先修好它，否则后面所有 ssh 都会失败。\n' >&2
    printf '      查看具体报错：ssh -G localhost\n' >&2
fi

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$KEY_DIR"
chmod 700 "$CONFIG_DIR" "$KEY_DIR"
copy_command() {
    # 不用 install(1)：Termux 基础环境不保证有这个命令。
    cp -f "$1" "$2"
    chmod 755 "$2"
}
copy_command "$PROJECT_DIR/bin/device-tunnel" "$BIN_DIR/device-tunnel"
copy_command "$PROJECT_DIR/bin/server-harness" "$BIN_DIR/server-harness"

if [ -f "$STATE_FILE" ]; then
    printf '本地命令已更新。已有设备配置，跳过首次接入。\n'
    printf '日常命令：device-tunnel、server-harness <命令>\n'
    exit 0
fi

printf '\n设备接入设置\n\n'
printf '1) 配置设备与服务器的 SSH 连接\n'
printf '0) 退出\n\n'
printf '请选择：'
read -r choice
[ "$choice" = "1" ] || exit 0

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
printf '继续接入？[Y/n]：'
read -r confirm
case "$confirm" in n|N) exit 0;; esac

mkdir -p "$HOME/.ssh" "$KEY_DIR"
chmod 700 "$HOME/.ssh" "$KEY_DIR"
if [ ! -f "$device_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$device_key" -C "device-onboard:$device_id"
fi
chmod 600 "$device_key"

device_pub=$(cat "$device_key.pub")
printf '\n首次 SSH 连接将由系统提示确认主机指纹或输入密码。\n'
printf '%s\n' "$device_pub" | ssh -p "$server_port" "$server_target" 'set -eu; umask 077; mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; key=$(cat); grep -qxF "$key" "$HOME/.ssh/authorized_keys" 2>/dev/null || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"'

server_ssh() {
    ssh -i "$device_key" -o IdentitiesOnly=yes -p "$server_port" "$server_target" "$@"
}

server_ssh "umask 077; mkdir -p \"\$HOME/.ssh/device-onboard\"; key=\"\$HOME/$server_key_relative\"; if [ ! -f \"\$key\" ]; then ssh-keygen -q -t ed25519 -N '' -f \"\$key\" -C 'device-onboard:$device_id'; fi; cat \"\$key.pub\"" > "$CONFIG_DIR/server-key.pub"
chmod 600 "$CONFIG_DIR/server-key.pub"
server_pub=$(cat "$CONFIG_DIR/server-key.pub")
grep -qxF "$server_pub" "$HOME/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$server_pub" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

reverse_port=
tunnel_pid=
cleanup_tunnel() {
    if [ -n "${tunnel_pid:-}" ]; then
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
    if [ -n "${probe_log:-}" ]; then
        rm -f "$probe_log" 2>/dev/null || true
    fi
}
trap cleanup_tunnel EXIT INT TERM

# Termux（Android）会在后台回收进程，建立隧道前先申请唤醒锁。
if [ "$DEVICE_NEEDS_WAKE_LOCK" = 1 ]; then
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1 || true
fi

# 反向端口搜索区间：起点刻意避开手工占用的低位端口（2222/2223）。
reverse_port_start=${DEVICE_ONBOARD_REVERSE_PORT_START:-2230}
reverse_port_end=${DEVICE_ONBOARD_REVERSE_PORT_END:-2299}

# Termux 上 /tmp 不可写（Android 限制），必须用 $TMPDIR；再不行退回配置目录。
probe_log_dir=${TMPDIR:-/tmp}
if [ ! -d "$probe_log_dir" ] || [ ! -w "$probe_log_dir" ]; then
    probe_log_dir=$CONFIG_DIR
fi
probe_log="$probe_log_dir/device-onboard-tunnel.$$.log"

port=$reverse_port_start
while [ "$port" -le "$reverse_port_end" ]; do
    ssh -i "$device_key" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=8 -p "$server_port" -R "$port:localhost:$device_port" -N "$server_target" >"$probe_log" 2>&1 &
    tunnel_pid=$!
    sleep 1
    if kill -0 "$tunnel_pid" 2>/dev/null; then
        reverse_port=$port
        break
    fi
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=
    port=$((port + 1))
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

server_alias="onboard-server-$device_id"
tunnel_alias="onboard-tunnel-$device_id"
device_alias="onboard-device-$device_id"
server_key_local="~/.ssh/device-onboard/${device_id}-server"
local_begin="# >>> device-onboard:$device_id BEGIN"
local_end="# <<< device-onboard:$device_id END"

local_block=$(cat <<EOF
$local_begin
Host $server_alias
    HostName $server_host
    User $server_user
    Port $server_port
    IdentityFile $device_key
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3

Host $tunnel_alias
    HostName $server_host
    User $server_user
    Port $server_port
    IdentityFile $device_key
    IdentitiesOnly yes
    RemoteForward $reverse_port localhost:$device_port
    ExitOnForwardFailure yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
$local_end
EOF
)

update_local_config() {
    config="$HOME/.ssh/config"
    tmp=$(mktemp)
    if [ -f "$config" ]; then
        awk -v begin="$local_begin" -v end="$local_end" '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' "$config" > "$tmp"
        cp "$config" "$config.device-onboard.bak"
    fi
    printf '%s\n' "$local_block" >> "$tmp"
    mv "$tmp" "$config"
    chmod 600 "$config"
}
update_local_config

remote_begin="# >>> device-onboard:$device_id BEGIN"
remote_end="# <<< device-onboard:$device_id END"
remote_block=$(cat <<EOF
$remote_begin
Host $device_alias
    HostName 127.0.0.1
    User $device_user
    Port $reverse_port
    IdentityFile $server_key_local
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
$remote_end
EOF
)

printf '%s\n' "$remote_block" | server_ssh "set -eu; file=\"\$HOME/.ssh/config\"; tmp=\"\$(mktemp)\"; mkdir -p \"\$HOME/.ssh\"; if [ -f \"\$file\" ]; then awk -v begin='$remote_begin' -v end='$remote_end' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' \"\$file\" > \"\$tmp\"; cp \"\$file\" \"\$file.device-onboard.bak\"; else : > \"\$tmp\"; fi; cat >> \"\$tmp\"; mv \"\$tmp\" \"\$file\"; chmod 600 \"\$file\""

skill_begin="<!-- DEVICE-ONBOARD:$device_id BEGIN -->"
skill_end="<!-- DEVICE-ONBOARD:$device_id END -->"
skill_block=$(cat <<EOF
$skill_begin
device_name: $device_name
server_host: $server_host
server_user: $server_user
server_ssh_port: $server_port
device_ssh_port: $device_port
reverse_port: $reverse_port
device_key_name: $device_id-device
server_key_name: $device_id-server
$skill_end
EOF
)
printf '%s\n' "$skill_block" | server_ssh "set -eu; dir=\"\$HOME/.agents/skills/device-onboard\"; file=\"\$dir/SKILL.md\"; tmp=\"\$(mktemp)\"; mkdir -p \"\$dir\"; if [ -f \"\$file\" ]; then awk -v begin='$skill_begin' -v end='$skill_end' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' \"\$file\" > \"\$tmp\"; cp \"\$file\" \"\$file.device-onboard.bak\"; else printf '# Device Onboard\\n\\n' > \"\$tmp\"; fi; cat >> \"\$tmp\"; mv \"\$tmp\" \"\$file\""

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
TUNNEL_HOST_ALIAS=$tunnel_alias
DEVICE_HOST_ALIAS=$device_alias
DEVICE_KEY=$device_key
EOF
chmod 600 "$STATE_FILE"
cleanup_tunnel
trap - EXIT INT TERM

printf '\n✅ 设备接入完成。\n'
printf '普通服务器：ssh %s\n' "$server_alias"
printf '反向隧道：device-tunnel\n'
printf '远程 Harness：server-harness codex\n'
