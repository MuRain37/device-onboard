# device-onboard 运行流程

这份文档讲清三件事：**首次接入装了什么**、**日常两条命令各自干了什么**、**出错时怎么退**。
内容对应分支 `termux-port` 的实际代码（`install.sh`、`bin/device-tunnel`、`bin/device-harness`）。

---

## 0. 三个角色

| 角色 | 是什么 | 例子 |
|---|---|---|
| **设备** | 你想"从它出发干活"的那台机器 | 手机（Termux）、Mac |
| **服务器** | 常开、算力大、真正跑 harness 的那台 | 腾讯云 Ubuntu |
| **harness** | 服务器上真正干活的东西，默认 codex | codex |

方向约定：

- **正控**：设备 → 服务器（`ssh onboard-server-<设备名>`）
- **反控**：服务器 → 设备（靠设备先开一条反向隧道，再用 `ssh onboard-device-<设备名>`）

设备是**主动方**：所有连接都由设备发起。服务器不需要能直接访问设备。

---

## 1. 总览

```mermaid
flowchart LR
    subgraph DEV["设备（手机 / Mac）"]
        I["install.sh<br/>① 首次接入（只跑一次）"]
        T["device-tunnel<br/>② 只开隧道"]
        H["device-harness<br/>③ 一键：隧道 + harness"]
    end

    subgraph SRV["服务器（Ubuntu）"]
        SSH["sshd"]
        ARCH["设备档案<br/>~/.codex/skills/device-onboard/SKILL.md"]
        MP["挂载点<br/>~/&lt;设备名&gt;"]
        RUN["harness（codex）<br/>工作目录可指向设备文件夹"]
        REPO["~/.ssh/config<br/>Host onboard-device-&lt;设备名&gt;"]
    end

    I -->|"生成密钥 / 交换公钥 / 写 config"| SSH
    I -->|"写档案"| ARCH
    I -->|"装 sshfs + 建挂载点 + 试挂验证"| MP
    I -->|"写回连 Host 块"| REPO

    T -->|"反向隧道<br/>服务器 127.0.0.1:&lt;REVERSE_PORT&gt; → 设备 localhost:&lt;DEVICE_PORT&gt;"| SSH
    H --> T
    H -->|"ssh -t 启动"| RUN
    RUN -.->|"读档案了解这台设备"| ARCH
    RUN -->|"工作目录"| MP
    MP -.->|"sshfs 走隧道"| SSH
```

---

## 2. 首次接入：`install.sh`（在设备上跑）

```mermaid
sequenceDiagram
    participant U as 你
    participant D as 设备（install.sh）
    participant S as 服务器

    D->>D: detect_platform()<br/>Darwin → macos；Termux → termux
    U->>D: 输入服务器 IP / 用户名 / 端口
    D->>S: ssh 登录（密码由你手输，脚本不存密码）
    D->>D: 生成密钥对（本地）
    D->>S: 追加公钥到服务器 authorized_keys
    S->>D: 回传服务器的公钥
    D->>D: 写进设备 authorized_keys
    D->>D: 写设备侧 ~/.ssh/config<br/>Host onboard-server-&lt;设备名&gt;
    S->>S: 写服务器侧 ~/.ssh/config<br/>Host onboard-device-&lt;设备名&gt;（含 RemoteForward）
    D->>S: 建设备档案到 ~/.codex/skills/device-onboard/
    D->>S: 反向通道真握手验证
    Note over D,S: 让服务器在探测端口上主动连回设备一次<br/>必须回显 DEVICE-ONBOARD-E2E-OK 才算通
    D->>S: 配置服务器端 sshfs
    Note over D,S: 装 sshfs → 建 ~/&lt;设备名&gt; → 趁隧道还开着试挂一次<br/>验读写 → 立刻摘掉（装完隧道就关了）
    D->>U: 完成，打印用法
```

### 关键点

- **密码由你手输**，脚本不保存、不落盘。
- **端到端验证**：不是"绑上端口就算通"，而是让服务器**真连回来握一次手**——
  绑上但握手失败会立刻中止，并明确告诉你"换端口没用"。
- **sshfs 任何一步失败都不影响接入**，只打警告（服务器可能没有 apt、可能是 macOS）。
- **首次接入路径带失败回滚**：半路挂了会按标记撤销、还原备份。
- **"已有配置"重跑会走跳过路径**，那条路径**绝不改动** `~/.ssh/config`。

---

## 3. 日常之一：`device-tunnel`（在设备上跑）

只做一件事：**把服务器的某个端口，转发到设备的 sshd**。保持前台，Ctrl-C 结束。

```mermaid
flowchart TD
    A["启动 device-tunnel"] --> B{"有接入配置吗<br/>~/.config/device-onboard/config"}
    B -- 没有 --> B1["报错：请先跑 install.sh"]
    B -- 有 --> C{"是 Termux 吗"}
    C -- 是 --> C1["拿唤醒锁<br/>防止 Android 冻结 App"]
    C1 --> C2{"本机 sshd 在跑吗<br/>pgrep -x sshd"}
    C2 -- 没跑 --> C3["sshd 拉起来<br/>（隧道是往外连的，sshd 死了照样连得上<br/>·结果服务器端口成空壳·）"]
    C2 -- 在跑 --> D
    C3 --> D
    C -- 否 --> D["ssh 到服务器，带 -R 反向转发"]
    D --> E{"转发真的绑上了吗<br/>Host 块里 ExitOnForwardFailure yes"}
    E -- 否 --> E1["ssh 退出，退出码非 0"]
    E -- 是 --> F["服务器打印「反向隧道已建立」<br/>这就是就绪信号"]
    F --> G["挂住不退出，直到 Ctrl-C"]
```

> **为什么就绪信号必须由服务器说？** 因为只有服务器的 `sshd` 真把端口绑上了，
> 才可能执行到那行打印。本地瞎报"已建立"没有意义。

---

## 4. 日常之二：`device-harness`（一键，在设备上跑）

```
device-harness [--no-map] [-C <服务器上的目录>] [harness 命令] [命令参数...]
```

它是**编排层**：把隧道和 harness 的生命期绑在一起，干完自动收拾。

```mermaid
flowchart TD
    A["启动 device-harness"] --> B["读配置，校验<br/>DEVICE_ID / 别名 / 端口"]
    B --> C["解析选项<br/>-C 与 --no-map 可任意顺序"]
    C --> D{"要起什么 harness<br/>默认 codex"}
    D -->|codex*| D1["自动补 --no-daemon<br/>理由见 §8"]
    C --> E["后台起 device-tunnel<br/>输出重定向到日志文件"]
    E --> F{"日志里出现<br/>「隧道已建立」了吗<br/>轮询等待"}
    F -- 超时 --> F1["打印隧道最后几行输出<br/>退出（隧道一并收起）"]
    F -- 出现 --> G["确保服务器上 ~/&lt;设备名&gt; 是活的 sshfs 挂载"]
    G --> H["决定工作目录（见 §5）"]
    H --> I["ssh -t 服务器<br/>DEVICE_ONBOARD_ID=… codex --no-daemon -C …"]
    I --> J["你退出 harness"]
    J --> K["EXIT trap 收掉隧道<br/>（挂载刻意不摘，留给下次）"]
```

### 挂载这一段的内部流程

```mermaid
flowchart TD
    M0["SSH 到服务器执行挂载脚本"] --> M1{"mountpoint 说挂着吗"}
    M1 -- 挂着 --> M2{"timeout 3 ls 读得动吗"}
    M2 -- 读得动 --> M3["MOUNT_ALREADY：已就绪"]
    M2 -- 读不动（僵死挂载）--> M4["fusermount -u → -uz → 按 PID 收 sshfs 进程"]
    M1 -- 没挂 --> M5["sshfs onboard-device-&lt;设备名&gt;: ~/&lt;设备名&gt;"]
    M4 --> M5
    M5 --> M6{"mountpoint 真负面<br/>且 ls 通"}
    M6 -- 是 --> M7["MOUNT_OK：已挂好"]
    M6 -- 否 --> M8["MOUNT_FAIL + 打印 sshfs 的真实报错"]
```

> **踩过的坑**：判定"挂载成功"**不能**用 `ls` —— 空目录 `ls` 也会成功，
> 会把"挂载失败"误报成"已挂好"，接着 harness 在空挂载点上 chdir，直接
> `Error: No such file or directory (os error 2)`。

---

## 5. 工作目录是怎么定的（优先级从高到低）

| 情况 | 工作目录 | 说明 |
|---|---|---|
| 显式 `-C <目录>` | 用它 | 只做 `~` → `$HOME` 的转换，交给服务器展开 |
| `--no-map` | 服务器家目录 | 明确"不要跟随本机目录" |
| 默认，且 `$PWD` 在设备家目录下 | 服务器 `~/<设备名>/<相对路径>` | 自动映射 |
| 默认，但 `$PWD` 不在设备家目录下 | 服务器家目录 + 提示 | 比如手机上的 `/sdcard/...` |
| 挂载不可用，而目录是**自动映射**来的 | 服务器家目录 + 警告 | 见 §6 |
| 挂载不可用，但目录是**你用 `-C` 点的** | 保持不动 + 警告 | 不擅自改你指定的东西 |

```mermaid
flowchart LR
    P["设备上的 $PWD"] --> Q{"在设备家目录 $HOME 下吗"}
    Q -- 是 --> R["映射：<br/>$HOME/x/y → 服务器 ~/&lt;设备名&gt;/x/y"]
    Q -- 否 --> S["服务器家目录 + 提示原因"]
    R --> T["交给服务器上的 codex -C"]
    S --> T
```

**为什么是"映射"而不是"拷贝"**：服务器上的 `~/<设备名>` 就是设备的家目录
（sshfs 挂载），同一份文件系统。在服务器上改文件，等于直接在设备上改。

---

## 6. 挂载这件事：为什么要它，什么时候会坏

- **为什么要**：让服务器上的 codex 直接**在设备的文件夹里干活**——读写的是同一份文件，
  不用同步、不用拷贝。
- **依赖**：sshfs 连接走的是**反向隧道**。所以：

```
隧道在 → 挂载活着
隧道断 → 挂载变僵死（挂载表里还在，读就 EIO）
```

- **僵死挂载怎么处理**：`device-harness` 每次启动都会用 `timeout 3 ls` 探一下，
  探不动就先摘（`fusermount -u` → `-uz` → 按 PID 收 sshfs 进程）再重挂。
- **退出时不摘挂载**：留着下次直接用；下次要是坏了，上面那套会自己修。
- **开关**：`DEVICE_ONBOARD_NO_MOUNT=1` 跳过整套挂载逻辑。

---

## 7. 出错时的三层退路

```mermaid
flowchart TD
    E1["第 1 层：工作目录回退<br/>挂载不可用 → 自动映射的目录退回服务器家目录"] --> E2["第 2 层：报错不再被吞<br/>sshfs 的真实报错直接打给你看"]
    E2 --> E3["第 3 层：隧道自检<br/>起隧道前确认设备 sshd 在跑，避免空壳隧道"]
```

对应用户能看到的：

- 挂载失败 → `警告：服务器 sshfs 挂载不可用，工作目录已退回服务器家目录（~）。`
  —— harness **照常启动**，你不会被卡住。
- 挂载失败 → `警告：服务器 sshfs 挂载失败：<sshfs 的原话>`
  —— 一眼就知道是网络、认证还是别的。
- 起隧道时设备 sshd 没跑 → `本机 sshd 没在跑，先拉起来…`

---

## 8. 两个"看起来多余"的设计，其实都是踩出来的

**① 为什么 codex 要带 `--no-daemon`**

交互式 Codex 把"执行工具命令"交给一个常驻的 `app-server` 守护进程，
那个进程继承的是**它启动那一刻**的环境。于是 `DEVICE_ONBOARD_ID` 这类
本次会话才有的变量，传不到 Codex 的工具手上（实测：工具 shell 里的
`SSH_CLIENT` 与两天前那个守护进程逐字一致）。`--no-daemon` 让工具在**本次会话
进程**里执行，环境变量才有效。

**② 为什么就绪信号要由服务器打印**

本地"我发出去了"毫无意义——`ExitOnForwardFailure yes` 保证只有**服务器真的绑上端口**
才会执行到那行打印。这是唯一能区分"隧道通了"和"端口被占/没绑上"的证据。

---

## 9. 服务器侧看到什么

- **设备档案**：`~/.codex/skills/device-onboard/SKILL.md`
  —— 一个 skill 记所有设备，每台一个块；还有一个放在所有设备块之外的
  **共享约定块**，说明"本次会话来自哪台设备"以环境变量形式传进来
  （`DEVICE_ONBOARD_ID`、`DEVICE_ONBOARD_DEVICE_ALIAS`）。
- **回连入口**：`~/.ssh/config` 里的 `Host onboard-device-<设备名>`
  （`127.0.0.1:<REVERSE_PORT>`）。
- **挂载点**：`~/<设备名>`。
- 于是服务器上的 harness 可以：读档案知道自己在谁的会话里、用
  `ssh onboard-device-<设备名> '<命令>'` 直接操作设备、在 `~/<设备名>` 里读写设备文件。

---

## 附：命令速查

| 想做什么 | 在哪跑 | 命令 |
|---|---|---|
| 首次接入 | 设备 | `sh install.sh` |
| 只开隧道 | 设备 | `device-tunnel` |
| 一键干活（跟随当前目录） | 设备 | `device-harness` |
| 一键干活（服务器家目录） | 设备 | `device-harness --no-map` |
| 一键干活（指定服务器目录） | 设备 | `device-harness -C '~/xiaomi/项目'` |
| 进服务器 | 设备 | `ssh onboard-server-<设备名>` |
| 从服务器操作设备 | 服务器 | `ssh onboard-device-<设备名> '<命令>'` |
| 工作目录直接在设备上 | 服务器 | `codex -C ~/<设备名>` |
