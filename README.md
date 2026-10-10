# Gitee 镜像同步

把 GitHub 上游仓库镜像到 Gitee。镜像按命名空间组织，映射表放在 `repos/<命名空间>/`。

## 命名空间

映射表所在目录名即 Gitee 命名空间：

- `repos/xzy-ime/` → 组织 `xzy-ime`
- `repos/xzy_nine/` → 个人空间 `xzy_nine`

## 映射表

`repos/<命名空间>/repo-map.json`，键为 Gitee 仓库名，值为 GitHub 上游地址：

```json
{
  "fcitx5": "https://github.com/fcitx/fcitx5.git",
  "libime": "https://github.com/fcitx/libime.git"
}
```

## 判定口径

两侧默认分支 HEAD SHA 相同即已同步。

## 构成

| 路径 | 作用 |
|---|---|
| `repos/*/repo-map.json` | 仓库映射表 |
| `check.sh` | 比对 gitee 与 GitHub 默认分支 SHA，输出需同步清单 |
| `sync.sh` | clone --mirror 上游并推送 gitee |
| `retry-push.sh` | 推送封装：单次超时 + 自动重试 |
| `.github/workflows/gitee-check.yml` | 每日比对，有差异时调用同步工作流 |
| `.github/workflows/gitee-sync.yml` | 执行 clone + push，也可手动触发 |

## 加仓库 / 加命名空间

往对应映射表加一行 `仓库名: GitHub 上游地址`；新增命名空间建 `repos/<命名空间>/repo-map.json`，无需改工作流。

运行、排查与开发命令见 [AGENTS.md](AGENTS.md)。