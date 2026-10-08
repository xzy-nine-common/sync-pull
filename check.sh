#!/usr/bin/env bash
# 差异检查: 只比对 gitee 与 GitHub 默认分支的 SHA, 不做任何 clone/push
# 用法: check.sh <repo-map.json>
# 依赖环境变量: GITEE_USER GITEE_ORG GITEE_API GITHUB_API MY_GITEE_PAT
# 可选环境变量: PARALLEL_JOBS(默认 6)
#
# 判定结果:
#   OK        两边默认分支 SHA 相同
#   NEED_SYNC 两边不同, 或 gitee 上仓库/分支还不存在
#   SKIP      repo-map.json 中没有该 gitee 仓库的上游映射
#   UNKNOWN   GitHub 侧取不到 SHA(限流/网络/改名), 不能当作"已同步"
#
# 输出到 $GITHUB_OUTPUT: need_sync=<数量>  repos=<逗号分隔的待同步仓库名>
# 说明: 存在差异属正常情况, 本脚本 exit 0; 只有配置/鉴权/解析错误才 exit 1。
set -o pipefail

REPO_MAP_FILE="$1"
PARALLEL_JOBS="${PARALLEL_JOBS:-6}"

if [[ -z "${MY_GITEE_PAT}" ]]; then
  echo "FATAL: MY_GITEE_PAT not set"
  exit 1
fi

if [[ -z "${REPO_MAP_FILE}" || ! -f "${REPO_MAP_FILE}" ]]; then
  echo "FATAL: repo map file not found: ${REPO_MAP_FILE}"
  exit 1
fi

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
echo "映射表: ${#REPO_MAP[@]} 个仓库"

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

echo "获取 gitee 组织 ${GITEE_ORG} 的仓库列表..."
curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" \
  "${GITEE_API}/orgs/${GITEE_ORG}/repos?per_page=100" > "${TMP_WORK}/gitee_repos.json"

# 拿不到仓库列表时必须报错退出, 否则会"什么都没检查"却显示成功
if ! jq -e 'type == "array"' "${TMP_WORK}/gitee_repos.json" >/dev/null 2>&1; then
  echo "FATAL: 获取 gitee 仓库列表失败, 返回内容:"
  head -c 500 "${TMP_WORK}/gitee_repos.json"
  echo
  exit 1
fi

echo "gitee 仓库数: $(jq 'length' "${TMP_WORK}/gitee_repos.json")"

# 单个仓库的比对, 结果写入 <repo>.result
check_one() {
  local repo_name="$1"
  local default_branch="$2"
  local upstream_git="$3"
  local owner_repo gitee_hash gh_def_branch github_hash

  if [[ -z "${upstream_git}" ]]; then
    echo "SKIP" > "${TMP_WORK}/${repo_name}.result"
    return 0
  fi

  owner_repo=$(sed -E 's#^https://github\.com/(.+)\.git$#\1#' <<< "${upstream_git}")
  if [[ -z "${owner_repo}" || "${owner_repo}" == "${upstream_git}" ]]; then
    echo "[WARN] ${repo_name} 上游地址无法解析: ${upstream_git}"
    echo "ERROR" > "${TMP_WORK}/${repo_name}.result"
    return 0
  fi

  gitee_hash=$(curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" \
    "${GITEE_API}/repos/${GITEE_ORG}/${repo_name}/branches/${default_branch}" \
    | jq -r '.commit.sha // empty')

  gh_def_branch=$(curl -s "${GITHUB_API}/repos/${owner_repo}" | jq -r '.default_branch // empty')
  if [[ -n "${gh_def_branch}" ]]; then
    github_hash=$(curl -s "${GITHUB_API}/repos/${owner_repo}/branches/${gh_def_branch}" \
      | jq -r '.commit.sha // empty')
  else
    github_hash=""
  fi

  if [[ -z "${github_hash}" ]]; then
    # 取不到上游 SHA 时不能判成"已同步", 单列为 UNKNOWN 留待下次
    echo "UNKNOWN" > "${TMP_WORK}/${repo_name}.result"
  elif [[ -z "${gitee_hash}" ]]; then
    # gitee 上仓库或分支不存在 => 必须推送
    echo "NEED_SYNC" > "${TMP_WORK}/${repo_name}.result"
  elif [[ "${github_hash}" == "${gitee_hash}" ]]; then
    echo "OK" > "${TMP_WORK}/${repo_name}.result"
  else
    echo "NEED_SYNC" > "${TMP_WORK}/${repo_name}.result"
  fi
  return 0
}

# 并行比对, 最多同时 PARALLEL_JOBS 个
running=0
while IFS=$'\t' read -r repo_name default_branch || [[ -n "${repo_name}" ]]; do
  [[ -n "${repo_name}" ]] || continue
  check_one "${repo_name}" "${default_branch}" "${REPO_MAP[${repo_name}]-}" &
  running=$(( running + 1 ))
  if (( running >= PARALLEL_JOBS )); then
    wait -n 2>/dev/null || true
    running=$(( running - 1 ))
  fi
done < <(jq -r '.[] | [.name, (.default_branch // "master")] | @tsv' "${TMP_WORK}/gitee_repos.json")
wait

# 汇总结果
SYNC_REPOS=()
OK_COUNT=0
SKIP_COUNT=0
UNKNOWN_COUNT=0
FAIL_COUNT=0

for result_file in "${TMP_WORK}"/*.result; do
  [[ -f "${result_file}" ]] || continue
  repo_name=$(basename "${result_file}" .result)
  case "$(cat "${result_file}")" in
    OK)
      echo "[OK] ${repo_name} 已是最新"
      OK_COUNT=$(( OK_COUNT + 1 ))
      ;;
    NEED_SYNC)
      echo "[SYNC] ${repo_name} 需要同步"
      SYNC_REPOS+=("${repo_name}")
      ;;
    SKIP)
      echo "[SKIP] ${repo_name} 无上游映射"
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
      ;;
    UNKNOWN)
      echo "[UNKNOWN] ${repo_name} 无法取得上游 SHA(限流/网络)"
      UNKNOWN_COUNT=$(( UNKNOWN_COUNT + 1 ))
      ;;
    *)
      echo "[ERROR] ${repo_name} 校验失败"
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      ;;
  esac
done

if (( ${#SYNC_REPOS[@]} > 1 )); then
  mapfile -t SYNC_REPOS < <(printf '%s\n' "${SYNC_REPOS[@]}" | sort)
fi
NEED_COUNT=${#SYNC_REPOS[@]}

echo "Check stat: ok=${OK_COUNT} need_sync=${NEED_COUNT} skip=${SKIP_COUNT} unknown=${UNKNOWN_COUNT} fail=${FAIL_COUNT}"

REPOS_CSV=""
if (( NEED_COUNT > 0 )); then
  REPOS_CSV=$(IFS=,; echo "${SYNC_REPOS[*]}")
  echo "待同步仓库: ${REPOS_CSV}"
else
  echo "所有仓库均已是最新。"
fi

# 传给工作流, 用于触发同步
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "need_sync=${NEED_COUNT}"
    echo "repos=${REPOS_CSV}"
  } >> "${GITHUB_OUTPUT}"
fi

# GitHub Actions Summary
{
  echo "## 🔍 IME 镜像差异检查"
  echo ""
  echo "| 指标 | 数量 |"
  echo "|------|------|"
  echo "| ✅ 已是最新 | ${OK_COUNT} |"
  echo "| 🔄 需要同步 | ${NEED_COUNT} |"
  echo "| ⏭️ 无上游映射 | ${SKIP_COUNT} |"
  echo "| ❓ 无法校验 | ${UNKNOWN_COUNT} |"
  echo "| ❌ 校验失败 | ${FAIL_COUNT} |"
  echo ""
  if (( NEED_COUNT > 0 )); then
    echo "### 🔄 待同步仓库"
    echo ""
    echo "已触发「IME镜像-同步」工作流。"
    echo ""
    for repo in "${SYNC_REPOS[@]}"; do
      echo "- \`${repo}\`"
    done
    echo ""
  else
    echo "全部仓库均已是最新, 本次未触发同步工作流。"
    echo ""
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "Check finished."

# 校验本身出错 => 让 job 变红, 避免"静默什么都没做"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
