#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR=${DEVICE_ONBOARD_BIN_DIR:-}
CONFIG_DIR=${DEVICE_ONBOARD_CONFIG_DIR:-"$HOME/.config/device-onboard"}
STATE_FILE="$CONFIG_DIR/config"
KEY_DIR=${DEVICE_ONBOARD_KEY_DIR:-"$HOME/.ssh/device-onboard"}

usage() {
    cat <<'EOF'
用法：sh install.sh

首次运行会安装本地命令并进入设备接入设置；再次运行只更新本地命令。
支持平台：macOS、Termux（Android）。
环境变量：
  DEVICE_ONBOARD_BIN_DIR            本地命令安装目录（默认 Termux: $PREFIX/bin；macOS: /usr/local/bin）
  DEVICE_ONBOARD_CONFIG_DIR         本地配置目录
  DEVICE_ONBOARD_KEY_DIR            本地密钥目录
  DEVICE_ONBOARD_DEVICE_SSH_PORT    本机 sshd 端口（macOS 默认 22，Termux 默认 8022）
  DEVICE_ONBOARD_REVERSE_PORT_START 反向端口起点（默认 2230，避开手工占用的低位端口）
  DEVICE_ONBOARD_REVERSE_PORT_END   反向端口终点（默认 2299）
  DEVICE_ONBOARD_SSHFS              设为 0 跳过服务器端 sshfs 配置（默认开启）
  DEVICE_ONBOARD_AGENTS_MD          设为 0 跳过服务器 ~/.codex/AGENTS.md 的设备会话块（默认开启）
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

# 装的目录若不在 PATH 里，明说怎么加 —— 别让人对着 command not found 发懵。
case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *)
        printf '提示：%s 不在 PATH 里，新开的终端可能敲不到 device-tunnel。\n' "$BIN_DIR"
        printf '      在 shell 配置里加一行：export PATH="%s:$PATH"\n' "$BIN_DIR"
        ;;
esac

if [ -f "$STATE_FILE" ]; then
    printf '本地命令已更新。已有设备配置，跳过首次接入。\n'
    # 这条路径绝不能碰 ~/.ssh/config：配置块是「产物」，状态文件才是「源」。
    # 清掉却重建不出来，就把已经接好的设备弄瘸了。
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    if ! grep -qF "# >>> device-onboard:$DEVICE_ID BEGIN" "$HOME/.ssh/config" 2>/dev/null; then
        printf '\n⚠️ %s 里找不到本设备（%s）的配置块，device-tunnel 会解析不到主机。\n' "$HOME/.ssh/config" "$DEVICE_ID"
        printf '   修复：删掉状态文件后重跑，脚本会照常重新生成 ——\n'
        printf '     rm -rf %s && sh install.sh\n' "$CONFIG_DIR"
    fi
    printf '日常命令：device-harness（一键：隧道 + harness）、device-tunnel；在服务器上跑命令：ssh %s <命令>\n' "$SERVER_HOST_ALIAS"
    exit 0
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
        rollback_note "已从 ~/.ssh/config 去掉本设备（$device_id）的配置块。"
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
        rollback_note "已删除本次生成的设备密钥（$device_key）。"
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
    grep -vF "device-onboard:$device_id" "\$ak" > "\$ak.rollback" && mv "\$ak.rollback" "\$ak" && chmod 600 "\$ak" 2>/dev/null && echo REMOVED_AUTHORIZED_KEY
fi
skill="\$HOME/.codex/skills/device-onboard/SKILL.md"
if [ "$SKILL_WAS_NEW" = 1 ]; then
    if [ -f "\$skill" ]; then rm -f "\$skill" && echo REMOVED_SKILL_FILE; fi
elif [ -f "\$skill" ] && grep -qF "<!-- DEVICE-ONBOARD:$device_id BEGIN -->" "\$skill" 2>/dev/null; then
    t=\$(mktemp)
    awk -v b="<!-- DEVICE-ONBOARD:$device_id BEGIN -->" -v e="<!-- DEVICE-ONBOARD:$device_id END -->" '\$0==b{skip=1;next} \$0==e{skip=0;next} !skip{print}' "\$skill" > "\$t"
    mv "\$t" "\$skill" 2>/dev/null; chmod 600 "\$skill" 2>/dev/null
    echo STRIPPED_SKILL_BLOCK
fi
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

server_ssh() {
    ssh -i "$device_key" -o IdentitiesOnly=yes -p "$server_port" "$server_target" "$@"
}

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
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3

Host $tunnel_alias
    HostName $server_host
    User $server_user
    Port $server_port
    IdentityFile $device_key
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
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
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
$remote_end
EOF
)

printf '%s\n' "$remote_block" | server_ssh "set -eu; file=\"\$HOME/.ssh/config\"; tmp=\"\$(mktemp)\"; mkdir -p \"\$HOME/.ssh\"; if [ -f \"\$file\" ]; then awk -v begin='$remote_begin' -v end='$remote_end' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' \"\$file\" > \"\$tmp\"; cp \"\$file\" \"\$file.device-onboard.bak\"; else : > \"\$tmp\"; fi; cat >> \"\$tmp\"; mv \"\$tmp\" \"\$file\"; chmod 600 \"\$file\""

# ---------- 服务器端 sshfs（可选；任何一步失败都不影响接入） ----------
# 把设备家目录通过 sshfs 挂到服务器的 ~/<device_id>，服务器上的 harness 就能直接
# 读写设备里的文件。试挂必须趁反向探测隧道还开着 —— 接入结束后隧道就关了，
# 之后服务器再想连设备就没通道了。所以这里挂一次、验证读写、立刻摘掉，只留结论。
# DEVICE_ONBOARD_SSHFS=0 可整体跳过。回滚逻辑不动：本段所有失败都被吞掉。
SSHFS_STATUS=unavailable

setup_server_sshfs() {
    if [ "${DEVICE_ONBOARD_SSHFS:-1}" = "0" ]; then
        SSHFS_STATUS=skipped
        printf '按 DEVICE_ONBOARD_SSHFS=0 跳过服务器 sshfs 配置。\n'
        return 0
    fi
    _sshfs_script=$(cat <<REMOTE_SSHFS_EOF
set +e
mp="\$HOME/$device_id"
mkdir -p "\$mp" 2>/dev/null && chmod 755 "\$mp" 2>/dev/null || { echo SSHFS_NO_DIR; exit 0; }
if ! command -v sshfs >/dev/null 2>&1; then
    case "\$(uname -s 2>/dev/null)" in
        Darwin) echo SSHFS_MACOS; exit 0 ;;
    esac
    if command -v apt-get >/dev/null 2>&1; then
        sudo -n apt-get install -y sshfs >/dev/null 2>&1
    fi
    command -v sshfs >/dev/null 2>&1 || { echo SSHFS_NO_INSTALL; exit 0; }
fi
_ls() { if command -v timeout >/dev/null 2>&1; then timeout 3 ls "\$1" >/dev/null 2>&1; else ls "\$1" >/dev/null 2>&1; fi; }
if sshfs onboard-device-$device_id: "\$mp" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user,follow_symlinks >/dev/null 2>&1; then
    if _ls "\$mp" && t="\$mp/.device-onboard-write-test.\$\$" && printf ok > "\$t" 2>/dev/null && rm -f "\$t" 2>/dev/null; then
        echo SSHFS_OK
    else
        rm -f "\$mp/.device-onboard-write-test.\$\$" 2>/dev/null
        echo SSHFS_RW_FAIL
    fi
    fusermount -u "\$mp" >/dev/null 2>&1 || umount "\$mp" >/dev/null 2>&1 || true
else
    echo SSHFS_MOUNT_FAIL
fi
REMOTE_SSHFS_EOF
)
    _sshfs_out=$(printf '%s\n' "$_sshfs_script" | server_ssh 'sh -s' 2>&1 || true)
    case "$_sshfs_out" in
        *SSHFS_OK*)
            SSHFS_STATUS=verified
            printf '✅ 服务器 sshfs 试挂成功（读、写已验证），已卸载。\n'
            ;;
        *SSHFS_MACOS*)
            SSHFS_STATUS=unsupported
            printf '提示：服务器是 macOS，跳过 sshfs 配置（如需请自行安装 macFUSE + sshfs）。\n' >&2
            ;;
        *SSHFS_NO_INSTALL*)
            SSHFS_STATUS=unavailable
            printf '警告：服务器上装不了 sshfs，跳过 sshfs 配置（不影响接入）。\n' >&2
            ;;
        *SSHFS_NO_DIR*)
            SSHFS_STATUS=unavailable
            printf '警告：服务器上创建挂载点 ~/%s 失败，跳过 sshfs 配置（不影响接入）。\n' "$device_id" >&2
            ;;
        *SSHFS_RW_FAIL*)
            SSHFS_STATUS=unavailable
            printf '警告：服务器 sshfs 挂上了但读写验证失败，已卸载（不影响接入）。\n' >&2
            ;;
        *)
            SSHFS_STATUS=unavailable
            printf '警告：服务器 sshfs 试挂失败，跳过（不影响接入）。\n' >&2
            ;;
    esac
    return 0
}
setup_server_sshfs || true

# ---------- 服务器端 ~/.codex/AGENTS.md（可选；任何一步失败都不影响接入） ----------
# Codex 只读 ~/.codex/AGENTS.md（实测：它不读 ~/.agents/AGENTS.md），所以设备会话说明
# 必须写在这里，且用独立标记块维护：块已存在就整体替换，不存在就追加，文件不存在就创建。
# 绝不碰块以外的任何内容。回滚逻辑刻意不动这一块（用户裁决：回滚不管 AGENTS.md）。
# DEVICE_ONBOARD_AGENTS_MD=0 可整体跳过。
setup_server_agents_md() {
    if [ "${DEVICE_ONBOARD_AGENTS_MD:-1}" = "0" ]; then
        printf '按 DEVICE_ONBOARD_AGENTS_MD=0 跳过服务器 ~/.codex/AGENTS.md 配置。\n'
        return 0
    fi
    _agents_script=$(cat <<'REMOTE_AGENTS_EOF'
set +e
file="$HOME/.codex/AGENTS.md"
mkdir -p "$HOME/.codex" 2>/dev/null || { echo AGENTS_FAIL; exit 0; }
tmp=$(mktemp 2>/dev/null) || { echo AGENTS_FAIL; exit 0; }
if [ -f "$file" ]; then
    awk -v b='<!-- DEVICE-ONBOARD-AGENTS BEGIN -->' -v e='<!-- DEVICE-ONBOARD-AGENTS END -->' '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; echo AGENTS_FAIL; exit 0; }
fi
cat >> "$tmp" <<'AGENTS_BLOCK_EOF'
<!-- DEVICE-ONBOARD-AGENTS BEGIN -->
## 设备会话
本服务器的设备登记见 ~/.codex/skills/device-onboard/SKILL.md。
判断本次会话来自哪台设备：看环境变量 DEVICE_ONBOARD_ID；有值时设备目录在 ~/<设备名>。
该目录是这台设备的项目锚点（不一定挂着 sshfs）；设备上的文件用 `ssh onboard-device-<设备名>` / `scp` 读写。
没有值 → 这是普通服务器会话，不要假设来自设备。
<!-- DEVICE-ONBOARD-AGENTS END -->
AGENTS_BLOCK_EOF
mv "$tmp" "$file" 2>/dev/null && chmod 600 "$file" 2>/dev/null && echo AGENTS_OK || { rm -f "$tmp"; echo AGENTS_FAIL; }
REMOTE_AGENTS_EOF
)
    _agents_out=$(printf '%s\n' "$_agents_script" | server_ssh 'sh -s' 2>&1 || true)
    case "$_agents_out" in
        *AGENTS_OK*) printf '✅ 已写入服务器 ~/.codex/AGENTS.md 的设备会话说明块。\n' ;;
        *)          printf '警告：写入服务器 ~/.codex/AGENTS.md 失败，跳过（不影响接入）。\n' >&2 ;;
    esac
    return 0
}

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
sshfs_mount: ~/$device_id
sshfs_status: $SSHFS_STATUS
$skill_end
EOF
)
# 共享约定。**必须放在设备块之外**：档案是多设备共用的，写进某一个设备块里，
# 第二台设备接进来时就看不到了。
conv_begin='<!-- DEVICE-ONBOARD-CONVENTION BEGIN -->'
conv_end='<!-- DEVICE-ONBOARD-CONVENTION END -->'
conv_block=$(cat <<EOF
$conv_begin
## 本次会话来自哪台设备

如果本次会话是被 \`device-harness\` 拉起来的，环境里带着两个变量：

    DEVICE_ONBOARD_ID=<设备名>                        例如 xiaomi
    DEVICE_ONBOARD_DEVICE_ALIAS=onboard-device-<设备名>

也就是说：这台服务器对面的那一侧，就是发起本次会话的那台设备。可以直接回去：

    ssh "\$DEVICE_ONBOARD_DEVICE_ALIAS"

没有这两个变量，说明本次会话不是从设备侧（device-harness）进来的，例如手动 ssh 上来。
$conv_end
EOF
)
skill_dir_remote='$HOME/.codex/skills/device-onboard'
skill_file_remote="$skill_dir_remote/SKILL.md"

if server_ssh "test -f \"$skill_file_remote\"" 2>/dev/null; then
    # 已有档案：只替换本设备那一块，其它内容原样保留
    printf '%s\n' "$conv_block
$skill_block" | server_ssh "set -eu; file=\"$skill_file_remote\"; tmp=\"\$(mktemp)\"; awk -v begin='$conv_begin' -v end='$conv_end' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' \"\$file\" | awk -v begin='$skill_begin' -v end='$skill_end' '\$0 == begin {skip=1; next} \$0 == end {skip=0; next} !skip {print}' > \"\$tmp\"; cp \"\$file\" \"\$file.device-onboard.bak\"; cat >> \"\$tmp\"; mv \"\$tmp\" \"\$file\""
else
    # 新档案：头部在本地拼好（带 frontmatter，真换行），整体送过去落盘。
    # 不在远端用 printf 拼 —— 那需要多层反斜杠转义，极易写出乱码。
    SKILL_WAS_NEW=1
    {
        printf -- '---\n'
        printf -- 'name: device-onboard\n'
        printf -- 'description: SSH devices on this server (incl. which one this session is from).\n'
        printf -- '---\n\n'
        printf -- '# Device Onboard\n\n'
        printf '%s\n' "$conv_block"
        printf '\n'
        printf '%s\n' "$skill_block"
    } | server_ssh "set -eu; dir=\"$skill_dir_remote\"; mkdir -p \"\$dir\"; cat > \"\$dir/SKILL.md\"; chmod 600 \"\$dir/SKILL.md\""
fi

# 服务器上的全局指令块：写进 ~/.codex/AGENTS.md，让普通/设备会话都能一眼判断身份。
setup_server_agents_md || true

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
SSHFS_STATUS=$SSHFS_STATUS
EOF
chmod 600 "$STATE_FILE"
INSTALL_OK=1
cleanup_tunnel
trap - EXIT INT TERM

printf '\n✅ 设备接入完成。\n'
printf '普通服务器：ssh %s\n' "$server_alias"
printf '一键（隧道 + harness）：device-harness\n'
printf '反向隧道：device-tunnel\n'
printf '服务器挂载点：~/<设备ID>（sshfs：%s）\n' "$SSHFS_STATUS"
printf '在服务器上跑 Harness：ssh %s codex\n' "$server_alias"
