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
# 'sh -s' 的远端脚本直接本地执行：这样 install.sh 送到服务器上的脚本能在沙箱里真的落盘。
case "$*" in
    *'sh -s'*) exec sh ;;
esac
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

# --- ~/.codex/AGENTS.md：设备会话说明块（首次创建、幂等、块外不动、可跳过）---
# Codex 只读 ~/.codex/AGENTS.md（不读 ~/.agents/AGENTS.md），所以块必须写在这里。
# 假 ssh 对 'sh -s' 直接本地执行，于是这段远端脚本真的在 $TMP_HOME 下落盘。

AGENTS_MD="$TMP_HOME/.codex/AGENTS.md"

run_full_install_again() {
    printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$TMP_HOME/full.log" TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
        DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p9" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k9" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b9" \
        sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
}

# 首次：文件不存在 → 创建，含块，权限 600
[ -f "$AGENTS_MD" ] || { printf '首次接入没有创建 ~/.codex/AGENTS.md\n' >&2; exit 1; }
agents_mode=$(stat -c %a "$AGENTS_MD" 2>/dev/null || stat -f %Lp "$AGENTS_MD")
[ "$agents_mode" = 600 ] || { printf 'AGENTS.md 权限不是 600（是 %s）\n' "$agents_mode" >&2; exit 1; }
grep -q '<!-- DEVICE-ONBOARD-AGENTS BEGIN -->' "$AGENTS_MD" || { printf 'AGENTS.md 缺少起始标记\n' >&2; exit 1; }
grep -q '<!-- DEVICE-ONBOARD-AGENTS END -->' "$AGENTS_MD" || { printf 'AGENTS.md 缺少结束标记\n' >&2; exit 1; }
grep -q '## 设备会话' "$AGENTS_MD" || { printf 'AGENTS.md 缺少块标题\n' >&2; exit 1; }
grep -q 'DEVICE_ONBOARD_ID' "$AGENTS_MD" || { printf 'AGENTS.md 没说明看 DEVICE_ONBOARD_ID\n' >&2; exit 1; }
grep -q '有值就是它' "$AGENTS_MD" || { printf 'AGENTS.md 没按新文案说明 DEVICE_ONBOARD_ID\n' >&2; exit 1; }
grep -q '~/.codex/skills/device-onboard/SKILL.md' "$AGENTS_MD" || { printf 'AGENTS.md 没指向设备档案\n' >&2; exit 1; }
if grep -q '设备目录是' "$AGENTS_MD"; then
    printf 'AGENTS.md 仍保留旧的「设备目录」表述（身份不该靠工作目录）\n' >&2
    sed 's/^/  /' "$AGENTS_MD" >&2
    exit 1
fi

# 二次运行：块整体替换、不重复累加；块外内容原样保留
printf '这行不在块里，必须原样保留。\n' >> "$AGENTS_MD"
rm -f "$TMP_HOME/p9/config"
run_full_install_again
[ "$(grep -c 'DEVICE-ONBOARD-AGENTS BEGIN' "$AGENTS_MD")" = 1 ] || {
    printf '二次运行把 AGENTS.md 的块写重复了：\n' >&2; sed 's/^/  /' "$AGENTS_MD" >&2; exit 1
}
grep -q '这行不在块里，必须原样保留。' "$AGENTS_MD" || { printf 'AGENTS.md 块外内容被改动\n' >&2; exit 1; }

# 文件里有其它内容但没有块 → 追加块，块外内容保留
awk '/<!-- DEVICE-ONBOARD-AGENTS BEGIN -->/{skip=1;next} /<!-- DEVICE-ONBOARD-AGENTS END -->/{skip=0;next} !skip{print}' "$AGENTS_MD" > "$AGENTS_MD.tmp" && mv "$AGENTS_MD.tmp" "$AGENTS_MD"
if grep -q 'DEVICE-ONBOARD-AGENTS BEGIN' "$AGENTS_MD"; then
    printf '测试准备失败：块没有被去掉\n' >&2; exit 1
fi
rm -f "$TMP_HOME/p9/config"
run_full_install_again
grep -q '<!-- DEVICE-ONBOARD-AGENTS BEGIN -->' "$AGENTS_MD" || { printf '无块文件没有追加块\n' >&2; exit 1; }
[ "$(grep -c 'DEVICE-ONBOARD-AGENTS BEGIN' "$AGENTS_MD")" = 1 ] || { printf '追加块时写重复了\n' >&2; exit 1; }
grep -q '这行不在块里，必须原样保留。' "$AGENTS_MD" || { printf '追加块时块外内容被改动\n' >&2; exit 1; }

# DEVICE_ONBOARD_AGENTS_MD=0 → 跳过，不创建（接入照常完成）
rm -f "$AGENTS_MD" "$TMP_HOME/p9/config"
printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env DEVICE_ONBOARD_AGENTS_MD=0 FAKE_SSH_LOG="$TMP_HOME/full.log" TERMUX_VERSION=0.118 PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p9" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k9" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b9" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
if [ -e "$AGENTS_MD" ]; then
    printf 'DEVICE_ONBOARD_AGENTS_MD=0 却仍然写了 AGENTS.md：\n' >&2; sed 's/^/  /' "$AGENTS_MD" >&2; exit 1
fi
grep -q '设备接入完成' /tmp/device-onboard-smoke.out || {
    printf 'DEVICE_ONBOARD_AGENTS_MD=0 时接入没有正常完成：\n' >&2; sed 's/^/  /' /tmp/device-onboard-smoke.out >&2; exit 1
}

# --- device-harness：一键（后台隧道 + 前台 harness + 退出收尾）---

mkdir -p "$TMP_HOME/hh"
: > "$TMP_HOME/hh.log"
env FAKE_SSH_LOG="$TMP_HOME/hh.log" TERMUX_VERSION=0.118 \
    PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
    sh "$TMP_HOME/b9/device-harness" -C /somewhere codex > "$TMP_HOME/hh.out" 2>&1 || true

grep -q '隧道就绪' "$TMP_HOME/hh.out" || { printf '没等到隧道就绪：\n'; sed 's/^/  /' "$TMP_HOME/hh.out" >&2; exit 1; }
grep -q 'codex --no-daemon' "$TMP_HOME/hh.log" || { printf '没在服务器上按预期启动 codex\n' >&2; exit 1; }
grep -q -- '--no-daemon' "$TMP_HOME/hh.log" || {
    printf '启动 codex 时没带 --no-daemon（否则环境变量到不了它的工具）\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh.log" >&2
    exit 1
}
grep -q -- '-C "/somewhere"' "$TMP_HOME/hh.log" || {
    printf 'device-harness -C 没把工作目录传给 codex\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh.log" >&2
    exit 1
}
grep -q "DEVICE_ONBOARD_ID='xiaomitest'" "$TMP_HOME/hh.log" || {
    printf '没把 DEVICE_ONBOARD_ID 传给 harness\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh.log" >&2
    exit 1
}
grep -q "DEVICE_ONBOARD_DEVICE_ALIAS='onboard-device-xiaomitest'" "$TMP_HOME/hh.log" || {
    printf '没把设备身份传给 harness\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh.log" >&2
    exit 1
}
grep -q '已收起' "$TMP_HOME/hh.out" || { printf '退出时没收隧道：\n'; sed 's/^/  /' "$TMP_HOME/hh.out" >&2; exit 1; }

# --- 不带 -C：默认落在服务器家目录（身份改由 DEVICE_ONBOARD_ID 传递，不靠工作目录）---

: > "$TMP_HOME/def.log"
env FAKE_SSH_LOG="$TMP_HOME/def.log" TERMUX_VERSION=0.118 \
    PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
    sh "$TMP_HOME/b9/device-harness" codex > "$TMP_HOME/def.out" 2>&1 || true
grep -qF -- '-C "$HOME"' "$TMP_HOME/def.log" || {
    printf '不给 -C 时没有默认落在服务器家目录：\n' >&2
    sed 's/^/  /' "$TMP_HOME/def.log" >&2
    exit 1
}
# 默认落点绝不能再带设备名目录（身份不该靠工作目录表示）
if grep -qF -- '-C "$HOME/xiaomitest"' "$TMP_HOME/def.log"; then
    printf '默认落点仍带设备目录（身份不该靠工作目录）：\n' >&2
    sed 's/^/  /' "$TMP_HOME/def.log" >&2
    exit 1
fi

# 显式 -C 优先，压过默认家目录
: > "$TMP_HOME/explicit.log"
env FAKE_SSH_LOG="$TMP_HOME/explicit.log" TERMUX_VERSION=0.118 \
    PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
    sh "$TMP_HOME/b9/device-harness" -C /explicit codex > "$TMP_HOME/explicit.out" 2>&1 || true
grep -qF -- '-C "/explicit"' "$TMP_HOME/explicit.log" || {
    printf '显式 -C 没有优先：\n' >&2
    sed 's/^/  /' "$TMP_HOME/explicit.log" >&2
    exit 1
}
if grep -qF -- '-C "$HOME"' "$TMP_HOME/explicit.log"; then
    printf '显式 -C 被默认家目录覆盖了\n' >&2
    exit 1
fi

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

# ~ 开头的目录：应翻译成远端可展开的 $HOME（手机上先展开就错了）
# 这组需要能报「隧道就绪」的假 ssh —— 回滚那组只用来制造失败。
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
    *'sh -s'*) exec sh ;;
esac
case "$*" in
    *DEVICE-ONBOARD-E2E-OK*) printf 'DEVICE-ONBOARD-E2E-OK' ;;
esac
case "$*" in
    *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;;
esac
case "$*" in
    *-R*localhost*) exec sleep 30 ;;
esac
# 服务器档案的读取：装了 FAKE_SKILL_MD 就当作远端档案返回（端口分配要靠它）。
case "$*" in
    *cat*device-onboard/SKILL.md*)
        if [ -n "${FAKE_SKILL_MD:-}" ] && [ -f "$FAKE_SKILL_MD" ]; then cat "$FAKE_SKILL_MD"; fi
        exit 0
        ;;
esac
# 服务器侧回连块的写入：块是走 stdin 送过去的，把 stdin 落盘才能断言它写了哪个端口。
case "$*" in
    *device-onboard:*BEGIN*)
        if [ -n "${FAKE_SERVER_BLOCK:-}" ]; then cat > "$FAKE_SERVER_BLOCK"; fi
        exit 0
        ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"
: > "$TMP_HOME/hh2.log"
env FAKE_SSH_LOG="$TMP_HOME/hh2.log" TERMUX_VERSION=0.118 \
    PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
    sh "$TMP_HOME/b9/device-harness" -C '~/phone' codex > "$TMP_HOME/hh2.out" 2>&1 || true

grep -q -- '-C "$HOME/phone"' "$TMP_HOME/hh2.log" || {
    printf 'device-harness 没有把 ~ 翻译成远端可展开的 $HOME\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh2.log" >&2
    exit 1
}

# --- 反向端口按设备固定：避开别人登记的端口 / 复用自己登记的端口 ---
# 端口是服务器上 [127.0.0.1]:<port> 这个 ssh 主机的身份，known_hosts 的键里带着端口。
# 两台设备先后用同一个端口，后到的那台会被旧指纹挡住（Host key verification failed）。
# 所以分配必须看档案登记，而不是"谁先来谁拿"。

PORT_ARCHIVE="$TMP_HOME/port-archive.md"
cat > "$PORT_ARCHIVE" <<'EOF'
<!-- DEVICE-ONBOARD-CONVENTION BEGIN -->
共享约定
<!-- DEVICE-ONBOARD-CONVENTION END -->

<!-- DEVICE-ONBOARD:xiaomitest BEGIN -->
device_name: xiaomitest
reverse_port: 2230
<!-- DEVICE-ONBOARD:xiaomitest END -->
EOF

# ① 另一台设备接入：2230 已被 xiaomitest 登记 → 必须拿 2231
mkdir -p "$TMP_HOME/x10"
printf '1\nseconddev\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$TMP_HOME/x10/ssh.log" FAKE_SKILL_MD="$PORT_ARCHIVE" FAKE_SERVER_BLOCK="$TMP_HOME/x10/server-block" TERMUX_VERSION=0.118 PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME/x10" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2231 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p10" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k10" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b10" \
    sh "$ROOT/install.sh" >"$TMP_HOME/x10/out" 2>&1 || true

grep -q '跳过端口 2230' "$TMP_HOME/x10/out" || {
    printf '没有跳过已登记给别的设备的端口 2230\n' >&2
    sed 's/^/  /' "$TMP_HOME/x10/out" >&2
    exit 1
}
grep -q 'REVERSE_PORT=2231' "$TMP_HOME/p10/config" || {
    printf '另一台设备没有拿到 2231（应避开已登记的 2230）\n' >&2
    sed 's/^/  /' "$TMP_HOME/p10/config" 2>/dev/null >&2
    exit 1
}
grep -q 'RemoteForward 2231 localhost' "$TMP_HOME/x10/.ssh/config" || {
    printf '设备侧隧道块没写 2231\n' >&2
    sed 's/^/  /' "$TMP_HOME/x10/.ssh/config" 2>/dev/null >&2
    exit 1
}
# 服务器侧的 Host 块（onboard-device-*）端口才是会撞 known_hosts 的那个
grep -q 'Port 2231' "$TMP_HOME/x10/server-block" || {
    printf '服务器回连块没写 2231\n' >&2
    sed 's/^/  /' "$TMP_HOME/x10/server-block" 2>/dev/null >&2
    exit 1
}

# ② 同一台设备重装：2230 是它自己登记的 → 复用（指纹才不会变），不要贪 2231
mkdir -p "$TMP_HOME/x11"
printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$TMP_HOME/x11/ssh.log" FAKE_SKILL_MD="$PORT_ARCHIVE" FAKE_SERVER_BLOCK="$TMP_HOME/x11/server-block" TERMUX_VERSION=0.118 PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME/x11" \
    DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2231 \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p11" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k11" DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/b11" \
    sh "$ROOT/install.sh" >"$TMP_HOME/x11/out" 2>&1 || true

grep -q 'REVERSE_PORT=2230' "$TMP_HOME/p11/config" || {
    printf '重装没有复用自己登记的 2230（指纹会因此失效）\n' >&2
    sed 's/^/  /' "$TMP_HOME/p11/config" 2>/dev/null >&2
    exit 1
}
grep -q 'Port 2230' "$TMP_HOME/x11/server-block" || {
    printf '重装把服务器回连块的端口改掉了（应仍为 2230）\n' >&2
    sed 's/^/  /' "$TMP_HOME/x11/server-block" 2>/dev/null >&2
    exit 1
}

# --- device-harness 把「设备侧当前目录」带给服务器（上下文，不是身份）---
# 目录名可能带空格 / 单引号，拼进远端命令行前必须转义 —— 不转义就是注入口子。
# 这里不只看字符串，而是把 harness 真正拼出来的远端命令行交给真 sh 跑一遍，验回环。
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
    *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;;
esac
case "$*" in
    *DEVICE_ONBOARD_ID=*)
        for a in "$@"; do last=$a; done
        printf '%s\n' "$last" >> "$FAKE_REMOTE_CMD"
        exit 0
        ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/sh
printf 'ID=[%s]\n' "$DEVICE_ONBOARD_ID"
printf 'ALIAS=[%s]\n' "$DEVICE_ONBOARD_DEVICE_ALIAS"
printf 'CWD=[%s]\n' "$DEVICE_ONBOARD_DEVICE_CWD"
printf 'REL=[%s]\n' "$DEVICE_ONBOARD_DEVICE_CWD_REL"
EOF
chmod 755 "$FAKE_BIN/codex"

run_harness_in() {
    _dir=$1
    _log=$2
    shift 2
    : > "$_log"
    ( cd "$_dir" && env FAKE_SSH_LOG="$TMP_HOME/hh3.log" FAKE_REMOTE_CMD="$_log" TERMUX_VERSION=0.118 \
        PATH="$TMP_HOME/b9:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
        sh "$TMP_HOME/b9/device-harness" ${1+"$@"} >"$TMP_HOME/hh3.out" 2>&1 ) || true
}

# ① 从一个带空格和单引号的目录里启动
QDIR="$TMP_HOME/it's a proj"
mkdir -p "$QDIR"
run_harness_in "$QDIR" "$TMP_HOME/remote1.log" codex
if [ ! -s "$TMP_HOME/remote1.log" ]; then
    printf 'device-harness 没把远端命令行送出来（ssh 没被调用？）\n' >&2
    sed 's/^/  /' "$TMP_HOME/hh3.out" >&2
    exit 1
fi
rcmd=$(tail -1 "$TMP_HOME/remote1.log")
case "$rcmd" in
    *"it'\\''s a proj"*) ;;
    *)  printf '目录名没有被单引号转义（注入口子）\n  %s\n' "$rcmd" >&2; exit 1 ;;
esac
got=$(PATH="$FAKE_BIN:$PATH" sh -c "$rcmd" 2>&1)
printf '%s\n' "$got" | grep -qxF "CWD=[$QDIR]" || {
    printf '设备侧绝对路径没传到 / 回环不一致\n  期望 CWD=[%s]\n  实际:\n%s\n' "$QDIR" "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF "REL=[it's a proj]" || {
    printf '相对家目录的形式不对\n  实际:\n%s\n' "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF "ID=[xiaomitest]" || {
    printf '身份变量丢了这个不该动的东西\n%s\n' "$got" >&2
    exit 1
}

# ② 就在家目录里：REL 应为 "."
run_harness_in "$TMP_HOME" "$TMP_HOME/remote2.log" codex
got=$(PATH="$FAKE_BIN:$PATH" sh -c "$(tail -1 "$TMP_HOME/remote2.log")" 2>&1)
printf '%s\n' "$got" | grep -qxF 'REL=[.]' || {
    printf '在家目录时 REL 应该是「.」\n%s\n' "$got" >&2
    exit 1
}

# ③ 在家目录之外：REL 应为空（空值有明确含义，不能被当成"家目录"）
run_harness_in / "$TMP_HOME/remote3.log" codex
got=$(PATH="$FAKE_BIN:$PATH" sh -c "$(tail -1 "$TMP_HOME/remote3.log")" 2>&1)
printf '%s\n' "$got" | grep -qxF 'REL=[]' || {
    printf '在家目录之外时 REL 应该是空\n%s\n' "$got" >&2
    exit 1
}

# ④ 换 harness + 带空格的参数：剩余参数必须逐个转义，不能被拆散
# （实测踩过：不转义时 `-p 'two words here'` 到远端会变成 4 个参数。）
cat > "$FAKE_BIN/claude" <<'EOF'
#!/bin/sh
printf 'ARGC=%s\n' "$#"
for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
EOF
chmod 755 "$FAKE_BIN/claude"
run_harness_in "$TMP_HOME" "$TMP_HOME/remote4.log" claude -p 'two words here'
got=$(PATH="$FAKE_BIN:$PATH" sh -c "$(tail -1 "$TMP_HOME/remote4.log")" 2>&1)
printf '%s\n' "$got" | grep -qxF 'ARGC=2' || {
    printf '换 harness / 参数被拆散：期望 2 个参数\n%s\n' "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF 'ARG=[two words here]' || {
    printf '带空格的参数没有原样送达\n%s\n' "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF 'ARG=[-p]' || {
    printf '选项参数缺失\n%s\n' "$got" >&2
    exit 1
}

printf 'smoke tests passed\n'