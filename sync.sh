#!/usr/bin/env bash
# 镜像同步: 把指定仓库(或全部映射仓库)镜像推送到 gitee
# 用法: sync.sh <repo-map.json> [repo1,repo2,...]
#       省略仓库列表时同步映射表中的全部仓库
# 依赖环境变量: GITEE_USER GITEE_ORG MY_GITEE_PAT
# 可选环境变量: PUSH_RETRY_MAX(默认3) PUSH_RETRY_DELAY(默认30) PUSH_TIMEOUT_SEC(默认2700)
#
# 说明: 本脚本不做 SHA 比对(比对在 check.sh 里), 收到谁就同步谁。
#       推送交给 retry-push.sh, 带单次超时与自动重试。
set -o pipefail

REPO_MAP_FILE="$1"
REPO_LIST="$2"

PUSH_RETRY_MAX="${PUSH_RETRY_MAX:-3}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-30}"
PUSH_TIMEOUT_SEC="${PUSH_TIMEOUT_SEC:-2700}"

if [[ -z "${MY_GITEE_PAT}" ]]; then
  echo "FATAL: MY_GITEE_PAT not set"
  exit 1
fi

if [[ -z "${REPO_MAP_FILE}" || ! -f "${REPO_MAP_FILE}" ]]; then
  echo "FATAL: repo map file not found: ${REPO_MAP_FILE}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 读取映射表: gitee 仓库名 -> GitHub 上游地址
declare -A REPO_MAP
while IFS=' ' read -r key value || [[ -n "${key}" ]]; do
  [[ -n "${key}" ]] || continue
  REPO_MAP["${key}"]="${value}"
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "${REPO_MAP_FILE}")

if (( ${#REPO_MAP[@]} == 0 )); then
  echo "FATAL: 映射表为空或解析失败: ${REPO_MAP_FILE}"
  exit 1
fi

# 确定本次要同步的仓库
SYNC_REPOS=()
if [[ -n "${REPO_LIST}" ]]; then
  IFS=',' read -r -a SYNC_REPOS <<< "${REPO_LIST}"
  echo "本次指定同步 ${#SYNC_REPOS[@]} 个仓库 (来自 check 工作流)"
else
  mapfile -t SYNC_REPOS < <(printf '%s\n' "${!REPO_MAP[@]}" | sort)
  echo "未指定仓库, 同步全部 ${#SYNC_REPOS[@]} 个映射仓库"
fi

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

echo "推送重试: 最多 ${PUSH_RETRY_MAX} 次, 单次超时 ${PUSH_TIMEOUT_SEC}s"

SYNC_OK=0
SYNC_FAIL=0
SYNC_SKIP=0
OK_REPOS=()
FAILED_REPOS=()

for repo_name in "${SYNC_REPOS[@]}"; do
  # 去掉可能的空白
  repo_name="$(echo "${repo_name}" | tr -d '[:space:]')"
  [[ -n "${repo_name}" ]] || continue

  upstream_git="${REPO_MAP[${repo_name}]-}"
  if [[ -z "${upstream_git}" ]]; then
    echo "----------------------------------------"
    echo "[SKIP] ${repo_name} 无上游映射, 跳过"
    SYNC_SKIP=$(( SYNC_SKIP + 1 ))
    continue
  fi

  echo "----------------------------------------"
  echo "Processing ${repo_name} <- ${upstream_git}"

  MIRROR_DIR="${TMP_WORK}/mirror_${repo_name}"
  rm -rf "${MIRROR_DIR}"

  echo "  [1/2] clone --mirror"
  clone_out=$(git clone --mirror "${upstream_git}" "${MIRROR_DIR}" 2>&1)
  clone_rc=$?
  printf '%s\n' "${clone_out}" | grep -v '^Cloning into' || true
  if (( clone_rc != 0 )) || [[ ! -d "${MIRROR_DIR}" ]]; then
    echo "  [FAIL] clone failed (rc=${clone_rc})"
    echo "[FAILED] ${repo_name} clone error"
    SYNC_FAIL=$(( SYNC_FAIL + 1 ))
    FAILED_REPOS+=("${repo_name}")
    continue
  fi
  echo "  [OK] clone success"

  echo "  [2/2] push --mirror -> gitee/${GITEE_ORG}/${repo_name}"
  if bash "${SCRIPT_DIR}/retry-push.sh" "${repo_name}" "${MIRROR_DIR}"; then
    echo "[SUCCESS] ${repo_name} synced"
    SYNC_OK=$(( SYNC_OK + 1 ))
    OK_REPOS+=("${repo_name}")
  else
    echo "[FAILED] ${repo_name} push error"
    SYNC_FAIL=$(( SYNC_FAIL + 1 ))
    FAILED_REPOS+=("${repo_name}")
  fi

  rm -rf "${MIRROR_DIR}"
done

echo "----------------------------------------"
echo "Sync result: ok=${SYNC_OK} fail=${SYNC_FAIL} skip=${SYNC_SKIP}"

# GitHub Actions Summary
{
  echo "## 🔄 IME 镜像同步报告"
  echo ""
  echo "| 指标 | 数量 |"
  echo "|------|------|"
  echo "| ✅ 同步成功 | ${SYNC_OK} |"
  echo "| ❌ 同步失败 | ${SYNC_FAIL} |"
  echo "| ⏭️ 无上游映射 | ${SYNC_SKIP} |"
  echo ""
  if (( ${#OK_REPOS[@]} > 0 )); then
    echo "### ✅ 已同步"
    echo ""
    for repo in "${OK_REPOS[@]}"; do
      echo "- \`${repo}\`"
    done
    echo ""
  fi
  if (( ${#FAILED_REPOS[@]} > 0 )); then
    echo "### ❌ 同步失败"
    echo ""
    for repo in "${FAILED_REPOS[@]}"; do
      echo "- \`${repo}\`"
    done
    echo ""
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "Job finished."

# 有仓库同步失败 => 让 job 变红, 便于发现
if (( SYNC_FAIL > 0 )); then
  exit 1
fi
