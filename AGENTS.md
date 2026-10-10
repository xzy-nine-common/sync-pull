# AGENTS.md

本项目的运行、排查与开发命令。项目介绍见 [README.md](README.md)。

## 查同步工作流运行情况（首选）

```bash
# 最近的同步运行
gh run list --repo xzy-nine-common/sync-pull --workflow gitee-sync.yml --limit 10

# 最近的全部运行(含每日检查)
gh run list --repo xzy-nine-common/sync-pull --limit 10

# 某次运行: 状态 + 各 job 结论
gh run view <run-id> --repo xzy-nine-common/sync-pull --json status,conclusion,jobs \
  --jq '.jobs[] | [.name, .conclusion] | @tsv'

# 只看失败步骤
gh run view <run-id> --repo xzy-nine-common/sync-pull --log-failed

# 从日志筛结论
gh run view <run-id> --repo xzy-nine-common/sync-pull --log \
  | grep -E 'Processing |Sync result|\[SUCCESS\]|\[FAILED\]|\[PUSH\]|\[RETRY'
```

判读：

- `gitee-sync.yml` 的 job 名为「同步」，`conclusion=success` 表示本次指定仓库全部推送成功
- 汇总行 `Sync result: ok=<成功> fail=<失败> skip=<无上游映射>`，`fail>0` 时 job 变红
- `[SUCCESS] <命名空间>/<仓库> synced` 单仓库成功；`[FAILED] <命名空间>/<仓库> push error|clone error` 单仓库失败
- `[PUSH] ... 第 n/3 次尝试`、`[RETRY] ...`、`[RETRY OK] ...` 为推送重试过程
- `gitee-check.yml` 的 job 名为「差异检查」「触发同步」，无差异时「触发同步」为 skipped
- 结论行 `Check stat: ok=.. need_sync=.. skip=.. unknown=.. fail=..`

## 镜像差异比对

比两侧默认分支 HEAD，免令牌、免 jq。PowerShell（本机首选，并发 8）：

```powershell
$map = foreach ($mapFile in Get-ChildItem repos/*/repo-map.json) {
  $ns = $mapFile.Directory.Name
  (Get-Content $mapFile -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { [pscustomobject]@{ ns = $ns; name = $_.Name; up = $_.Value -replace '^https://github\.com/','' -replace '\.git$','' } }
}
$map | ForEach-Object -Parallel {
  $r = $_
  $g = ((git -c http.sslBackend=openssl ls-remote "https://gitee.com/$($r.ns)/$($r.name).git" HEAD 2>$null | Select-Object -First 1) -split '\s+')[0]
  $h = ((git -c http.sslBackend=openssl ls-remote "https://github.com/$($r.up).git" HEAD 2>$null | Select-Object -First 1) -split '\s+')[0]
  [pscustomobject]@{
    repo = "$($r.ns)/$($r.name)"; gitee = $g; github = $h
    status = if ($g -notmatch '^[0-9a-f]{40}$') { 'GITEE_MISSING' }
             elseif ($h -notmatch '^[0-9a-f]{40}$') { 'GH_ERROR' }
             elseif ($g -eq $h) { 'OK' } else { 'NEED_SYNC' }
  }
} -ThrottleLimit 8 | Sort-Object status, repo | ForEach-Object {
  '{0,-13} {1,-32} gitee={2} github={3}' -f $_.status, $_.repo,
    ($_.gitee -replace '^(.{8}).*','$1'), ($_.github -replace '^(.{8}).*','$1')
}
```

bash（需 bash + jq）：

```bash
for map in repos/*/repo-map.json; do
  ns=$(basename "$(dirname "$map")")
  jq -r --arg ns "$ns" 'to_entries[] | "\($ns)/\(.key) \(.value)"' "$map"
done | while read -r key upstream; do
  up=${upstream#https://github.com/}; up=${up%.git}
  g=$(git -c http.sslBackend=openssl ls-remote "https://gitee.com/$key.git" HEAD 2>/dev/null | cut -f1)
  h=$(git -c http.sslBackend=openssl ls-remote "https://github.com/$up.git" HEAD 2>/dev/null | cut -f1)
  if   [[ -z "$g" ]]; then s=GITEE_MISSING
  elif [[ -z "$h" ]]; then s=GH_ERROR
  elif [[ "$g" == "$h" ]]; then s=OK
  else s=NEED_SYNC; fi
  printf '%-13s %-32s gitee=%s github=%s\n' "$s" "$key" "${g:0:8}" "${h:0:8}"
done
```

状态取值：`OK` / `NEED_SYNC` / `GITEE_MISSING`（gitee 上仓库或默认分支不存在）/ `GH_ERROR`（GitHub 侧取不到）。

落后提交数：

```bash
gh api "repos/<owner>/<repo>/compare/<gitee_sha>...<github_sha>" --jq '{status,ahead_by}'
```

`ahead_by` 即镜像落后上游的提交数，`behind_by` 为 0 表示快进关系。

## 全量差异检查（Gitee API，需令牌）

```bash
export GITEE_USER=xzy_nine
export GITEE_API=https://gitee.com/api/v5
export GITHUB_API=https://api.github.com
export MY_GITEE_PAT=<gitee 令牌>

bash check.sh                              # repos/*/repo-map.json 全部
bash check.sh repos/xzy_nine/repo-map.json # 只检查某个命名空间
```

状态取值：

- `OK` 两侧默认分支 SHA 相同
- `NEED_SYNC` 两侧不同，或 gitee 上仓库/分支不存在
- `SKIP` gitee 上有该仓库，但映射表里没有它的上游
- `UNKNOWN` GitHub 侧取不到 SHA（限流/网络/改名），不计入 need_sync
- `ERROR` 上游地址无法解析

## 触发同步

```bash
# 手动: 指定仓库
gh workflow run gitee-sync.yml --repo xzy-nine-common/sync-pull \
  -f repos=xzy_nine/deepseek-harness,xzy-ime/fcitx5

# 手动: 全部映射仓库
gh workflow run gitee-sync.yml --repo xzy-nine-common/sync-pull

# 重跑失败的部分
gh run rerun <run-id> --repo xzy-nine-common/sync-pull --failed
```

- `gitee-check.yml` 每日比对，差异 > 0 时调用 `gitee-sync.yml`，无差异不调用
- `gitee-sync.yml` 单次超时 240 分钟
- 触发是异步的，用「查同步工作流运行情况」确认状态

## 本地手动跑

```bash
bash sync.sh                                   # 同步全部映射仓库
bash sync.sh xzy_nine/deepseek-harness fcitx5  # 只同步指定(裸名唯一时可省略命名空间)
bash retry-push.sh <命名空间> <仓库名> <镜像目录>
```

`sync.sh` 不做 SHA 比对，收到谁同步谁；推送交给 `retry-push.sh`。

## 环境变量

| 变量 | 用途 | 默认 |
|---|---|---|
| `GITEE_USER` | gitee 用户名 | 工作流里为 `xzy_nine` |
| `GITEE_API` | gitee API 地址 | `https://gitee.com/api/v5` |
| `GITHUB_API` | GitHub API 地址 | `https://api.github.com` |
| `MY_GITEE_PAT` | gitee 令牌，仓库 secrets 同名 | 无，缺失即 FATAL |
| `REPO_ROOT` | 映射表根目录 | `repos` |
| `PARALLEL_JOBS` | `check.sh` 并发数 | `6` |
| `PUSH_RETRY_MAX` | 推送重试次数 | `3` |
| `PUSH_RETRY_DELAY` | 重试退避基数(秒) | `30` |
| `PUSH_TIMEOUT_SEC` | 单次推送超时(秒) | `2700` |

`check.sh` 与 `sync.sh` 的 GitHub 侧请求为匿名调用（60 次/小时），仓库多时会撞限流。

## 本机 / 沙箱注意

- Windows 上 git 走 schannel 会报 `SEC_E_NO_CREDENTIALS`，命令加 `-c http.sslBackend=openssl`
- PATH 里没有 `bash` 与 `jq`，Git Bash 在 `C:\Program Files\Git\bin\bash.exe`，jq 需另装
- `gh run view --log` 需要可写缓存目录（默认 `%LocalAppData%\GitHub CLI` 在工作区外）：

```powershell
$env:LOCALAPPDATA = Join-Path $env:TEMP 'ghcache'
```