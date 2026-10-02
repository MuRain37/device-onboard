#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_HOME=$(mktemp -d)
FAKE_BIN="$TMP_HOME/fake-bin"
mkdir -p "$FAKE_BIN" "$TMP_HOME/config"
trap 'rm -rf "$TMP_HOME"' EXIT

cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_SSH_LOG"
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

HOME="$TMP_HOME" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/bin" DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/config" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/keys" \
    sh "$ROOT/install.sh" --help >/dev/null

if HOME="$TMP_HOME" DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/missing/config" sh "$ROOT/bin/device-tunnel" >/tmp/device-onboard-smoke.out 2>&1; then
    printf 'device-tunnel should fail without configuration\n' >&2
    exit 1
fi
grep -q '还没有设备接入配置' /tmp/device-onboard-smoke.out

if HOME="$TMP_HOME" DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/missing/config" sh "$ROOT/bin/device-harness" >/tmp/device-onboard-smoke.out 2>&1; then
    printf 'device-harness should fail without configuration\n' >&2
    exit 1
fi
grep -q '还没有设备接入配置' /tmp/device-onboard-smoke.out

cat > "$TMP_HOME/config/config" <<EOF
SERVER_HOST_ALIAS=onboard-server-test
TUNNEL_HOST_ALIAS=onboard-tunnel-test
REVERSE_PORT=2230
DEVICE_PORT=8022
EOF

FAKE_SSH_LOG="$TMP_HOME/ssh.log" PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/config/config" sh "$ROOT/bin/device-tunnel"
grep -q 'onboard-tunnel-test' "$TMP_HOME/ssh.log"
grep -q '反向隧道已建立' "$TMP_HOME/ssh.log"

# --- 平台识别 ---

# 既不是 macOS 也不是 Termux：必须明确拒绝，而不是继续往下跑
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
chmod 755 "$FAKE_BIN/uname"
if PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p1" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k1" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b1" \
        sh "$ROOT/install.sh" </dev/null >/tmp/device-onboard-smoke.out 2>&1; then
    printf 'install.sh should reject unsupported platforms\n' >&2
    exit 1
fi
grep -q '不支持的平台' /tmp/device-onboard-smoke.out

# Termux：应当通过平台检查并进入菜单（喂 0 直接退出）
printf '0\n' | TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p2" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k2" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b2" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1
grep -q '设备接入设置' /tmp/device-onboard-smoke.out
if grep -q '不支持的平台' /tmp/device-onboard-smoke.out; then
    printf 'Termux should pass the platform check\n' >&2
    exit 1
fi

# macOS：同样应当通过平台检查
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
chmod 755 "$FAKE_BIN/uname"
printf '0\n' | PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p3" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k3" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b3" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1
grep -q '设备接入设置' /tmp/device-onboard-smoke.out

# --- Termux: 自动确保 sshd 在跑 ---

# 用假的 sshd 记录调用，避免测试时真的去起 sshd
cat > "$FAKE_BIN/sshd" <<'EOF'
#!/bin/sh
printf 'sshd called\n' >> "$FAKE_SSHD_LOG"
exit 0
EOF
chmod 755 "$FAKE_BIN/sshd"
: > "$TMP_HOME/sshd.log"
# 端口区间压成一个，避免这段流程在测试里空转 70 次
printf '1\n\ntest.invalid\nubuntu\n\n' | env FAKE_SSHD_LOG="$TMP_HOME/sshd.log" TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p4" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k4" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b4" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
grep -q '已确保 sshd 在运行' /tmp/device-onboard-smoke.out
grep -q 'sshd called' "$TMP_HOME/sshd.log"

# --- 旧的坏块必须被清掉（否则之后每次 ssh 都会失败）---

mkdir -p "$TMP_HOME/.ssh"
cat > "$TMP_HOME/.ssh/config" <<'EOF'
Host keepme
    HostName example.com

# >>> device-onboard:oldrun BEGIN
Host onboard-tunnel-oldrun
    RemoteForward :localhost:
# <<< device-onboard:oldrun END
EOF
printf '0\n' | TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p6" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k6" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b6" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
grep -q '已清理' /tmp/device-onboard-smoke.out
grep -q 'Host keepme' "$TMP_HOME/.ssh/config"
if grep -q 'device-onboard' "$TMP_HOME/.ssh/config"; then
    printf 'stale device-onboard block was not stripped\n' >&2
    exit 1
fi
rm -f "$TMP_HOME/.ssh/config"

# --- 回归防护：写进 ssh config 的 RemoteForward 必须能被 ssh 解析 ---
# ssh_config 里得用两参数写法 `RemoteForward <listen> <target>`；
# 把命令行那种 `2230:localhost:8022` 的单参数写法抄进来，ssh 会直接拒绝启动。
fwd_line=$(grep -m1 '^    RemoteForward ' "$ROOT/install.sh")
if [ -z "$fwd_line" ]; then
    printf 'install.sh 里找不到 RemoteForward 模板，测试需要更新\n' >&2
    exit 1
fi
fwd_line=$(printf '%s\n' "$fwd_line" | sed 's/\$reverse_port/2230/g; s/\$device_port/8022/g')
cfg=$(mktemp)
printf 'Host fwdtest\n%s\n' "$fwd_line" > "$cfg"
if ! ssh -F "$cfg" -G fwdtest >/dev/null 2>&1; then
    printf 'RemoteForward 这行 ssh 解析不了：%s\n' "$fwd_line" >&2
    ssh -F "$cfg" -G fwdtest 2>&1 | head -2 >&2
    rm -f "$cfg"
    exit 1
fi
rm -f "$cfg"

# --- 命令要装进本来就处于 PATH 里的目录（Termux 上是 $PREFIX/bin）---
mkdir -p "$TMP_HOME/prefix/bin"
printf '0\n' | env TERMUX_VERSION=0.118 PREFIX="$TMP_HOME/prefix" PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p7" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k7" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
if [ ! -x "$TMP_HOME/prefix/bin/device-tunnel" ]; then
    printf 'device-tunnel 没有装进 $PREFIX/bin（默认 BIN_DIR 选错了）\n' >&2
    exit 1
fi

# --- 「已有配置」这条路径绝不能动 ~/.ssh/config ---

mkdir -p "$TMP_HOME/p8" "$TMP_HOME/.ssh"
cat > "$TMP_HOME/p8/config" <<'EOF'
DEVICE_ID=xiaomi
DEVICE_KEY=/nonexistent
EOF
cat > "$TMP_HOME/.ssh/config" <<'EOF'
Host server
    HostName example.com

# >>> device-onboard:xiaomi BEGIN
Host onboard-tunnel-xiaomi
    RemoteForward 2230 localhost:8022
# <<< device-onboard:xiaomi END
EOF
cp "$TMP_HOME/.ssh/config" "$TMP_HOME/.ssh/config.before"
printf '0\n' | TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p8" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k8" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b8" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
if ! diff -q "$TMP_HOME/.ssh/config.before" "$TMP_HOME/.ssh/config" >/dev/null; then
    printf '「已有配置」这条路径不该改动 ~/.ssh/config\n' >&2
    exit 1
fi
if grep -q '已清理' /tmp/device-onboard-smoke.out; then
    printf '「已有配置」这条路径不该执行清理\n' >&2
    exit 1
fi

# 配置块真的丢了，要明确提示而不是装没看见
cat > "$TMP_HOME/.ssh/config" <<'EOF'
Host server
    HostName example.com
EOF
printf '0\n' | TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p8" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k8" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b8" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
grep -q '找不到本设备' /tmp/device-onboard-smoke.out
rm -f "$TMP_HOME/.ssh/config" "$TMP_HOME/.ssh/config.before"

# --- 完整跑一遍接入（假 ssh），并验证生成的配置真能被 ssh 解析 ---
# 这组是昨晚那串坑的回归防线：配置块写法、PATH、e2e 握手、状态文件。

cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
    *DEVICE-ONBOARD-E2E-OK*) printf 'DEVICE-ONBOARD-E2E-OK' ;;
esac
case "$*" in
    *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;;
esac
case "$*" in
    *-R*localhost*) exec sleep 30 ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

mkdir -p "$TMP_HOME/p9"
: > "$TMP_HOME/full.log"
printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$TMP_HOME/full.log" TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p9" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k9" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b9" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true

grep -q '设备接入完成' /tmp/device-onboard-smoke.out
grep -q 'DEVICE-ONBOARD-E2E-OK' "$TMP_HOME/full.log"
[ -f "$TMP_HOME/p9/config" ] || { printf '状态文件没写出来\n' >&2; exit 1; }
grep -q 'Host onboard-tunnel-xiaomitest' "$TMP_HOME/.ssh/config" || { printf '反向隧道 Host 没写进配置\n' >&2; exit 1; }

# 生成的配置必须能被真 ssh 解析 —— 昨晚就是这条把整台设备弄瘸的
if ! ssh -F "$TMP_HOME/.ssh/config" -G onboard-tunnel-xiaomitest >/dev/null 2>&1; then
    printf '生成的 ~/.ssh/config 解析不过：\n' >&2
    ssh -F "$TMP_HOME/.ssh/config" -G onboard-tunnel-xiaomitest 2>&1 | head -3 >&2
    exit 1
fi

# --- device-harness：一键（后台隧道 + 前台 harness + 退出收尾）---

mkdir -p "$TMP_HOME/hh"
: > "$TMP_HOME/hh.log"
env FAKE_SSH_LOG="$TMP_HOME/hh.log" TERMUX_VERSION=0.118 \
    PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
    sh "$TMP_HOME/b9/device-harness" echo-test > "$TMP_HOME/hh.out" 2>&1 || true

grep -q '隧道就绪' "$TMP_HOME/hh.out" || { printf '没等到隧道就绪：\n'; sed 's/^/  /' "$TMP_HOME/hh.out" >&2; exit 1; }
grep -q 'echo-test' "$TMP_HOME/hh.log" || { printf '没在服务器上跑 harness\n' >&2; exit 1; }
grep -q "DEVICE_ONBOARD_DEVICE_ALIAS='onboard-device-xiaomitest'" "$TMP_HOME/hh.log" || {
    printf '没把设备身份传给 harness\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh.log" >&2
    exit 1
}
grep -q '已收起' "$TMP_HOME/hh.out" || { printf '退出时没收隧道：\n'; sed 's/^/  /' "$TMP_HOME/hh.out" >&2; exit 1; }

# --- 中途失败必须自动回滚：只撤本次改动，别碰别人的配置 ---
# 用假 ssh 让「写服务器 ~/.ssh/config」这一步返回非 0，流程应当在
# 写完本地配置后就地失败，并由 EXIT trap 把本次新增的东西全部撤回。

cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
    *DEVICE-ONBOARD-E2E-OK*) printf 'DEVICE-ONBOARD-E2E-OK'; exit 0 ;;
esac
# 只让写服务器 ssh config 的那一步失败（命令串里带 file="$HOME/.ssh/config"）
case "$*" in
    *'file="$HOME/.ssh/config"'*) exit 1 ;;
esac
case "$*" in
    *'-R'*'localhost'*) exec sleep 30 ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

# 重置到已知状态：keepme 不属于本设备，回滚后必须原样还在
rm -f "$TMP_HOME/.ssh/config" "$TMP_HOME/.ssh/config.device-onboard.bak"
rm -rf "$TMP_HOME/p10" "$TMP_HOME/k10"
cat > "$TMP_HOME/.ssh/config" <<'EOF'
Host keepme
    HostName keep.example.com
EOF

rb_status=0
printf '1\nrollbacktest\n203.0.113.9\nubuntu\n22\n' | env FAKE_SSH_LOG="$TMP_HOME/rollback.log" TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p10" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k10" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b10" \
    sh "$ROOT/install.sh" >"$TMP_HOME/rollback.out" 2>&1 || rb_status=$?

# ① 失败必须以非 0 退出
if [ "$rb_status" = 0 ]; then
    printf '接入中途失败却仍以 0 退出\n' >&2
    exit 1
fi
# 回滚确实被触发
if ! grep -q '开始回滚' "$TMP_HOME/rollback.out"; then
    printf '失败后没有触发自动回滚：\n' >&2
    sed 's/^/  /' "$TMP_HOME/rollback.out" >&2
    exit 1
fi
# ② 本地配置里没有本设备的块
if grep -q 'device-onboard:rollbacktest' "$TMP_HOME/.ssh/config"; then
    printf '回滚后本地配置里仍残留本设备的块：\n' >&2
    sed 's/^/  /' "$TMP_HOME/.ssh/config" >&2
    exit 1
fi
# ⑤ 不属于本设备的内容没被误删
if ! grep -q 'Host keepme' "$TMP_HOME/.ssh/config"; then
    printf '回滚误删了与本设备无关的配置（keepme）\n' >&2
    exit 1
fi
# ③ 本次生成的设备密钥已删除
if [ -f "$TMP_HOME/k10/rollbacktest-device" ] || [ -f "$TMP_HOME/k10/rollbacktest-device.pub" ]; then
    printf '回滚后本次生成的设备密钥仍然存在\n' >&2
    exit 1
fi
# ④ 状态文件不存在
if [ -f "$TMP_HOME/p10/config" ]; then
    printf '回滚后状态文件仍然存在\n' >&2
    exit 1
fi

printf 'smoke tests passed\n'
