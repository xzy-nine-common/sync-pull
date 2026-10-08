#!/usr/bin/env bash
# 镜像同步: 把指定仓库(或全部映射仓库)镜像推送到 gitee
#
# 用法: sync.sh [命名空间/仓库名 ...]
#       省略参数时同步 ${REPO_ROOT}/*/repo-map.json 里的全部仓库
#       例: sync.sh xzy_nine/deepseek-harness
#           sync.sh fcitx5 libime          # 裸名在所有映射表里唯一时可省略命名空间
#
# Gitee 命名空间由映射表所在目录名决定:
#   repos/xzy-ime/repo-map.json   -> xzy-ime
#   repos/xzy_nine/repo-map.json  -> xzy_nine
#
# 依赖环境变量: GITEE_USER GITEE_API MY_GITEE_PAT
# 可选环境变量: REPO_ROOT(默认 repos)
#               PUSH_RETRY_MAX(默认3) PUSH_RETRY_DELAY(默认30) PUSH_TIMEOUT_SEC(默认2700)
#
# 说明: 本脚本不做 SHA 比对(比对在 check.sh 里), 收到谁就同步谁。
#       推送交给 retry-push.sh, 带单次超时与自动重试。
set -o pipefail

REPO_ROOT="${REPO_ROOT:-repos}"

PUSH_RETRY_MAX="${PUSH_RETRY_MAX:-3}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-30}"
PUSH_TIMEOUT_SEC="${PUSH_TIMEOUT_SEC:-2700}"

if [[ -z "${MY_GITEE_PAT}" ]]; then
  echo "FATAL: MY_GITEE_PAT not set"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 读取全部映射表: "命名空间/仓库名" -> GitHub 上游地址 ----------
shopt -s nullglob
MAP_FILES=("${REPO_ROOT}"/*/repo-map.json)
shopt -u nullglob

if (( ${#MAP_FILES[@]} == 0 )); then
  echo "FATAL: 未找到任何映射表 (${REPO_ROOT}/*/repo-map.json)"
  exit 1
fi

declare -A REPO_MAP
for map_file in "${MAP_FILES[@]}"; do
  pf_ns="$(basename "$(dirname "${map_file}")")"
  while IFS=' ' read -r key value || [[ -n "${key}" ]]; do
    [[ -n "${key}" ]] || continue
    REPO_MAP["${pf_ns}/${key}"]="${value}"
  done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "${map_file}")
done

if (( ${#REPO_MAP[@]} == 0 )); then
  echo "FATAL: 映射表为空或解析失败: ${MAP_FILES[*]}"
  exit 1
fi

# ---------- 解析本次要同步的目标 ----------
# 返回 0 并打印 "命名空间/仓库名"; 返回 1 表示不存在, 返回 2 表示裸名有歧义
resolve_target() {
  local t="$1" key found=""

  if [[ "${t}" == */* ]]; then
    if [[ -n "${REPO_MAP[${t}]:-}" ]]; then
      echo "${t}"
      return 0
    fi
    return 1
  fi

  for key in "${!REPO_MAP[@]}"; do
    if [[ "${key##*/}" == "${t}" ]]; then
      [[ -n "${found}" ]] && return 2
      found="${key}"
    fi
  done

  [[ -n "${found}" ]] || return 1
  echo "${found}"
  return 0
}

SYNC_TARGETS=()
if (( $# > 0 )); then
  for raw in "$@"; do
    raw="$(echo "${raw}" | tr -d '[:space:]')"
    [[ -n "${raw}" ]] || continue

    resolved="$(resolve_target "${raw}")"
    resolve_rc=$?
    if (( resolve_rc == 0 )); then
      SYNC_TARGETS+=("${resolved}")
    elif (( resolve_rc == 2 )); then
      echo "FATAL: 仓库名有歧义, 请带上命名空间: ${raw}"
      exit 1
    else
      # 映射表里没有的目标交给下面统一记为 SKIP, 不中断
      SYNC_TARGETS+=("${raw}")
    fi
  done
  echo "本次指定同步 ${#SYNC_TARGETS[@]} 个仓库"
else
  mapfile -t SYNC_TARGETS < <(printf '%s\n' "${!REPO_MAP[@]}" | sort)
  echo "未指定仓库, 同步全部 ${#SYNC_TARGETS[@]} 个映射仓库"
fi

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

echo "推送重试: 最多 ${PUSH_RETRY_MAX} 次, 单次超时 ${PUSH_TIMEOUT_SEC}s"

SYNC_OK=0
SYNC_FAIL=0
SYNC_SKIP=0
OK_REPOS=()
FAILED_REPOS=()

for gitee_key in "${SYNC_TARGETS[@]}"; do
  [[ -n "${gitee_key}" ]] || continue
  gitee_ns="${gitee_key%%/*}"
  repo_name="${gitee_key#*/}"

  upstream_git="${REPO_MAP[${gitee_key}]-}"
  if [[ -z "${upstream_git}" ]]; then
    echo "----------------------------------------"
    echo "[SKIP] ${gitee_key} 无上游映射, 跳过"
    SYNC_SKIP=$(( SYNC_SKIP + 1 ))
    continue
  fi

  echo "----------------------------------------"
  echo "Processing ${gitee_key} <- ${upstream_git}"

  MIRROR_DIR="${TMP_WORK}/mirror_${gitee_ns}_${repo_name}"
  rm -rf "${MIRROR_DIR}"

  echo "  [1/2] clone --mirror"
  clone_out=$(git clone --mirror "${upstream_git}" "${MIRROR_DIR}" 2>&1)
  clone_rc=$?
  printf '%s\n' "${clone_out}" | grep -v '^Cloning into' || true
  if (( clone_rc != 0 )) || [[ ! -d "${MIRROR_DIR}" ]]; then
    echo "  [FAIL] clone failed (rc=${clone_rc})"
    echo "[FAILED] ${gitee_key} clone error"
    SYNC_FAIL=$(( SYNC_FAIL + 1 ))
    FAILED_REPOS+=("${gitee_key}")
    continue
  fi
  echo "  [OK] clone success"

  echo "  [2/2] push --mirror -> gitee/${gitee_key}"
  if bash "${SCRIPT_DIR}/retry-push.sh" "${gitee_ns}" "${repo_name}" "${MIRROR_DIR}"; then
    echo "[SUCCESS] ${gitee_key} synced"
    SYNC_OK=$(( SYNC_OK + 1 ))
    OK_REPOS+=("${gitee_key}")
  else
    echo "[FAILED] ${gitee_key} push error"
    SYNC_FAIL=$(( SYNC_FAIL + 1 ))
    FAILED_REPOS+=("${gitee_key}")
  fi

  rm -rf "${MIRROR_DIR}"
done

echo "----------------------------------------"
echo "Sync result: ok=${SYNC_OK} fail=${SYNC_FAIL} skip=${SYNC_SKIP}"

# GitHub Actions Summary
{
  echo "## 🔄 Gitee 镜像同步报告"
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
