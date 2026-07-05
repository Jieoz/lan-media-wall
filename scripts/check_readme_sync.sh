#!/usr/bin/env bash
# check_readme_sync.sh — 发布/推送前硬门槛:任一模块有代码改动,其对应 README 必须
# 在同一批改动里一起更新;否则退出码非 0,挡住"文档跟不上代码"。
#
# 用法:
#   scripts/check_readme_sync.sh            # 对比 工作树+暂存区 vs HEAD(提交前用)
#   scripts/check_readme_sync.sh <base>     # 对比 HEAD vs <base>(发版/合并前用,如 v1.8.0)
#
# 判定:某模块目录下(排除 README 本身)有文件改动,而该模块的 README 未改 → 违规。
# 根 README 视作"任一模块有改动就应考虑更新",但为免噪音,仅当**跨≥2个模块**改动
# 或改了 protocol_spec.md 时才强制要求根 README 同步。

set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-}"
if [ -n "$BASE" ]; then
  DIFF="git diff --name-only ${BASE} HEAD"
else
  # 提交前:暂存区 + 工作树相对 HEAD 的全部改动
  DIFF="git diff --name-only HEAD"
fi

CHANGED="$($DIFF)"
if [ -z "$CHANGED" ]; then
  echo "check_readme_sync: 无改动,跳过。"
  exit 0
fi

# 模块 → 其 README 路径
declare -A README=(
  ["broker"]="broker/README.md"
  ["windows_player"]="windows_player/README.md"
  ["android_apps/player"]="android_apps/player/README.md"
  ["remote_flutter"]="remote_flutter/README.md"
)

violations=0
touched_modules=0

is_changed() { echo "$CHANGED" | grep -qxF "$1"; }
module_has_code_change() {
  # $1=模块前缀;排除该模块自己的 README
  echo "$CHANGED" | grep -q "^$1/" \
    && echo "$CHANGED" | grep "^$1/" | grep -qvxF "${README[$1]}"
}

for mod in "${!README[@]}"; do
  if echo "$CHANGED" | grep -q "^$mod/"; then
    # 该模块有非 README 的代码/资源改动?
    code_changed=$(echo "$CHANGED" | grep "^$mod/" | grep -vxF "${README[$mod]}" || true)
    if [ -n "$code_changed" ]; then
      touched_modules=$((touched_modules+1))
      if is_changed "${README[$mod]}"; then
        echo "✓ $mod: 代码有改动,README 已同步更新"
      else
        echo "✗ $mod: 代码有改动但 ${README[$mod]} 未更新 —— 请同步 README"
        echo "    改动文件:"
        echo "$code_changed" | sed 's/^/      /'
        violations=$((violations+1))
      fi
    fi
  fi
done

# 根 README:跨模块大改 或 改了协议合同 时强制要求同步
proto_changed=false
is_changed "protocol_spec.md" && proto_changed=true
if [ "$touched_modules" -ge 2 ] || [ "$proto_changed" = true ]; then
  if is_changed "README.md"; then
    echo "✓ root: 跨模块/协议改动,根 README 已同步"
  else
    echo "✗ root: 跨模块(${touched_modules}个)或协议改动,但根 README.md 未更新 —— 请同步"
    violations=$((violations+1))
  fi
fi

echo "----"
if [ "$violations" -gt 0 ]; then
  echo "check_readme_sync: 发现 $violations 处 README 未同步。交付红线要求 README 随代码同步更新。"
  exit 1
fi
echo "check_readme_sync: 全部通过 ✓"
