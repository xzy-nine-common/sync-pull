#!/usr/bin/env bash
# 推送封装: 带超时 + 自动重试
# 用法: retry-push.sh <仓库名> <镜像目录>
# 依赖环境变量: GITEE_USER GITEE_ORG MY_GITEE_PAT
# 可选环境变量: PUSH_RETRY_MAX(默认3) PUSH_RETRY_DELAY(默认30) PUSH_TIMEOUT_SEC(默认2700)
#
# 注意: 本脚本刻意不使用 `cmd | grep -q` 这种写法。
#       在 `set -o pipefail` 下, grep -q 命中首个匹配后立即退出,
#       上游的 echo 会收到 SIGPIPE 并以非 0 退出, pipefail 会把整条管道判为失败,
#       从而把"推送成功"误判成"推送失败"(历史 bug, 曾导致 fcitx5 连续误报失败)。
#       这里统一用 here-string (<<<) 或变量匹配, 彻底避免 SIGPIPE。

set -o pipefail

REPO_NAME="$1"
MIRROR_DIR="$2"

PUSH_RETRY_MAX="${PUSH_RETRY_MAX:-3}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-30}"
PUSH_TIMEOUT_SEC="${PUSH_TIMEOUT_SEC:-2700}"

if [[ -z "${REPO_NAME}" || -z "${MIRROR_DIR}" ]]; then
  echo "[PUSH ERROR] usage: retry-push.sh <repo_name> <mirror_dir>"
  exit 1
fi

# gitee 会拒绝 refs/pull/*, git 因此返回非 0 并打印
# "error: failed to push some refs"; 只要分支/标签推送成功就算成功。
# 真正的致命错误(认证/网络/超时)才判失败。
is_fatal_error() {
  local out="$1"
  local re='fatal:|authentication failed|Authentication failed|could not read Username|Permission denied|access denied|unable to access|Could not resolve host|Connection (reset|refused|timed out)|Operation timed out|The remote end hung up'
  if [[ "${out}" =~ ${re} ]]; then
    return 0
  fi
  return 1
}

# 是否至少推送成功了一个引用
has_pushed_ref() {
  local out="$1"
  # 形如 "   abc123..def456  master -> master" 或 " * [new branch] x -> x"
  if [[ "${out}" =~ -\>[[:space:]] ]]; then
    return 0
  fi
  return 1
}

# 单次推送, 返回 0 表示成功
push_once() {
  local repo_name="$1"
  local mirror_dir="$2"
  local out rc

  cd "${mirror_dir}" || return 1

  git remote remove gitee >/dev/null 2>&1 || true
  git remote add gitee "https://${GITEE_USER}:${MY_GITEE_PAT}@gitee.com/${GITEE_ORG}/${repo_name}.git"

  local timeout_cmd=()
  if command -v timeout >/dev/null 2>&1 && [[ -n "${PUSH_TIMEOUT_SEC}" ]]; then
    timeout_cmd=(timeout "${PUSH_TIMEOUT_SEC}")
  fi

  out=$("${timeout_cmd[@]}" git push --mirror gitee 2>&1)
  rc=$?

  git remote remove gitee >/dev/null 2>&1 || true
  cd - >/dev/null 2>&1 || true

  # 打印输出, 但过滤掉 gitee 拒绝 refs/pull/* 的正常噪声
  printf '%s\n' "${out}" | grep -v "refs/pull/" || true

  # 超时被杀 (timeout 返回 124) 属于失败
  if (( rc == 124 )); then
    echo "[PUSH ERROR] ${repo_name} 推送超时 (${PUSH_TIMEOUT_SEC}s)"
    return 1
  fi

  if is_fatal_error "${out}"; then
    echo "[PUSH ERROR] ${repo_name} 推送出现致命错误"
    return 1
  fi

  if has_pushed_ref "${out}"; then
    return 0
  fi

  # 全量镜像已是最新时 git 输出 "Everything up-to-date", 属正常成功
  if [[ "${out}" == *"Everything up-to-date"* ]]; then
    return 0
  fi

  echo "[PUSH ERROR] ${repo_name} 没有任何引用被推送 (rc=${rc})"
  return 1
}

attempt=1
while (( attempt <= PUSH_RETRY_MAX )); do
  echo "[PUSH] ${REPO_NAME} 第 ${attempt}/${PUSH_RETRY_MAX} 次尝试"
  if push_once "${REPO_NAME}" "${MIRROR_DIR}"; then
    if (( attempt > 1 )); then
      echo "[RETRY OK] ${REPO_NAME} 第 ${attempt} 次尝试成功"
    fi
    exit 0
  fi

  if (( attempt < PUSH_RETRY_MAX )); then
    delay=$(( PUSH_RETRY_DELAY * attempt ))
    echo "[RETRY] ${REPO_NAME} 推送失败, ${delay}s 后重试 (${attempt}/${PUSH_RETRY_MAX})"
    sleep "${delay}"
  fi
  attempt=$(( attempt + 1 ))
done

echo "[FAILED] ${REPO_NAME} 重试 ${PUSH_RETRY_MAX} 次后仍然失败"
exit 1
