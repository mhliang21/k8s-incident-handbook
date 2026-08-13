#!/usr/bin/env bash
# =============================================================================
# k8s-inspect.sh — K8s 集群一键巡检脚本
# 适用：kind / 生产集群（需 kubectl 已配置 context）
# 用法：bash k8s-inspect.sh [--json] [--ai]
#   --json  输出机器可读的 JSON 报告
#   --ai    检测到异常时，自动生成可粘贴给 Claude Code / Codex 的排障 prompt
# =============================================================================

set -uo pipefail

# ---------- 颜色 ----------
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'

JSON_MODE=false
AI_MODE=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON_MODE=true ;;
    --ai)   AI_MODE=true ;;
  esac
done

ISSUE_COUNT=0
ISSUES=()

log()  { printf "%b%s%b\n" "$1" "$2" "$NC"; }
ok()   { log "$GREEN" "  ✓ $1"; }
warn() { log "$YELLOW" "  ⚠ $1"; ISSUE_COUNT=$((ISSUE_COUNT+1)); ISSUES+=("$1"); }
err()  { log "$RED" "  ✗ $1"; ISSUE_COUNT=$((ISSUE_COUNT+1)); ISSUES+=("$1"); }
sec()  { printf "\n%b━━━ %s ━━━%b\n" "$BLUE" "$1" "$NC"; }

# ---------- 前置检查 ----------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 未安装或不在 PATH"; exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "无法连接集群，请检查 kubeconfig / context"; exit 1
fi

CLUSTER=$(kubectl config current-context 2>/dev/null)
sec "集群巡检报告"
echo "  Context : $CLUSTER"
echo "  时间    : $(date '+%Y-%m-%d %H:%M:%S')"

# =============================================================================
sec "1. 节点健康"
# =============================================================================
NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | wc -l)
if [ "$NOTREADY" -eq 0 ]; then
  ok "所有节点 Ready"
else
  err "存在 $NOTREADY 个非 Ready 节点："
  kubectl get nodes --no-headers | grep -v ' Ready' | awk '{print "      - " $1 " " $2}'
fi

# 磁盘/内存压力
PRESSURE=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\t"}{.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}{end}' 2>/dev/null)
if echo "$PRESSURE" | grep -q True; then
  warn "存在节点资源压力（Memory/Disk Pressure）"
fi

# 节点资源水位（需 metrics-server）
if kubectl top nodes >/dev/null 2>&1; then
  echo ""
  kubectl top nodes --no-headers 2>/dev/null | while read -r line; do
    echo "  $line"
  done
else
  warn "metrics-server 未就绪，跳过资源水位检查（kubectl top 不可用）"
fi

# =============================================================================
sec "2. Pod 异常巡检"
# =============================================================================
for status in Pending CrashLoopBackOff ImagePullBackOff OOMKilled Evicted CreateContainerConfigError; do
  COUNT=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "$status" || true)
  if [ "$COUNT" -gt 0 ]; then
    err "发现 $COUNT 个 $status 状态的 Pod："
    kubectl get pods -A --no-headers | grep "$status" | awk '{print "      - " $1 "/" $2}'
  fi
done

TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
RUNNING=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c Running || true)
ok "Pod 总计 $TOTAL_PODS 个，Running $RUNNING 个"

# =============================================================================
sec "3. 最近 Warning 事件"
# =============================================================================
WARN_EVENTS=$(kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -15)
if [ -n "$WARN_EVENTS" ]; then
  warn "最近 Warning 事件（最多 15 条）："
  echo "$WARN_EVENTS" | awk '{print "      - " $0}'
else
  ok "无 Warning 事件"
fi

# =============================================================================
sec "4. 控制面组件"
# =============================================================================
for comp in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  if kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -q "$comp"; then
    READY=$(kubectl get pods -n kube-system --no-headers | grep "$comp" | awk '{print $2}')
    if echo "$READY" | grep -q '^1/1'; then
      ok "$comp 正常"
    else
      warn "$comp 状态异常：$READY"
    fi
  fi
done

# =============================================================================
sec "5. 证书有效期"
# =============================================================================
READYZ=$(kubectl get --raw '/readyz' 2>/dev/null | tr -d '\r\n')
if [ "$READYZ" = "ok" ]; then
  ok "apiserver readyz 健康"
else
  warn "apiserver readyz 未通过"
fi

# =============================================================================
sec "6. 总结"
# =============================================================================
echo ""
if [ "$ISSUE_COUNT" -eq 0 ]; then
  log "$GREEN" "  ✅ 巡检通过，未发现异常。"
else
  log "$RED" "  ⚠ 巡检完成，共发现 $ISSUE_COUNT 个问题："
  for i in "${ISSUES[@]}"; do
    echo "      - $i"
  done
fi
echo ""

# =============================================================================
# AI 排障 prompt 生成
# =============================================================================
if $AI_MODE && [ "$ISSUE_COUNT" -gt 0 ]; then
  sec "AI 排障提示"
  echo "  将以下内容粘贴给 Claude Code / Codex / Cursor："
  echo ""
  echo "  ─────────────────────────────────────────"
  echo "  我的 K8s 集群（context: $CLUSTER）巡检发现以下问题，请帮我逐一分析根因并给出排查命令和修复方案："
  for i in "${ISSUES[@]}"; do
    echo "  - $i"
  done
  echo "  请按：现象 → 可能根因 → 排查命令 → 修复方案 的结构回答。"
  echo "  ─────────────────────────────────────────"
  echo ""
fi

# ---------- JSON 输出 ----------
if $JSON_MODE; then
  cat <<EOF
{
  "cluster": "$CLUSTER",
  "time": "$(date -Iseconds)",
  "issue_count": $ISSUE_COUNT,
  "issues": $(printf '%s\n' "${ISSUES[@]}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))' 2>/dev/null || echo '[]')
}
EOF
fi

exit 0
