#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# 取物理路径：device-harness 用 `pwd -P` 报告设备侧目录（故意解掉符号链接），
# 而 macOS 上 mktemp 给的 /var/... 其实是指向 /private/var/... 的符号链接 ——
# 两边不一致就会把「产品行为正确」误判成「路径没传到」。整棵树统一用物理路径。
TMP_HOME=$(mktemp -d)
TMP_HOME=$(CDPATH= cd -- "$TMP_HOME" && pwd -P)
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
SERVER_HOST_ALIAS=server
REVERSE_PORT=2230
DEVICE_PORT=8022
EOF

FAKE_SSH_LOG="$TMP_HOME/ssh.log" PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/config/config" sh "$ROOT/bin/device-tunnel"
grep -q '反向隧道已建立' "$TMP_HOME/ssh.log"
# 转发参数由命令自己拼，不再存进 ssh config —— 端口只有一个真相（状态文件）。
grep -q -- '-R 2230:localhost:8022' "$TMP_HOME/ssh.log" || {
    printf 'device-tunnel 没把 -R <server>:localhost:<device> 拼进命令行：\n' >&2
    sed 's/^/  /' "$TMP_HOME/ssh.log" >&2
    exit 1
}
# 就绪信号的全部依据：转发绑不上就让 ssh 直接退出
grep -q -- 'ExitOnForwardFailure=yes' "$TMP_HOME/ssh.log" || {
    printf 'device-tunnel 没带 ExitOnForwardFailure（「已建立」就不再是服务器亲口说的）\n' >&2
    exit 1
}
# 连的是 server 这个别名
case "$(head -1 "$TMP_HOME/ssh.log")" in
    *' server '*) : ;;
    *) printf 'device-tunnel 没连 server 别名：%s\n' "$(head -1 "$TMP_HOME/ssh.log")" >&2; exit 1 ;;
esac

# 端口不是数字时必须在拼 -R 之前挡住，说清是哪个变量的错
cat > "$TMP_HOME/config/badport" <<EOF
SERVER_HOST_ALIAS=server
REVERSE_PORT=22x0
DEVICE_PORT=8022
EOF
: > "$TMP_HOME/ssh.log"
if FAKE_SSH_LOG="$TMP_HOME/ssh.log" PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/config/badport" sh "$ROOT/bin/device-tunnel" \
        >/tmp/device-onboard-smoke.out 2>&1; then
    printf 'REVERSE_PORT 不是数字时 device-tunnel 竟然照跑\n' >&2
    exit 1
fi
grep -q 'REVERSE_PORT 不是数字' /tmp/device-onboard-smoke.out
if [ -s "$TMP_HOME/ssh.log" ]; then
    printf '端口非法时不该发起 ssh（会撞出 Bad forwarding specification）\n' >&2
    exit 1
fi

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

# --- 回归防护：device-tunnel 拼出来的 -R 必须能被 ssh 解析 ---
# 曾经踩过：把 ssh_config 的双参数写法（`RemoteForward <listen> <target>`）和命令行的
# 单参数写法（`-R 2230:localhost:8022`）混着用，ssh 直接拒绝启动、而且报错指向别处。
# 现在转发参数只在命令里出现一次，就把那一份拿去给真 ssh 验。
fwd_spec=$(grep -m1 -o '\-R "\${REVERSE_PORT}:localhost:\${DEVICE_PORT}"' "$ROOT/bin/device-tunnel")
if [ -z "$fwd_spec" ]; then
    printf 'bin/device-tunnel 里找不到 -R 的拼法，测试需要更新\n' >&2
    exit 1
fi
fwd_spec=$(printf '%s\n' "$fwd_spec" | sed 's/.*-R "//; s/"$//; s/\${REVERSE_PORT}/2230/g; s/\${DEVICE_PORT}/8022/g')
if ! ssh -G -R "$fwd_spec" localhost >/dev/null 2>&1; then
    printf 'ssh 解析不了这个转发规格：-R %s\n' "$fwd_spec" >&2
    exit 1
fi
# 反向通道不再单独占 Host：设备侧 config 里出现 RemoteForward 就说明又退回老写法了
if grep -q '^    RemoteForward' "$ROOT/install.sh"; then
    printf 'install.sh 又往 ssh config 里写 RemoteForward 了（端口会变成两处真相）\n' >&2
    exit 1
fi

# --- 命令要装进本来就处于 PATH 里的目录（Termux 上是 $PREFIX/bin）---
mkdir -p "$TMP_HOME/prefix/bin"
printf '0\n' | env TERMUX_VERSION=0.118 PREFIX="$TMP_HOME/prefix" PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
    DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/p7" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/k7" \
    sh "$ROOT/install.sh" >/tmp/device-onboard-smoke.out 2>&1 || true
if [ ! -x "$TMP_HOME/prefix/bin/device-tunnel" ]; then
    printf 'device-tunnel 没有装进 $PREFIX/bin（默认 BIN_DIR 选错了）\n' >&2
    exit 1
fi

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
# harness 探测（install.sh 会问服务器装了哪些 harness）：默认当装了 codex，
# 老用例行为不变；新用例用 FAKE_HARNESSES 指定（可含 claude，或留空）。
case "$*" in
    *'for c in codex claude'*) printf '%s' "${FAKE_HARNESSES-codex}" ;;
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

# 设备侧只写一个 Host，且名字就叫 server
grep -qx 'Host server' "$TMP_HOME/.ssh/config" || {
    printf '设备侧没有写出 Host server：\n' >&2
    sed 's/^/  /' "$TMP_HOME/.ssh/config" >&2
    exit 1
}
# 反向通道不占 Host：config 里既不该有 onboard-tunnel，也不该有 RemoteForward
if grep -q 'onboard-tunnel\|RemoteForward' "$TMP_HOME/.ssh/config"; then
    printf '设备侧 config 里又出现了反向隧道的痕迹（端口会出现两处真相）：\n' >&2
    grep -n 'onboard-tunnel\|RemoteForward' "$TMP_HOME/.ssh/config" | sed 's/^/  /' >&2
    exit 1
fi
grep -qx 'SERVER_HOST_ALIAS=server' "$TMP_HOME/p9/config" || { printf '状态文件里的别名不是 server\n' >&2; exit 1; }
if grep -q 'TUNNEL_HOST_ALIAS' "$TMP_HOME/p9/config"; then
    printf '状态文件里还在写 TUNNEL_HOST_ALIAS（已经不需要了）\n' >&2
    exit 1
fi

# 生成的配置必须能被真 ssh 解析 —— 昨晚就是这条把整台设备弄瘸的
if ! ssh -F "$TMP_HOME/.ssh/config" -G server >/dev/null 2>&1; then
    printf '生成的 ~/.ssh/config 解析不过：\n' >&2
    ssh -F "$TMP_HOME/.ssh/config" -G server 2>&1 | head -3 >&2
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

# --- device-harness dsh：把服务器的 Web GUI 转到设备的 127.0.0.1 ---
# dsh 不是终端会话：`dsh web` 起一个只绑 loopback 的网页服务，脚本要
#   ① 在服务器上挑一个空闲端口给它监听，
#   ② 用 ssh -L 把设备 127.0.0.1:<同号> 转到那个端口，
#   ③ 等 dsh web 自己打印 `dsh web: <带凭据的 URL>`（不是等端口），
#   ④ 把那条 URL 原样交给用户点开。
WBIN="$TMP_HOME/wbin"
mkdir -p "$WBIN"
cat > "$WBIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
    *'ss -ltn'*) printf '%s' "${FAKE_WEB_PORT:-9230}"; exit 0 ;;
    *'command -v dsh'*) [ "${FAKE_NO_DSH:-0}" = 1 ] && exit 1; exit 0 ;;
esac
case "$*" in
    *'dsh web'*)
        if [ "${FAKE_DSH_FAIL:-0}" = 1 ]; then printf 'dsh: 起不来\n' >&2; exit 1; fi
        printf 'dsh web: http://127.0.0.1:%s/?token=SECRET\n' "${FAKE_WEB_PORT:-9230}"
        exit 0 ;;
esac
case "$*" in *'反向隧道已建立'*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;; esac
case "$*" in *'-R'*localhost*) exec sleep 30 ;; esac
exit 0
EOF
chmod 755 "$WBIN/ssh"
# 假 nc：把指定端口当成「设备上已经有人在听」，用来验端口顺位与 URL 改写
cat > "$WBIN/nc" <<'EOF'
#!/bin/sh
case "$3" in "${FAKE_BUSY_PORT:-none}") exit 0 ;; *) exit 1 ;; esac
EOF
chmod 755 "$WBIN/nc"

# run_dsh <占用端口|none> <服务器没有 dsh:0|1> <dsh 起不来:0|1> [dsh 参数…]
# 场景一律走参数、不用前缀赋值：给 shell 函数加的前缀变量会留在当前 shell 里，
# 上一个场景的开关会渗到下一个场景（真踩过：③ 的 FAKE_NO_DSH 渗进了 ④）。
run_dsh() {
    _busy=$1; _no_dsh=$2; _fail_dsh=$3
    shift 3
    : > "$TMP_HOME/w.log"
    env FAKE_SSH_LOG="$TMP_HOME/w.log" TERMUX_VERSION=0.118 \
        PATH="$TMP_HOME/b9:$WBIN:$FAKE_BIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_CONFIG_FILE="$TMP_HOME/p9/config" \
        DEVICE_ONBOARD_DSH_WEB_PORT=9230 DEVICE_ONBOARD_DSH_WEB_PORT_END=9299 \
        FAKE_WEB_PORT=9230 FAKE_BUSY_PORT="$_busy" FAKE_NO_DSH="$_no_dsh" FAKE_DSH_FAIL="$_fail_dsh" \
        sh "$TMP_HOME/b9/device-harness" dsh "$@" > "$TMP_HOME/w.out" 2>&1
}

# ① 正常路径：同号转发、URL 原样给用户、反向隧道照旧在场
run_dsh none 0 0 || {
    printf 'device-harness dsh 正常路径失败：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}
grep -q -- '-L 9230:localhost:9230' "$TMP_HOME/w.log" || {
    printf '没把 dsh web 的端口本地转发到设备（应有 -L 9230:localhost:9230）：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.log" >&2
    exit 1
}
grep -q -- 'dsh web --no-open --host 127.0.0.1 --port 9230' "$TMP_HOME/w.log" || {
    printf '没在服务器上按预期启动 dsh web：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.log" >&2
    exit 1
}
grep -q 'http://127.0.0.1:9230/?token=SECRET' "$TMP_HOME/w.out" || {
    printf '没把 dsh web 打印的 URL 交给用户：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}
grep -q 'dsh web 已就绪' "$TMP_HOME/w.out" || { printf '没有就绪提示\n' >&2; exit 1; }
grep -q "DEVICE_ONBOARD_ID='xiaomitest'" "$TMP_HOME/w.log" || {
    printf 'dsh 会话没带上设备身份（DEVICE_ONBOARD_ID）\n' >&2
    exit 1
}
grep -q '反向隧道已建立' "$TMP_HOME/w.log" || {
    printf 'dsh 模式没有再起反向隧道（agent 就 ssh 不回设备了）\n' >&2
    exit 1
}
# 端口由本命令统一分配：别让人传 --port 把它和 -L 弄错开
if run_dsh none 0 0 --port 9999; then
    printf 'device-harness dsh --port 没有被拒绝\n' >&2
    exit 1
fi
grep -q '别传 --port' "$TMP_HOME/w.out" || {
    printf '拒绝 --port 时没说清原因：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}

# ② 设备上同号端口被占：顺位到 9231，并把 URL 里的端口改掉
run_dsh 9230 0 0 || {
    printf 'device-harness dsh 端口顺位失败：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}
grep -q -- '-L 9231:localhost:9230' "$TMP_HOME/w.log" || {
    printf '设备端口被占时没有顺位到 9231：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.log" >&2
    exit 1
}
grep -q 'http://127.0.0.1:9231/?token=SECRET' "$TMP_HOME/w.out" || {
    printf 'URL 里的端口没跟着改（用户点开就是 404/连不上）：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}

# ③ 服务器上没有 dsh：直接说清楚
if run_dsh none 1 0; then
    printf '服务器没有 dsh 时竟然还往下跑了\n' >&2
    exit 1
fi
grep -q '服务器上找不到 dsh' "$TMP_HOME/w.out" || {
    printf '没提示服务器缺 dsh：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}

# ④ dsh web 起来就挂了：把它的输出摊给用户，别只说「失败」
if run_dsh none 0 1; then
    printf 'dsh web 挂掉时竟然算成功\n' >&2
    exit 1
fi
grep -q 'dsh: 起不来' "$TMP_HOME/w.out" || {
    printf 'dsh web 失败时没把它的输出给用户：\n' >&2
    sed 's/^/  /' "$TMP_HOME/w.out" >&2
    exit 1
}

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

# ~ 开头的目录：应翻译成远端可展开的 ${HOME}（手机上先展开就错了）
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
# 端口只该落在状态文件（device-tunnel 从这里读、自己拼 -R）——
# 设备侧 config 里再出现 RemoteForward 就是又退回「两处真相」了
if grep -q 'RemoteForward' "$TMP_HOME/x10/.ssh/config"; then
    printf '设备侧 config 里又写了 RemoteForward（端口会出现两处真相）：\n' >&2
    sed 's/^/  /' "$TMP_HOME/x10/.ssh/config" 2>/dev/null >&2
    exit 1
fi
grep -qx 'Host server' "$TMP_HOME/x10/.ssh/config" || {
    printf '设备侧没有 Host server：\n' >&2
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
# 也把 4 个上下文变量打出来：换 harness 走的是 `cd <目录> && 命令` 这条复合路径，
# 变量必须对它同样可见（实测踩过：赋值只贴在 cd 上，cd 之后就全丢了）。
printf 'ID=[%s]\n' "$DEVICE_ONBOARD_ID"
printf 'CWD=[%s]\n' "$DEVICE_ONBOARD_DEVICE_CWD"
printf 'REL=[%s]\n' "$DEVICE_ONBOARD_DEVICE_CWD_REL"
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

# ⑤ 复合命令（cd 之后）也必须拿到那 4 个变量
# 实测踩过：`VAR=x cd <目录> && 命令` 里的赋值只贴在 cd 这一个命令上（bash 下 cd
# 不是 special builtin，赋值不留在 shell 里）→ cd 之后的命令读 DEVICE_ONBOARD_ID
# 全是空。device-harness claude 正好死在这条路上。
printf '%s\n' "$got" | grep -qxF 'ID=[xiaomitest]' || {
    printf '换 harness 后身份变量丢了 —— 赋值只贴在 cd 上？\n%s\n' "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF "CWD=[$TMP_HOME]" || {
    printf '换 harness 后目录变量丢了\n%s\n' "$got" >&2
    exit 1
}
printf '%s\n' "$got" | grep -qxF 'REL=[.]' || {
    printf '换 harness 后 REL 丢了\n%s\n' "$got" >&2
    exit 1
}

# --- 按 harness 分发：服务器装了哪个 harness，就给哪个铺档案 + 提示块 ---
# codex → ~/.codex/skills/device-onboard/SKILL.md + ~/.codex/AGENTS.md
# claude → ~/.claude/skills/device-onboard/SKILL.md + ~/.claude/CLAUDE.md
# 一个都没装 → 什么都不写（不能凭空建目录）。
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in *'sh -s'*) exec sh ;; esac
case "$*" in *DEVICE-ONBOARD-E2E-OK*) printf 'DEVICE-ONBOARD-E2E-OK' ;; esac
case "$*" in *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;; esac
case "$*" in *-R*localhost*) exec sleep 30 ;; esac
# 技能档案的读写是「复合命令」而不是 sh -s：把最后一个参数当命令本地跑一遍，
# 沙箱里才会真的落盘 —— 否则断言只能看到“命令发出去了”，看不到结果。
case "$*" in
    *skills/device-onboard*)
        for a in "$@"; do last=$a; done
        exec sh -c "$last"
        ;;
esac
case "$*" in *'for c in codex claude'*) printf '%s' "${FAKE_HARNESSES-}" ;; esac
exit 0
EOF
cat > "$FAKE_BIN/sshd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh" "$FAKE_BIN/sshd"

run_install_with_harnesses() {
    _h=$1
    _home=$2
    mkdir -p "$_home"
    printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$_home/ssh.log" FAKE_HARNESSES="$_h" TERMUX_VERSION=0.118 \
        PATH="$FAKE_BIN:$PATH" HOME="$_home" \
        DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END=2230 \
        DEVICE_ONBOARD_CONFIG_DIR="$_home/cfg" DEVICE_ONBOARD_KEY_DIR="$_home/keys" DEVICE_ONBOARD_BIN_DIR="$_home/bin" \
        sh "$ROOT/install.sh" >"$_home/out" 2>&1 || true
}

# ① 两个都装：两份档案（内容一致）+ 两个记忆文件（各指自己的档案）
run_install_with_harnesses 'codex claude' "$TMP_HOME/h30"
CX_SKILL="$TMP_HOME/h30/.codex/skills/device-onboard/SKILL.md"
CL_SKILL="$TMP_HOME/h30/.claude/skills/device-onboard/SKILL.md"
CX_MD="$TMP_HOME/h30/.codex/AGENTS.md"
CL_MD="$TMP_HOME/h30/.claude/CLAUDE.md"
for f in "$CX_SKILL" "$CL_SKILL" "$CX_MD" "$CL_MD"; do
    [ -f "$f" ] || { printf '该写却没写：%s\n' "$f" >&2; sed 's/^/  /' "$TMP_HOME/h30/out" >&2; exit 1; }
done
cmp -s "$CX_SKILL" "$CL_SKILL" || { printf 'codex 与 claude 的档案内容不一致\n' >&2; exit 1; }
grep -q '<!-- DEVICE-ONBOARD-AGENTS BEGIN -->' "$CX_MD" || { printf 'codex 记忆文件缺起始标记\n' >&2; exit 1; }
grep -q '~/.codex/skills/device-onboard/SKILL.md' "$CX_MD" || { printf 'codex 记忆文件没指向自己的档案\n' >&2; exit 1; }
grep -q '<!-- DEVICE-ONBOARD-CLAUDE BEGIN -->' "$CL_MD" || { printf 'claude 记忆文件缺起始标记\n' >&2; exit 1; }
grep -q '<!-- DEVICE-ONBOARD-CLAUDE END -->' "$CL_MD" || { printf 'claude 记忆文件缺结束标记\n' >&2; exit 1; }
grep -q '~/.claude/skills/device-onboard/SKILL.md' "$CL_MD" || { printf 'claude 记忆文件没指向 claude 的档案\n' >&2; exit 1; }
grep -q 'DEVICE_ONBOARD_ID' "$CL_MD" || { printf 'claude 记忆文件没说明身份变量\n' >&2; exit 1; }
for f in "$CX_MD" "$CL_MD"; do
    _m=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
    [ "$_m" = 600 ] || { printf '%s 权限应为 600，实际 %s\n' "$f" "$_m" >&2; exit 1; }
done

# ② 只装 claude：~/.codex 下一个文件都不该出现
run_install_with_harnesses 'claude' "$TMP_HOME/h31"
[ -f "$TMP_HOME/h31/.claude/CLAUDE.md" ] || { printf '只装 claude 却没写 CLAUDE.md\n' >&2; exit 1; }
[ -f "$TMP_HOME/h31/.claude/skills/device-onboard/SKILL.md" ] || { printf '只装 claude 却没写档案\n' >&2; exit 1; }
if [ -e "$TMP_HOME/h31/.codex" ]; then
    printf '只装了 claude，却凭空建了 ~/.codex\n' >&2
    exit 1
fi

# ③ 一个都没装：目录都不建，并且明确提示
run_install_with_harnesses '' "$TMP_HOME/h32"
if [ -e "$TMP_HOME/h32/.codex" ] || [ -e "$TMP_HOME/h32/.claude" ]; then
    printf '没探测到 harness，却建了目录\n' >&2
    exit 1
fi
grep -q '没探测到' "$TMP_HOME/h32/out" || { printf '没探测到 harness 时没有提示\n' >&2; sed 's/^/  /' "$TMP_HOME/h32/out" >&2; exit 1; }

# --- 端口候选逻辑：自己的隧道要复用，别人的要让开 ---
# 背景（真机踩过）：清空服务器档案后重跑安装，候选里既没有「本设备登记过的端口」，
# 也不知道别的设备登记了什么；而本设备隧道还开着 → 2230 被自己占着、bind 必然失败
# → 顺位拿走 2231（那是 Mac 的）→ 两台设备争同一个 [127.0.0.1]:<端口> 指纹。
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in *'sh -s'*) exec sh ;; esac
case "$*" in *'for c in codex claude'*) printf '%s' "${FAKE_HARNESSES-}" ;; esac
# 服务器 ~/.ssh/config 里各设备登记的端口
case "$*" in *'Host onboard-device-'*) printf '%s' "${FAKE_CONFIG_PORTS-}" ;; esac
# 端口占用探测：FAKE_INUSE_PORTS 里的端口「有人在听」
case "$*" in
    *'ss -ltn'*)
        for p in ${FAKE_INUSE_PORTS-}; do
            case "$*" in *"sport = :$p"*) printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$p" ;;
            esac
        done
        exit 0 ;;
esac
# 反向握手探测（取命令行里最后一个 -p N，那才是被探的端口）
case "$*" in
    *DEVICE-ONBOARD-E2E-OK*)
        _p=$(printf '%s' "$*" | grep -o '\-p [0-9]*' | tail -1 | awk '{print $2}')
        for p in ${FAKE_E2E_FAIL_PORTS-}; do
            case "$_p" in "$p") exit 1 ;; esac
        done
        printf 'DEVICE-ONBOARD-E2E-OK' ;;
esac
case "$*" in *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;; esac
# 绑定：端口被人占着时 ssh 会失败（模拟 remote port forwarding failed）
case "$*" in
    *-R*localhost*)
        _p=$(printf '%s' "$*" | grep -o '\-R [0-9]*' | tail -1 | awk '{print $2}')
        for p in ${FAKE_INUSE_PORTS-}; do
            case "$_p" in "$p") exit 1 ;; esac
        done
        exec sleep 30 ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

run_install_port_case() {
    _home=$1
    mkdir -p "$_home"
    printf '1\nxiaomitest\n134.175.91.169\nubuntu\n22\n' | env FAKE_SSH_LOG="$_home/ssh.log" TERMUX_VERSION=0.118 FAKE_HARNESSES='' \
        PATH="$FAKE_BIN:$PATH" HOME="$_home" \
        DEVICE_ONBOARD_CONFIG_DIR="$_home/cfg" DEVICE_ONBOARD_KEY_DIR="$_home/keys" DEVICE_ONBOARD_BIN_DIR="$_home/bin" \
        sh "$ROOT/install.sh" >"$_home/out" 2>&1 || true
}

# ① 端口上已有本设备的隧道（握手成功）→ 直接复用，不重新绑定
FAKE_INUSE_PORTS=2230 run_install_port_case "$TMP_HOME/p30"
grep -q '^REVERSE_PORT=2230$' "$TMP_HOME/p30/cfg/config" || { printf '① 应复用 2230，实际: %s\n' "$(grep '^REVERSE_PORT=' "$TMP_HOME/p30/cfg/config")" >&2; exit 1; }
grep -q '已有本设备的隧道在跑' "$TMP_HOME/p30/out" || { printf '① 没有走「复用已有隧道」分支\n' >&2; sed 's/^/  /' "$TMP_HOME/p30/out" >&2; exit 1; }
if grep -q '\-R 2230:' "$TMP_HOME/p30/ssh.log"; then
    printf '① 复用了却还去 bind 2230（端口被自己占着，bind 必然失败）\n' >&2
    exit 1
fi

# ② 端口上有别人的隧道（占用 + 握手失败）→ 让开，顺位拿 2231
FAKE_INUSE_PORTS=2230 FAKE_E2E_FAIL_PORTS=2230 run_install_port_case "$TMP_HOME/p31"
grep -q '^REVERSE_PORT=2231$' "$TMP_HOME/p31/cfg/config" || { printf '② 应让开 2230 拿 2231，实际: %s\n' "$(grep '^REVERSE_PORT=' "$TMP_HOME/p31/cfg/config")" >&2; exit 1; }
grep -q '确认不是本设备' "$TMP_HOME/p31/out" || { printf '② 没有识别出「别人的隧道」\n' >&2; sed 's/^/  /' "$TMP_HOME/p31/out" >&2; exit 1; }

# ③ 档案被清空，但服务器 config 里仍登记着其它设备的端口 → 照样跳过
FAKE_CONFIG_PORTS='mac 2230' run_install_port_case "$TMP_HOME/p32"
grep -q '^REVERSE_PORT=2231$' "$TMP_HOME/p32/cfg/config" || { printf '③ 应跳过 config 里登记给 mac 的 2230，实际: %s\n' "$(grep '^REVERSE_PORT=' "$TMP_HOME/p32/cfg/config")" >&2; exit 1; }
grep -q '跳过端口 2230：已登记给其它设备' "$TMP_HOME/p32/out" || { printf '③ 没有用 config 台账保护别设备的端口\n' >&2; sed 's/^/  /' "$TMP_HOME/p32/out" >&2; exit 1; }

# --- device-uninstall：把 install.sh 留下的东西拆干净 ---
# 卸载的语义是「装了什么就删什么」：更新走的是另一条路（只换本地命令、不碰配置），
# 所以卸载只需要对「install.sh 到底写了哪些东西」负责 —— 漏一件就是永久残留。
#
# 桩件把「设备」和「服务器」分到两个 HOME（$h 与 $h-server）：
# 真机上它们是两台机器，共用一个 HOME 会把两边的断言搅在一起。
UBIN="$TMP_HOME/ubin"
mkdir -p "$UBIN"
cat > "$UBIN/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
for _last; do :; done
# 'sh -s' 的远端脚本在「服务器 HOME」下真的执行：档案、提示块、密钥都会落盘
case "$_last" in
    'sh -s -- '*)
        # 真 ssh 会把 `sh -s -- a b` 的参数送进远端脚本的 $1/$2；桩件也得照做，
        # 否则脚本拿到的 $1 是空的 —— 它会「什么都没删却报完成」。
        # 别用 ${*#...}：bash 对 ${*#pat} 是按位置参数逐个处理的，不是整串前缀。
        _rest=$(printf '%s' "$_last" | sed 's/^sh -s -- //' | tr -d "'")
        exec env HOME="$FAKE_SERVER_HOME" sh -s -- $_rest ;;
    *'sh -s'*) exec env HOME="$FAKE_SERVER_HOME" sh ;;
esac
case "$*" in *DEVICE-ONBOARD-E2E-OK*) printf 'DEVICE-ONBOARD-E2E-OK'; exit 0 ;; esac
case "$*" in *反向隧道已建立*) printf '✅ 反向隧道已建立\n'; exec sleep 30 ;; esac
case "$*" in *-R*localhost*) exec sleep 30 ;; esac
case "$*" in *'for c in codex claude'*) printf 'codex claude'; exit 0 ;; esac
# 其余「落到服务器上」的命令（生成回连密钥、写 authorized_keys、写 ssh config）：
# 远端要跑的那一串就是最后一个参数 —— 在服务器 HOME 下跑一遍，断言才有真文件可查。
case "$_last" in
    *ssh-keygen*|*authorized_keys*|*key.pub*|*'.ssh/config'*|*SKILL.md*|*AGENTS.md*|*CLAUDE.md*)
        exec env HOME="$FAKE_SERVER_HOME" sh -c "$_last" ;;
esac
exit 0
EOF
chmod 755 "$UBIN/ssh"

# install_into <设备 HOME> [设备名] [服务器 HOME] [反向端口上界]
# 服务器 HOME 默认是 <设备 HOME>-server；两台设备共用一台服务器时显式传同一个。
install_into() {
    _h=$1; _name=${2:-xiaomitest}; _s=${3:-"$1-server"}; _pend=${4:-2230}
    mkdir -p "$_h/.ssh" "$_s/.ssh"
    # 块外预置一条用户手写的 Host keepme：卸载不该碰它
    printf 'Host keepme\n    HostName example.com\n' > "$_h/.ssh/config"
    printf '1\n%s\n134.175.91.169\nubuntu\n22\n' "$_name" | \
        env FAKE_SSH_LOG="$_h/ssh.log" FAKE_SERVER_HOME="$_s" TERMUX_VERSION=0.118 PATH="$UBIN:$PATH" HOME="$_h" \
        DEVICE_ONBOARD_REVERSE_PORT_START=2230 DEVICE_ONBOARD_REVERSE_PORT_END="$_pend" \
        DEVICE_ONBOARD_CONFIG_DIR="$_h/cfg" DEVICE_ONBOARD_KEY_DIR="$_h/keys" DEVICE_ONBOARD_BIN_DIR="$_h/bin" \
        sh "$ROOT/install.sh" > "$_h/out" 2>&1
}

# uninstall_from <设备 HOME> <服务器 HOME> [device-uninstall 参数…]
uninstall_from() {
    _h=$1; _s=$2
    shift 2
    env FAKE_SSH_LOG="$_h/ssh.log" FAKE_SERVER_HOME="$_s" PATH="$UBIN:$PATH" HOME="$_h" \
        DEVICE_ONBOARD_CONFIG_DIR="$_h/cfg" DEVICE_ONBOARD_KEY_DIR="$_h/keys" \
        sh "$ROOT/bin/device-uninstall" "$@" > "$_h/un.out" 2>&1
}

assert_gone() {
    if [ -e "$1" ]; then printf '卸载后还在：%s（%s）\n' "$1" "$2" >&2; exit 1; fi
}

# ① 全拆：两边都不该留东西，用户手写的 Host keepme 必须还在
U1="$TMP_HOME/u1"
install_into "$U1" || { printf '卸载用例的前置安装失败：\n' >&2; sed 's/^/  /' "$U1/out" >&2; exit 1; }
[ -f "$U1/cfg/config" ] && [ -f "$U1/keys/xiaomitest-device" ] && [ -x "$U1/bin/device-uninstall" ] || {
    printf '安装没有产出预期的文件，卸载用例不成立\n' >&2
    exit 1
}
grep -q 'device-onboard:xiaomitest' "$U1/.ssh/authorized_keys" || { printf '前置安装没写本地 authorized_keys\n' >&2; exit 1; }
[ -f "$U1-server/.codex/skills/device-onboard/SKILL.md" ] || { printf '前置安装没在服务器侧写设备档案\n' >&2; exit 1; }
grep -q 'Host onboard-device-xiaomitest' "$U1-server/.ssh/config" || { printf '前置安装没在服务器侧写回连 Host\n' >&2; exit 1; }

uninstall_from "$U1" "$U1-server" || {
    printf 'device-uninstall 失败：\n' >&2
    sed 's/^/  /' "$U1/un.out" >&2
    exit 1
}
grep -q '拆除完成' "$U1/un.out" || { printf '卸载没有完成提示：\n' >&2; sed 's/^/  /' "$U1/un.out" >&2; exit 1; }

# 设备侧
assert_gone "$U1/cfg/config" '状态文件'
assert_gone "$U1/keys/xiaomitest-device" '设备密钥'
assert_gone "$U1/bin/device-tunnel" '本地命令'
assert_gone "$U1/bin/device-harness" '本地命令'
assert_gone "$U1/bin/device-uninstall" '本地命令（它自己）'
assert_gone "$U1/.ssh/config.device-onboard.bak" '我们留的配置备份'
if grep -q 'device-onboard' "$U1/.ssh/config"; then
    printf '卸载后设备侧 ~/.ssh/config 里还有本工具的区块：\n' >&2
    sed 's/^/  /' "$U1/.ssh/config" >&2
    exit 1
fi
grep -qx 'Host keepme' "$U1/.ssh/config" || { printf '卸载动了用户手写的 Host keepme\n' >&2; exit 1; }
if grep -q 'device-onboard:xiaomitest' "$U1/.ssh/authorized_keys" 2>/dev/null; then
    printf '卸载后设备侧 authorized_keys 还有回连公钥的行\n' >&2
    exit 1
fi

# 服务器侧
assert_gone "$U1-server/.codex/skills/device-onboard/SKILL.md" '设备档案'
assert_gone "$U1-server/.claude/skills/device-onboard/SKILL.md" '设备档案（claude 那份）'
assert_gone "$U1-server/.codex/AGENTS.md" '记忆文件（原来只有本工具的块）'
assert_gone "$U1-server/.claude/CLAUDE.md" '记忆文件（原来只有本工具的块）'
assert_gone "$U1-server/.ssh/device-onboard/xiaomitest-server" '服务器侧回连密钥'
if grep -q 'device-onboard' "$U1-server/.ssh/config" 2>/dev/null; then
    printf '卸载后服务器侧 ~/.ssh/config 里还有回连区块：\n' >&2
    sed 's/^/  /' "$U1-server/.ssh/config" >&2
    exit 1
fi
if grep -q 'device-onboard:xiaomitest' "$U1-server/.ssh/authorized_keys" 2>/dev/null; then
    printf '卸载后服务器侧 authorized_keys 还有本设备的公钥\n' >&2
    exit 1
fi

# ② --keep-keys：密钥与双方的授权行留着（否则每次更新都要重新过一次密码）
U2="$TMP_HOME/u2"
install_into "$U2" || { printf '--keep-keys 用例的前置安装失败：\n' >&2; sed 's/^/  /' "$U2/out" >&2; exit 1; }
key_before=$(cksum "$U2/keys/xiaomitest-device" | awk '{print $1}')
uninstall_from "$U2" "$U2-server" --keep-keys || {
    printf 'device-uninstall --keep-keys 失败：\n' >&2
    sed 's/^/  /' "$U2/un.out" >&2
    exit 1
}
[ -f "$U2/keys/xiaomitest-device" ] || { printf -- '--keep-keys 却把设备密钥删了\n' >&2; exit 1; }
[ "$(cksum "$U2/keys/xiaomitest-device" | awk '{print $1}')" = "$key_before" ] || {
    printf -- '--keep-keys 改动了设备密钥（下次更新就要重新过密码）\n' >&2
    exit 1
}
grep -q 'device-onboard:xiaomitest' "$U2/.ssh/authorized_keys" || { printf -- '--keep-keys 却删了设备侧授权行\n' >&2; exit 1; }
[ -f "$U2-server/.ssh/device-onboard/xiaomitest-server" ] || { printf -- '--keep-keys 却删了服务器侧回连密钥\n' >&2; exit 1; }
grep -q 'device-onboard:xiaomitest' "$U2-server/.ssh/authorized_keys" || { printf -- '--keep-keys 却删了服务器侧授权行\n' >&2; exit 1; }
# 派生产物照样得拆掉
assert_gone "$U2/cfg/config" '状态文件'
assert_gone "$U2/bin/device-harness" '本地命令'
if grep -q 'device-onboard' "$U2/.ssh/config"; then
    printf -- '--keep-keys 也没有清掉设备侧 config 里的区块\n' >&2
    exit 1
fi

# ③ 重跑 install.sh = 只更新本地命令、跳过接入，绝不碰 ~/.ssh/config
U3="$TMP_HOME/u3"
install_into "$U3" || { printf '重跑用例的前置安装失败：\n' >&2; sed 's/^/  /' "$U3/out" >&2; exit 1; }
cp "$U3/.ssh/config" "$U3/config.before"
key_before=$(cksum "$U3/keys/xiaomitest-device" | awk '{print $1}')
: > "$U3/ssh.log"
env FAKE_SSH_LOG="$U3/ssh.log" FAKE_SERVER_HOME="$U3-server" TERMUX_VERSION=0.118 PATH="$UBIN:$PATH" HOME="$U3" \
    DEVICE_ONBOARD_CONFIG_DIR="$U3/cfg" DEVICE_ONBOARD_KEY_DIR="$U3/keys" DEVICE_ONBOARD_BIN_DIR="$U3/bin" \
    sh "$ROOT/install.sh" </dev/null > "$U3/out2" 2>&1 || {
    printf '重跑 install.sh 失败：\n' >&2
    sed 's/^/  /' "$U3/out2" >&2
    exit 1
}
grep -q '本地命令已更新' "$U3/out2" || { printf '重跑没有走「只更新命令」那条路：\n' >&2; sed 's/^/  /' "$U3/out2" >&2; exit 1; }
grep -q '跳过首次接入' "$U3/out2" || { printf '重跑又进了一次接入向导\n' >&2; exit 1; }
diff -q "$U3/config.before" "$U3/.ssh/config" >/dev/null || {
    printf '重跑动了 ~/.ssh/config（这条路径刻意不碰它，要重写块用 --repair）\n' >&2
    exit 1
}
[ "$(cksum "$U3/keys/xiaomitest-device" | awk '{print $1}')" = "$key_before" ] || {
    printf '重跑把设备密钥重造了\n' >&2
    exit 1
}
if grep -q 'DEVICE-ONBOARD-E2E-OK' "$U3/ssh.log"; then
    printf '重跑又跑了一遍端到端握手（那是接入才做的事）\n' >&2
    exit 1
fi

# ④ --repair：别名规则变了，只重写双方的标记块，不重新接入、不动密钥
R1="$TMP_HOME/r1"
mkdir -p "$R1/.ssh" "$R1/cfg" "$R1/keys" "$R1-server/.ssh"
cat > "$R1/.ssh/config" <<'EOF'
Host keepme
    HostName example.com

# >>> device-onboard:xiaomitest BEGIN
Host onboard-server-xiaomitest
    HostName 134.175.91.169
    User ubuntu
    Port 22
    IdentityFile /old/path/xiaomitest-device

Host onboard-tunnel-xiaomitest
    HostName 134.175.91.169
    RemoteForward 2230 localhost:8022
    ExitOnForwardFailure yes
# <<< device-onboard:xiaomitest END
EOF
: > "$R1/keys/xiaomitest-device"
cat > "$R1/cfg/config" <<EOF
DEVICE_ID=xiaomitest
DEVICE_NAME=xiaomitest
DEVICE_USER=mac
SERVER_HOST=134.175.91.169
SERVER_USER=ubuntu
SERVER_PORT=22
DEVICE_PORT=8022
REVERSE_PORT=2230
SERVER_HOST_ALIAS=onboard-server-xiaomitest
TUNNEL_HOST_ALIAS=onboard-tunnel-xiaomitest
DEVICE_HOST_ALIAS=onboard-device-xiaomitest
DEVICE_KEY=$R1/keys/xiaomitest-device
EOF
FAKE_SERVER_HOME="$R1-server" PATH="$UBIN:$PATH" HOME="$R1" \
    DEVICE_ONBOARD_CONFIG_DIR="$R1/cfg" DEVICE_ONBOARD_KEY_DIR="$R1/keys" DEVICE_ONBOARD_BIN_DIR="$R1/bin" \
    sh "$ROOT/install.sh" --repair > "$R1/out" 2>&1 || {
    printf -- '--repair 失败：\n' >&2
    sed 's/^/  /' "$R1/out" >&2
    exit 1
}
grep -qx 'Host server' "$R1/.ssh/config" || {
    printf -- '--repair 没把服务器别名换成 server：\n' >&2
    sed 's/^/  /' "$R1/.ssh/config" >&2
    exit 1
}
if grep -q 'onboard-tunnel\|onboard-server-xiaomitest\|RemoteForward' "$R1/.ssh/config"; then
    printf -- '--repair 没清掉上一版的别名：\n' >&2
    sed 's/^/  /' "$R1/.ssh/config" >&2
    exit 1
fi
grep -qx 'Host keepme' "$R1/.ssh/config" || { printf -- '--repair 动了块外的手写内容\n' >&2; exit 1; }
rcount=$(grep -c '^# >>> device-onboard:xiaomitest BEGIN$' "$R1/.ssh/config" || true)
[ "$rcount" = 1 ] || { printf -- '--repair 后标记块有 %s 个（应该是 1 个）\n' "$rcount" >&2; exit 1; }
grep -q 'Host onboard-device-xiaomitest' "$R1-server/.ssh/config" || {
    printf -- '--repair 没重写服务器侧的回连 Host：\n' >&2
    sed 's/^/  /' "$R1-server/.ssh/config" 2>/dev/null >&2
    exit 1
}
grep -qx 'SERVER_HOST_ALIAS=server' "$R1/cfg/config" || { printf -- '--repair 没同步状态文件里的别名\n' >&2; exit 1; }
if grep -q 'TUNNEL_HOST_ALIAS' "$R1/cfg/config"; then
    printf -- '--repair 没清掉状态文件里的 TUNNEL_HOST_ALIAS\n' >&2
    exit 1
fi
# 没有状态文件时 --repair 要明确报错，而不是跑进向导
if PATH="$UBIN:$PATH" HOME="$TMP_HOME" \
        DEVICE_ONBOARD_CONFIG_DIR="$TMP_HOME/nostate" DEVICE_ONBOARD_KEY_DIR="$TMP_HOME/nokeys" \
        DEVICE_ONBOARD_BIN_DIR="$TMP_HOME/nobin" \
        sh "$ROOT/install.sh" --repair </dev/null >/tmp/device-onboard-smoke.out 2>&1; then
    printf '没有接入配置时 --repair 竟然成功了\n' >&2
    exit 1
fi
grep -q -- '--repair 需要已有接入配置' /tmp/device-onboard-smoke.out

# ④ 状态文件没了也要能把本地残留清掉，并明说服务器侧得人工收拾
U4="$TMP_HOME/u4"
install_into "$U4" || { printf '缺状态文件用例的前置安装失败：\n' >&2; sed 's/^/  /' "$U4/out" >&2; exit 1; }
rm -f "$U4/cfg/config"
uninstall_from "$U4" "$U4-server" || {
    printf '没有状态文件时卸载失败了：\n' >&2
    sed 's/^/  /' "$U4/un.out" >&2
    exit 1
}
grep -q '状态文件不在了' "$U4/un.out" || { printf '没说明状态文件不在：\n' >&2; sed 's/^/  /' "$U4/un.out" >&2; exit 1; }
grep -q '服务器侧没有凭据信息' "$U4/un.out" || { printf '没提醒服务器侧要人工收拾\n' >&2; exit 1; }
if grep -q 'device-onboard' "$U4/.ssh/config"; then
    printf '状态文件缺失时没能清掉设备侧区块：\n' >&2
    sed 's/^/  /' "$U4/.ssh/config" >&2
    exit 1
fi
grep -qx 'Host keepme' "$U4/.ssh/config" || { printf '兜底清理顺手删了用户的 Host keepme\n' >&2; exit 1; }

# ⑤ 一台服务器上登记了两台设备：卸掉一台只去它自己的档案块
# 记忆文件里的「设备会话」块不分设备 —— 卸载照删，但必须提醒「另一台会少这条提示」。
T1="$TMP_HOME/t1"; T2="$TMP_HOME/t2"; TS="$TMP_HOME/tsrv"
mkdir -p "$TS/.ssh"
install_into "$T1" devicea "$TS" 2231 || { printf '两台设备用例：第一台安装失败：\n' >&2; sed 's/^/  /' "$T1/out" >&2; exit 1; }
install_into "$T2" deviceb "$TS" 2231 || { printf '两台设备用例：第二台安装失败：\n' >&2; sed 's/^/  /' "$T2/out" >&2; exit 1; }
SKF="$TS/.codex/skills/device-onboard/SKILL.md"
grep -q 'DEVICE-ONBOARD:devicea' "$SKF" || { printf '两台设备没都登记进档案\n' >&2; exit 1; }
grep -q 'DEVICE-ONBOARD:deviceb' "$SKF" || { printf '两台设备没都登记进档案\n' >&2; exit 1; }
[ -f "$TS/.codex/AGENTS.md" ] || { printf '安装没写记忆文件\n' >&2; exit 1; }

uninstall_from "$T1" "$TS" || { printf '两台设备用例：卸载第一台失败：\n' >&2; sed 's/^/  /' "$T1/un.out" >&2; exit 1; }
if grep -q 'DEVICE-ONBOARD:devicea' "$SKF"; then
    printf '卸载没去掉本设备的档案块\n' >&2
    exit 1
fi
grep -q 'DEVICE-ONBOARD:deviceb' "$SKF" || { printf '卸载把另一台设备的档案块也删了：\n' >&2; sed 's/^/  /' "$SKF" >&2; exit 1; }
# 记忆文件里的块不分设备：卸载语义是「装了什么就删什么」，所以它也会被删 ——
# 但必须说清楚「另一台设备的会话会因此少这条提示」，别让人事后才发现。
if grep -q 'DEVICE-ONBOARD-AGENTS BEGIN' "$TS/.codex/AGENTS.md" 2>/dev/null; then
    printf '卸载没有清掉记忆文件里的提示块（卸载语义是全部删掉）\n' >&2
    exit 1
fi
grep -q '记忆文件的提示块是共用的' "$T1/un.out" || {
    printf '删了共用提示块却没提醒（另一台设备的会话会少这条提示）：\n' >&2
    sed 's/^/  /' "$T1/un.out" >&2
    exit 1
}

# 最后一台也卸掉 → 档案目录也该消失
uninstall_from "$T2" "$TS" || { printf '两台设备用例：卸载第二台失败：\n' >&2; sed 's/^/  /' "$T2/un.out" >&2; exit 1; }
assert_gone "$SKF" '设备档案（最后一台卸掉后）'

# ⑥ 老状态文件里没有 BIN_DIR：从 PATH 上找，但只认 $HOME 底下的、且确实是我们的脚本
U5="$TMP_HOME/u5"
install_into "$U5" || { printf '缺 BIN_DIR 用例的前置安装失败：\n' >&2; sed 's/^/  /' "$U5/out" >&2; exit 1; }
# 模拟「老版本装的状态文件」，并放一个同名但无关的命令，它不该被删
grep -v '^BIN_DIR=' "$U5/cfg/config" > "$U5/cfg/config.tmp" && mv "$U5/cfg/config.tmp" "$U5/cfg/config"
printf '#!/bin/sh\necho not-ours\n' > "$U5/bin/device-harness-x"
mkdir -p "$U5/otherbin" && printf '#!/bin/sh\necho 别人的工具\n' > "$U5/otherbin/device-harness" && chmod 755 "$U5/otherbin/device-harness"
env FAKE_SSH_LOG="$U5/ssh.log" FAKE_SERVER_HOME="$U5-server" PATH="$U5/bin:$U5/otherbin:$UBIN:$PATH" HOME="$U5" \
    DEVICE_ONBOARD_CONFIG_DIR="$U5/cfg" DEVICE_ONBOARD_KEY_DIR="$U5/keys" \
    sh "$ROOT/bin/device-uninstall" > "$U5/un.out" 2>&1 || {
    printf '缺 BIN_DIR 时卸载失败：\n' >&2
    sed 's/^/  /' "$U5/un.out" >&2
    exit 1
}
assert_gone "$U5/bin/device-harness" '本地命令（从 PATH 上找到的）'
[ -f "$U5/otherbin/device-harness" ] || {
    printf '把同名但无关的命令也删了（它不属于本工具）\n' >&2
    exit 1
}

# 未知参数要明确拒绝，别默默当普通安装跑

# --- 变量引用与多字节字符的边界 ---
# macOS 的 /bin/sh 是 bash 3.2：具名变量引用后面紧跟一个汉字时，它会把那个多字节
# 字符的前几字节吃进变量名 —— set -u 下报 unbound variable（真机踩过：install.sh
# 的回滚路径整段中断、只回滚了一半），不报时静默输出乱码。位置参数（$1）与特殊
# 参数（$?）不受影响，但具名变量一律写成 ${name}。
for _f in "$ROOT/install.sh" "$ROOT/bin/device-harness" "$ROOT/bin/device-tunnel" "$ROOT/bin/device-uninstall" "$ROOT/tests/smoke.sh"; do
    if LC_ALL=C grep -q '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$_f" 2>/dev/null; then
        printf '%s 里有「变量引用紧邻非 ASCII 字符」的写法（macOS bash 3.2 会解析错）：\n' "$_f" >&2
        LC_ALL=C grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$_f" | sed 's/^/  /' >&2
        exit 1
    fi
done

printf 'smoke tests passed\n'