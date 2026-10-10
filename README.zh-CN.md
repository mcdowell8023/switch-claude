# switch-claude

[English](README.md)

在一台机器上保存多个 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 账号，一条命令切换，不用每次重新登录。

```console
$ switch-claude
Mode: oauth
Active slot: work
Login on record: me@work.example

Slots:
* work       oauth  me@work.example                  ✓ access valid for 6.2h
  personal   oauth  me@home.example                  access expired; refresh CLAIMS 610.0h left (UNVERIFIED)
  ci         token  -                                token stored

$ switch-claude personal
✓ Switched to personal (me@home.example)
```

只有一个 bash 脚本，支持 macOS（Keychain）和 Linux（凭据文件）。

## 为什么需要它

Claude Code 同一时间只保存一个登录，换账号就得 `/logout` 再 `/login`，每次都要走一遍浏览器授权。直接复制凭据文件也不行：每次刷新都会**轮换** refresh token，旧的随即作废，昨天拷的那份通常已经用不了。

switch-claude 给每个账号一个插槽（slot）。每次切走之前，先把轮换后的新凭据存回它自己的插槽。如果当前登录不在任何插槽里，它拒绝覆盖，能用的账号不会被误丢。

## 功能

- **oauth 插槽**：普通 `/login` 得到的凭据（access + refresh token），切换时写到 Claude Code 读取凭据的位置。
- **token 插槽**：`claude setup-token` 签发的长期 token，通过环境变量 `CLAUDE_CODE_OAUTH_TOKEN` 生效，适合服务器和 CI。
- **不丢登录**：每次切换前把轮换后的凭据写回插槽；仍然有效、又不在任何插槽里的登录，一律不覆盖。
- `status --probe` 给每个插槽发一个极小的真实请求，显示 HTTP 状态和 API 返回的 5 小时 / 7 天用量，某个账号撞额度时可以看该切到哪个。
- 增加、改名、删除、重新登录插槽都用命令完成，不用改代码，也不用手改 JSON。
- `backup` / `restore`，`remove` 前自动备份。
- 切换后可以跑一个 hook，比如重启会派生 Claude Code 的守护进程（[Paseo 示例](examples/hooks/paseo-restart.sh)）。

## 依赖

- bash 3.2 及以上（macOS 自带的 bash 就行）、`python3`、`awk`、`sed`
- `curl`（只有 `status --probe` 和切到 token 插槽时用到）
- macOS 用系统自带的 `security` 命令；Linux 不需要别的
- Claude Code 使用默认配置目录（不支持 `CLAUDE_CONFIG_DIR`）

## 安装

```bash
git clone https://github.com/mcdowell8023/switch-claude.git
mkdir -p ~/.local/bin
ln -s "$PWD/switch-claude/bin/switch-claude" ~/.local/bin/switch-claude   # 确认 ~/.local/bin 在 PATH 里
switch-claude help
```

## 快速上手

### 1. 保存当前登录的账号

```bash
switch-claude add work           # 记下当前登录的凭据、邮箱和账号 ID
```

### 2. 加第二个账号

先登记，再登录一次：

```bash
switch-claude add personal --email me@home.example
switch-claude login personal     # 当前登录存回它的插槽，然后退出登录
# 在 Claude Code 里 /login，用 me@home.example 登录
switch-claude save               # 把新登录存进 personal 插槽
```

没有浏览器的环境（比如 SSH 上去的服务器）用 `switch-claude login personal --no-browser`，它会运行 `claude auth login` 并打印一个链接，在别的设备上打开即可。

### 3. 切换

```bash
switch-claude work
switch-claude personal
```

新开的 Claude Code 会话用新账号。已经在跑的会话可能还拿着旧账号，想确保生效就重启它们。

## token 插槽

`claude setup-token` 会签发一个有效期约一年的 token。设置了环境变量 `CLAUDE_CODE_OAUTH_TOKEN` 时，Claude Code 用它，并且它的优先级高于 `/login` 的凭据。

```bash
claude setup-token                    # 复制它打印出来的 token
switch-claude add ci --token          # 在隐藏输入里粘贴（也可以用管道传进去）
switch-claude ci                      # 先探测一下，再写入 token 环境文件
```

脚本没法修改启动它的那个 shell 的环境变量，所以切到 token 插槽时，switch-claude 把 `CLAUDE_CODE_OAUTH_TOKEN=<token>` 写进一个**环境文件**（默认 `~/.config/switch-claude/token.env`），由 shell 和服务去读：

```bash
# ~/.zshenv 或 ~/.bashrc
f="${XDG_CONFIG_HOME:-$HOME/.config}/switch-claude/token.env"
[ -r "$f" ] && set -a && . "$f" && set +a
```

```ini
# 运行 Claude Code 的 systemd unit
EnvironmentFile=-%h/.config/switch-claude/token.env
```

切回 oauth 插槽时，文件里写的是 `CLAUDE_CODE_OAUTH_TOKEN=`（空值），Claude Code 把空值当作未设置。之后新开的 shell 都会回到 oauth 插槽，包括从 tmux 这类父进程继承了旧值的 shell。已经在跑的 shell 和服务不受影响，要新开 shell 或重启服务（见 `post_switch_hook`）。

如果你已经有这样一个环境文件，不必搬家，把 `token_env_file` 指向它就行。

当前 shell 里的 `CLAUDE_CODE_OAUTH_TOKEN` 和环境文件不一致时，`status` 会警告：从这个 shell 启动的任何东西都会被它压住，切 oauth 插槽对它们无效。

## 命令

| 命令 | 作用 |
|---|---|
| `switch-claude` / `status [--probe]` | 显示所有插槽、当前生效的插槽和警告。`--probe` 给每个插槽发一个真实请求。 |
| `switch-claude <名字> [--force]` | 切换。`--force` 允许装入已完全过期的 oauth 凭据，或跳过 token 探测。 |
| `list` | 只列名字、类型、邮箱。 |
| `add <名字>` | 把当前登录存成新的 oauth 插槽。 |
| `add <名字> --email <邮箱>` | 登记一个空的 oauth 插槽，之后再 `login`。 |
| `add <名字> --token [--email <备注>]` | 保存 `claude setup-token` 的 token，从隐藏输入或 stdin 读取。 |
| `rename <旧名> <新名>` | 改名。 |
| `remove <名字>` | 先备份，再删除。 |
| `login <名字> [--no-browser]` | 为插槽重新登录，最后用 `save` 收尾。 |
| `save` | 完成待定的登录；没有待定登录时，把当前（已轮换的）凭据存回它的插槽。 |
| `save <名字>` | 把当前登录存进指定插槽（邮箱必须对得上）。 |
| `sync` | 没有待定登录时等同于 `save`。 |
| `refresh <名字>` / `--all` | 用一次真实请求把过期的 access token 换新，完成后切回原来的登录。 |
| `cancel` | 放弃待定的登录。 |
| `backup` | 给所有插槽拍快照（明文；拒绝写进 git 工作区）。 |
| `restore <目录> [--apply] [名字 …]` | 从快照恢复插槽，不加 `--apply` 只预演。 |

## 工作原理

| | macOS | Linux |
|---|---|---|
| 当前 oauth 登录（Claude Code 读这里） | Keychain `Claude Code-credentials` / 当前用户名，同时镜像到 `~/.claude/.credentials.json` | `~/.claude/.credentials.json` |
| 插槽凭据 | Keychain，service 为 `switch-claude`，account 为插槽名 | `~/.config/switch-claude/creds/<名字>`（0600） |
| 插槽清单 | `~/.config/switch-claude/slots.conf` | 同左 |

`slots.conf` 一行一个插槽：`名字 类型 邮箱 uuid`。里面没有任何凭据，由命令自动维护。其他设置放在 `~/.config/switch-claude/config`（见 [`examples/config.example`](examples/config.example)）：`token_env_file`、`post_switch_hook`、`backup_dir`、`login_args`（比如 `--sso`）、`probe_model`。

**几条始终遵守的规则：**

1. 任何会替换当前登录的操作，都先把当前凭据存回它自己的插槽。Claude Code 刷新时只改当前登录，插槽里那份会随之作废。
2. 不在任何插槽里、而且仍然有效的登录，绝不覆盖；命令会停下，并告诉你怎么保存或丢弃。只存在于 token 环境文件里的 token 同样处理。
3. `save` 拒绝邮箱和插槽对不上的凭据，也拒绝和其他插槽逐字节相同的凭据。
4. access token 过期的 oauth 插槽照样可以切过去，第一次请求时会用 refresh token 换新。只有两个都过期了，才要求加 `--force`。

## 注意事项

- **一个插槽只在一台机器上用。** 两台机器共用同一账号时，一边刷新，另一边那份就作废了。第二台机器改用 token 插槽（`claude setup-token`）。
- `refreshTokenExpiresAt` 只是 token 自己声称的有效期。已经被轮换作废的 token 在本地看起来仍然有效，所以 `status` 标成「CLAIMS … UNVERIFIED」。用 `status --probe` 或者直接切过去，才能知道它是不是真的还能用。
- macOS 上写 Keychain 时，凭据作为参数传给 `security`，在那一瞬间**同一用户**的其他进程能从 `ps` 看到。`security` 读不了 stdin 传入的长值；而同一用户本来就能直接读取这条 Keychain 记录。
- 备份里是明文凭据，`backup_dir` 不要放进 git 仓库或同步文件夹。
- `status --probe` 和切到 token 插槽时，会向 `api.anthropic.com` 发一个真实请求（max_tokens 8）。
- 这是个人维护的独立工具，与 Anthropic 无关。它依赖 Claude Code 目前存放凭据的方式，这一点将来可能会变。

## 测试

```bash
bash test/switch-claude.test.sh              # 全部用例，每种平台各跑一遍
TEST_PLATFORMS=linux bash test/switch-claude.test.sh test_switch_
```

测试在一次性的临时 `HOME` 里运行，`security`、`claude`、`curl` 都是 mock，不会碰你的 Keychain、凭据，也不联网。

## 许可证

[MIT](LICENSE)
