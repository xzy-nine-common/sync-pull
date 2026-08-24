#!/usr/bin/env bash
set -o pipefail

REPO_MAP_FILE="$1"

if [[ -z "${MY_GITEE_PAT}" ]]; then
  echo "FATAL: MY_GITEE_PAT not set"
  exit 1
fi

if [[ ! -f "${REPO_MAP_FILE}" ]]; then
  echo "FATAL: repo map file not found: ${REPO_MAP_FILE}"
  exit 1
fi

# 从文件读取映射表
declare -A REPO_MAP
while IFS=' ' read -r key value; do
  REPO_MAP["$key"]="$value"
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "${REPO_MAP_FILE}")

TMP_WORK="/tmp/sync_$(date +%s%N | cut -c1-13)"
mkdir -p "${TMP_WORK}"
echo 0 > "${TMP_WORK}/job_count"

# 获取gitee组织仓库列表
curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" "${GITEE_API}/orgs/${GITEE_ORG}/repos?per_page=100" > "${TMP_WORK}/gitee_repos.json"

# 并行校验每个仓库commit是否一致
while read -r repo_obj; do
  repo_name=$(echo "$repo_obj" | jq -r ".name")
  gitee_default_branch=$(echo "$repo_obj" | jq -r ".default_branch")
  upstream_git="${REPO_MAP[$repo_name]-}"

  if [[ -z "$upstream_git" ]]; then
    echo "[SKIP] no upstream mapping: ${repo_name}"
    echo "SKIP" > "${TMP_WORK}/${repo_name}.result"
    continue
  fi

  owner_repo=$(echo "$upstream_git" | sed -E 's#^https://github.com/(.*)\.git$#\1#')
  if [[ -z "$owner_repo" ]]; then
    echo "[ERROR] parse upstream failed: ${repo_name}"
    echo "ERROR" > "${TMP_WORK}/${repo_name}.result"
    continue
  fi

  (
    gitee_hash=$(curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" "${GITEE_API}/repos/${GITEE_ORG}/${repo_name}/branches/${gitee_default_branch}" | jq -r ".commit.sha")
    gh_def_branch=$(curl -s "${GITHUB_API}/repos/${owner_repo}" | jq -r ".default_branch")
    github_hash=$(curl -s "${GITHUB_API}/repos/${owner_repo}/branches/${gh_def_branch}" | jq -r ".commit.sha")

    if [[ "${github_hash}" == "null" || -z "${github_hash}" || "${gitee_hash}" == "null" || -z "${gitee_hash}" ]]; then
      echo "SKIP" > "${TMP_WORK}/${repo_name}.result"
    elif [[ "${github_hash}" == "${gitee_hash}" ]]; then
      echo "OK" > "${TMP_WORK}/${repo_name}.result"
    else
      echo "NEED_SYNC" > "${TMP_WORK}/${repo_name}.result"
    fi
  ) &

  cur=$(cat "${TMP_WORK}/job_count")
  cur=$((cur + 1))
  echo "$cur" > "${TMP_WORK}/job_count"
  if (( cur >= PARALLEL_JOBS )); then
    wait -n 2>/dev/null || wait
    cur=$(cat "${TMP_WORK}/job_count")
    cur=$((cur - 1))
    echo "$cur" > "${TMP_WORK}/job_count"
  fi
done < <(jq -c ".[]" "${TMP_WORK}/gitee_repos.json")
wait

# 收集校验结果
SYNC_REPOS=()
OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SYNC_OK=0
SYNC_FAIL=0
for result_file in "${TMP_WORK}"/*.result; do
  [[ -f "$result_file" ]] || continue
  repo_name=$(basename "$result_file" .result)
  status=$(cat "$result_file")
  case "$status" in
    OK)
      echo "[OK] ${repo_name} already up-to-date"
      OK_COUNT=$((OK_COUNT + 1))
      ;;
    NEED_SYNC)
      echo "[SYNC] ${repo_name} needs mirror"
      SYNC_REPOS+=("$repo_name")
      ;;
    SKIP)
      SKIP_COUNT=$((SKIP_COUNT +1))
      ;;
    *)
      echo "[ERROR] ${repo_name} check failed"
      FAIL_COUNT=$((FAIL_COUNT +1))
      ;;
  esac
done
echo "Check stat: ok=${OK_COUNT} need_sync=${#SYNC_REPOS[@]} skip=${SKIP_COUNT} fail=${FAIL_COUNT}"

# 推送到gitee
push_to_gitee(){
  local repo_name="$1"
  local mirror_dir="$2"
  cd "${mirror_dir}" || return 1
  git remote add gitee "https://${GITEE_USER}:${MY_GITEE_PAT}@gitee.com/${GITEE_ORG}/${repo_name}.git"
  local push_output
  push_output=$(git push --mirror gitee 2>&1) || true
  local real_errors
  real_errors=$(echo "$push_output" | grep -v "refs/pull/" | grep -iE "error|fatal|failed" || true)
  echo "$push_output" | grep -v "refs/pull/"
  git remote remove gitee
  cd - >/dev/null || return 1
  if [[ -n "$real_errors" ]]; then
    echo "[PUSH ERROR] $real_errors"
    return 1
  fi
  return 0
}

# 执行同步
if [[ ${#SYNC_REPOS[@]} -eq 0 ]]; then
  echo "All repos are up-to-date, nothing to sync."
else
  echo "Start syncing ${#SYNC_REPOS[@]} repos..."
  for repo_name in "${SYNC_REPOS[@]}"; do
    upstream_git="${REPO_MAP[$repo_name]}"
    echo "----------------------------------------"
    echo "Processing ${repo_name}"
    MIRROR_DIR="${TMP_WORK}/mirror_${repo_name}"
    rm -rf "${MIRROR_DIR}"
    echo "  [1/2] clone ${upstream_git}"
    if git clone --mirror "${upstream_git}" "${MIRROR_DIR}" 2>/dev/null; then
      echo "  [OK] clone success"
      if push_to_gitee "${repo_name}" "${MIRROR_DIR}"; then
        echo "[SUCCESS] ${repo_name} synced"
        SYNC_OK=$((SYNC_OK+1))
      else
        echo "[FAILED] ${repo_name} push error"
        SYNC_FAIL=$((SYNC_FAIL+1))
      fi
    else
      echo "  [FAIL] clone failed"
      echo "[FAILED] ${repo_name} clone error"
      SYNC_FAIL=$((SYNC_FAIL+1))
    fi
    rm -rf "${MIRROR_DIR}"
  done
  echo "Sync result: ok=${SYNC_OK} fail=${SYNC_FAIL}"
fi

rm -rf "${TMP_WORK}"

# GitHub Actions Summary
{
  echo "## 🔄 镜像同步报告"
  echo ""
  echo "| 指标 | 数量 |"
  echo "|------|------|"
  echo "| ✅ 已是最新 | ${OK_COUNT} |"
  echo "| 🔄 已同步 | ${SYNC_OK} |"
  echo "| ⏭️ 跳过 | ${SKIP_COUNT} |"
  echo "| ❌ 失败 | $((FAIL_COUNT + SYNC_FAIL)) |"
  echo ""
  if [[ ${#SYNC_REPOS[@]} -gt 0 ]]; then
    echo "### 已同步仓库"
    echo ""
    for repo in "${SYNC_REPOS[@]}"; do
      echo "- \`${repo}\`"
    done
  fi
} >> "$GITHUB_STEP_SUMMARY"
echo "Job finished."
