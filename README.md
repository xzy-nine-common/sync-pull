# Gitee 镜像同步

Gitee 命名空间由映射表所在目录名决定：`repos/xzy-ime/` → 组织 `xzy-ime`，`repos/xzy_nine/` → 个人空间 `xzy_nine`。

## 查日志

```bash
# 最近运行
gh run list --repo xzy-nine-common/sync-pull --limit 20

# 某次运行的步骤摘要(不下载日志)
gh run view <run-id> --repo xzy-nine-common/sync-pull

# 全部日志
gh run view <run-id> --repo xzy-nine-common/sync-pull --log

# 只看失败步骤
gh run view <run-id> --repo xzy-nine-common/sync-pull --log-failed

# 从日志筛结论
gh run view <run-id> --repo xzy-nine-common/sync-pull --log \
  | grep -E 'Check stat|待同步仓库'
gh run view <run-id> --repo xzy-nine-common/sync-pull --log \
  | grep -E 'Sync result|\[SUCCESS\]|\[FAILED\]'

# 某次运行有哪些 job(出现「同步」即本次真的推过东西)
gh run view <run-id> --repo xzy-nine-common/sync-pull --json jobs \
  --jq '.jobs[] | [.name, .conclusion] | @tsv'

# 只看「同步」job 的日志
gh run view <run-id> --repo xzy-nine-common/sync-pull --job <job-id> --log

# 检查工作流的运行记录
gh run list --repo xzy-nine-common/sync-pull \
  --workflow gitee-check.yml --limit 20
```

## 触发运行

```bash
# 重跑失败的部分
gh run rerun <run-id> --repo xzy-nine-common/sync-pull --failed

# 手动触发同步(留空=全部仓库)
gh workflow run gitee-sync.yml --repo xzy-nine-common/sync-pull

# 手动触发同步指定仓库
gh workflow run gitee-sync.yml --repo xzy-nine-common/sync-pull \
  -f repos=xzy_nine/deepseek-harness,fcitx5
```

## 本地手动跑

```bash
export GITEE_USER=xzy_nine
export GITEE_API=https://gitee.com/api/v5
export GITHUB_API=https://api.github.com
export MY_GITEE_PAT=<你的 gitee 令牌>

bash check.sh                              # 检查 repos/*/repo-map.json 全部
bash check.sh repos/xzy_nine/repo-map.json # 只检查某个命名空间

bash sync.sh                                                  # 同步全部
bash sync.sh xzy_nine/deepseek-harness fcitx5                 # 只同步指定仓库
```

## 加一个仓库 / 一个命名空间

```bash
# 加到已有命名空间: 往对应映射表加一行  仓库名 -> GitHub 上游地址
# 新增命名空间: 建目录 repos/<命名空间>/repo-map.json, 无需改工作流
```
