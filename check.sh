#!/usr/bin/env bash
# 差异检查: 只比对 gitee 与 GitHub 默认分支的 SHA, 不做任何 clone/push
#
# 用法: check.sh [repo-map.json ...]
#       省略参数时检查 ${REPO_ROOT}/*/repo-map.json
#
# Gitee 命名空间(组织或个人空间)由映射表所在目录名决定:
#   repos/xzy-ime/repo-map.json   -> 命名空间 xzy-ime  (组织)
#   repos/xzy_nine/repo-map.json  -> 命名空间 xzy_nine (个人空间)
#
# 依赖环境变量: GITEE_USER GITEE_API GITHUB_API MY_GITEE_PAT
# 可选环境变量: REPO_ROOT(默认 repos) PARALLEL_JOBS(默认 6)
#
# 判定结果:
#   OK        两边默认分支 SHA 相同
#   NEED_SYNC 两边不同, 或 gitee 上仓库/分支还不存在
#   SKIP      gitee 上有该仓库, 但映射表里没有它的上游
#   UNKNOWN   GitHub 侧取不到 SHA(限流/网络/改名), 不能当作"已同步"
#   ERROR     上游地址无法解析
#
# 输出到 $GITHUB_OUTPUT: need_sync=<数量>  repos=<逗号分隔的 命名空间/仓库名>
# 说明: 存在差异属正常情况, 本脚本 exit 0; 只有配置/鉴权/解析错误才 exit 1。
set -o pipefail

REPO_ROOT="${REPO_ROOT:-repos}"
PARALLEL_JOBS="${PARALLEL_JOBS:-6}"

if [[ -z "${MY_GITEE_PAT}" ]]; then
  echo "FATAL: MY_GITEE_PAT not set"
  exit 1
fi

# ---------- 收集映射表 ----------
if (( $# > 0 )); then
  MAP_FILES=("$@")
else
  shopt -s nullglob
  MAP_FILES=("${REPO_ROOT}"/*/repo-map.json)
  shopt -u nullglob
fi

if (( ${#MAP_FILES[@]} == 0 )); then
  echo "FATAL: 未找到任何映射表 (${REPO_ROOT}/*/repo-map.json)"
  exit 1
fi

declare -A REPO_MAP          # "命名空间/仓库名" -> GitHub 上游地址
declare -A NS_SEEN
NAMESPACES=()

for map_file in "${MAP_FILES[@]}"; do
  if [[ ! -f "${map_file}" ]]; then
    echo "FATAL: 映射表不存在: ${map_file}"
    exit 1
  fi
  ns="$(basename "$(dirname "${map_file}")")"
  if [[ -z "${NS_SEEN[${ns}]:-}" ]]; then
    NS_SEEN["${ns}"]=1
    NAMESPACES+=("${ns}")
  fi
  while IFS=' ' read -r key value || [[ -n "${key}" ]]; do
    [[ -n "${key}" ]] || continue
    REPO_MAP["${ns}/${key}"]="${value}"
  done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "${map_file}")
done

if (( ${#REPO_MAP[@]} == 0 )); then
  echo "FATAL: 映射表为空或解析失败: ${MAP_FILES[*]}"
  exit 1
fi

echo "映射表: ${#MAP_FILES[@]} 份, 共 ${#REPO_MAP[@]} 个仓库"
echo "命名空间: ${NAMESPACES[*]}"

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

# ---------- 取 gitee 仓库列表 ----------
# 组织走 /orgs, 个人空间走 /users。个人接口会连带返回自己所属组织的仓库,
# 所以统一按 full_name 的 "<命名空间>/" 前缀过滤。
fetch_gitee_repos() {
  local ns="$1" out="$2" tmp="$2.tmp"
  local url

  for url in "${GITEE_API}/orgs/${ns}/repos?per_page=100" \
             "${GITEE_API}/users/${ns}/repos?per_page=100"; do
    curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" "${url}" > "${tmp}"
    if jq -e 'type == "array"' "${tmp}" >/dev/null 2>&1 && (( $(jq 'length' "${tmp}") > 0 )); then
      mv "${tmp}" "${out}"
      return 0
    fi
  done

  cp "${tmp}" "${out}"
  return 1
}

# ---------- 组装候选集 ----------
# 候选 = gitee 上已存在的仓库 ∪ 映射表里的键。
# 只取 gitee 列表的话, 映射表里有、gitee 上还没建的仓库会被漏掉, 永远不会被创建。
declare -a CAND_KEYS=() CAND_BRANCH=()
declare -A CAND_SEEN

add_candidate() {
  local key="$1" branch="$2"
  [[ -n "${CAND_SEEN[${key}]:-}" ]] && return 0
  CAND_SEEN["${key}"]=1
  CAND_KEYS+=("${key}")
  CAND_BRANCH+=("${branch}")
}

for ns in "${NAMESPACES[@]}"; do
  listing="${TMP_WORK}/gitee_${ns}.json"
  if ! fetch_gitee_repos "${ns}" "${listing}"; then
    echo "FATAL: 获取 gitee 命名空间 ${ns} 的仓库列表失败, 返回内容:"
    head -c 500 "${listing}"
    echo
    exit 1
  fi
  echo "命名空间 ${ns}: gitee 仓库数 $(jq 'length' "${listing}")"

  while IFS=$'\t' read -r name branch || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    add_candidate "${ns}/${name}" "${branch}"
  done < <(jq -r --arg p "${ns}/" \
    '.[] | select(.full_name | startswith($p)) | [.name, (.default_branch // "")] | @tsv' "${listing}")
done

for key in "${!REPO_MAP[@]}"; do
  add_candidate "${key}" ""
done

# ---------- 单个仓库的比对 ----------
check_one() {
  local idx="$1" key="$2" fallback_branch="$3"
  local ns="${key%%/*}" name="${key#*/}"
  local upstream_git="${REPO_MAP[${key}]-}"
  local status owner_repo gh_def_branch github_hash gitee_hash branch

  if [[ -z "${upstream_git}" ]]; then
    status="SKIP"
  else
    owner_repo=$(sed -E 's#^https://github\.com/(.+)\.git$#\1#' <<< "${upstream_git}")
    if [[ -z "${owner_repo}" || "${owner_repo}" == "${upstream_git}" ]]; then
      echo "[WARN] ${key} 上游地址无法解析: ${upstream_git}"
      status="ERROR"
    else
      gh_def_branch=$(curl -s "${GITHUB_API}/repos/${owner_repo}" | jq -r '.default_branch // empty')
      github_hash=""
      if [[ -n "${gh_def_branch}" ]]; then
        github_hash=$(curl -s "${GITHUB_API}/repos/${owner_repo}/branches/${gh_def_branch}" \
          | jq -r '.commit.sha // empty')
      fi

      branch="${gh_def_branch:-${fallback_branch}}"
      [[ -n "${branch}" ]] || branch="master"
      gitee_hash=$(curl -s -u "${GITEE_USER}:${MY_GITEE_PAT}" \
        "${GITEE_API}/repos/${ns}/${name}/branches/${branch}" | jq -r '.commit.sha // empty')

      if [[ -z "${github_hash}" ]]; then
        # 取不到上游 SHA 时不能判成"已同步", 单列为 UNKNOWN 留待下次
        status="UNKNOWN"
      elif [[ -z "${gitee_hash}" ]]; then
        # gitee 上仓库或分支不存在 => 必须推送
        status="NEED_SYNC"
      elif [[ "${github_hash}" == "${gitee_hash}" ]]; then
        status="OK"
      else
        status="NEED_SYNC"
      fi
    fi
  fi

  printf '%s\n%s\n' "${status}" "${key}" > "${TMP_WORK}/r_${idx}.result"
  return 0
}

# ---------- 并行比对 ----------
total=${#CAND_KEYS[@]}
echo "待检查: ${total} 个仓库 (并发 ${PARALLEL_JOBS})"

running=0
for (( i = 0; i < total; i++ )); do
  check_one "${i}" "${CAND_KEYS[$i]}" "${CAND_BRANCH[$i]}" &
  running=$(( running + 1 ))
  if (( running >= PARALLEL_JOBS )); then
    wait -n 2>/dev/null || true
    running=$(( running - 1 ))
  fi
done
wait

# ---------- 汇总 ----------
SYNC_REPOS=()
OK_COUNT=0
SKIP_COUNT=0
UNKNOWN_COUNT=0
FAIL_COUNT=0

for result_file in "${TMP_WORK}"/r_*.result; do
  [[ -f "${result_file}" ]] || continue
  { IFS= read -r status; IFS= read -r key; } < "${result_file}"
  case "${status}" in
    OK)
      echo "[OK] ${key} 已是最新"
      OK_COUNT=$(( OK_COUNT + 1 ))
      ;;
    NEED_SYNC)
      echo "[SYNC] ${key} 需要同步"
      SYNC_REPOS+=("${key}")
      ;;
    SKIP)
      echo "[SKIP] ${key} 无上游映射"
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
      ;;
    UNKNOWN)
      echo "[UNKNOWN] ${key} 无法取得上游 SHA(限流/网络)"
      UNKNOWN_COUNT=$(( UNKNOWN_COUNT + 1 ))
      ;;
    *)
      echo "[ERROR] ${key} 校验失败"
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
  echo "## 🔍 Gitee 镜像差异检查"
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
    echo "已触发「Gitee镜像-同步」工作流。"
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
