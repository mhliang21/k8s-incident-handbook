# K8s 故障排查 SOP · 第三篇：用 Ansible/Shell 写集群巡检脚本

> 环境：kind v0.27 + kubectl v1.32 + Bash · 3 节点集群
> 本篇记录如何从 0 写一个 K8s 集群巡检脚本（Shell + Ansible 两个版本），以及集成 AI 工具辅助排障的思路。

## 一、为什么要写巡检脚本

纯手工 `kubectl` 排查效率低、依赖个人经验、无法沉淀。巡检脚本的价值：

1. **标准化**：把排障经验固化成可重复执行的检查项
2. **自动化**：一条命令跑完所有检查，适合定时任务 / CI
3. **AI 联动**：脚本负责「发现问题」，AI 负责「定位根因 + 给方案」

## 二、Shell 版巡检脚本（k8s-inspect.sh）

适用于本地 kind / 任意有 kubectl 的集群。

### 核心结构

```bash
set -uo pipefail   # 严格模式：未定义变量报错 + 管道失败传递

# 6 大类检查
1. 节点健康      # NotReady / 内存磁盘压力 / 资源水位
2. Pod 异常      # Pending / CrashLoopBackOff / OOMKilled 等 6 种状态
3. Warning 事件  # 最近 15 条 Warning
4. 控制面组件    # apiserver / controller-manager / scheduler / etcd
5. 证书与健康    # apiserver readyz
6. 总结 + AI prompt 生成
```

### 关键设计

**1. 计数与问题收集**

```bash
ISSUE_COUNT=0
ISSUES=()
warn() { ISSUE_COUNT=$((ISSUE_COUNT+1)); ISSUES+=("$1"); }
```

每次发现异常都调 `warn`，最后统一汇总。

**2. 三类输出模式**

```bash
bash k8s-inspect.sh            # 彩色终端输出
bash k8s-inspect.sh --json     # 机器可读 JSON（接 CI）
bash k8s-inspect.sh --ai       # 检测到异常时生成 AI 排障 prompt
```

**3. AI prompt 自动生成**

```bash
if $AI_MODE && [ "$ISSUE_COUNT" -gt 0 ]; then
  echo "我的 K8s 集群巡检发现以下问题，请逐一分析根因..."
  for i in "${ISSUES[@]}"; do
    echo "- $i"
  done
  echo "请按：现象 → 可能根因 → 排查命令 → 修复方案 的结构回答。"
fi
```

### ⚠️ 踩坑记录

**1. `pipefail` + `grep -q` 的时序竞态**

最初用：

```bash
CERT_CHECK=$(kubectl get --raw '/readyz' | grep -q ok && echo ok || echo fail)
```

问题：`grep -q` 一匹配到 "ok" 就**立即退出**，管道提前关闭，`kubectl` 收到 broken pipe 报错。在 `pipefail` 模式下，管道里任何一个命令非零退出，整条管道就返回非零，导致误判成 `fail`。

这是时序竞态——readyz 内容短（就 `ok\n`），大部分时候能正常，但在某些环境（如 CMD 的 bash）会稳定触发。

修复：直接拿原始字符串对比，不依赖管道退出码：

```bash
READYZ=$(kubectl get --raw '/readyz' 2>/dev/null | tr -d '\r\n')
if [ "$READYZ" = "ok" ]; then
```

**2. `kubectl top` 依赖 metrics-server**

如果没有装 metrics-server，`kubectl top` 会报 `Metrics API not available`。脚本里要对这种情况做降级处理：

```bash
if kubectl top nodes >/dev/null 2>&1; then
  kubectl top nodes
else
  warn "metrics-server 未就绪，跳过资源水位检查"
fi
```

## 三、Ansible 版巡检脚本（k8s-inspect.yml）

适用于生产多节点集群，通过 SSH 批量巡检物理状态。

### 核心思路

Shell 版走 **kubectl API**，查集群逻辑状态（Pod/事件/组件）；Ansible 版走 **SSH**，查节点物理状态（磁盘/内存/kubelet 进程）。两者互补：

| 维度 | Shell 版 | Ansible 版 |
|------|---------|-----------|
| 访问方式 | kubectl API | SSH |
| 检查内容 | 集群逻辑状态 | 节点物理状态 |
| 适用场景 | 本地/开发 | 生产多节点 |
| 前置条件 | kubectl + context | ansible + SSH 免密 |

### inventory.ini 模板

```ini
[k8s-nodes]
node1 ansible_host=192.168.1.10 ansible_user=root
node2 ansible_host=192.168.1.11 ansible_user=root
node3 ansible_host=192.168.1.12 ansible_user=root
```

### 关键 task

```yaml
- name: 检查磁盘使用率
  ansible.builtin.shell: df -h --output=source,pcent,target
  register: disk_usage

- name: 磁盘告警
  ansible.builtin.fail:
    msg: "磁盘使用率超过 80%"
  when: (disk_usage.stdout | regex_findall('[0-9]+%') | map('int') | max) > 80
  ignore_errors: yes
```

### ⚠️ 注意：kind 无法本地验证 Ansible 版

kind 的"节点"是 Docker 容器，**没有 sshd**，`ansible-playbook` 连不上。这是正常的，不是配置问题。Ansible 版需要用真实 VM / 服务器验证。

## 四、AI 辅助排障集成方案

巡检脚本负责「发现问题」，AI 负责「定位根因 + 给方案」。两条链路：

**方案 A：脚本生成 prompt（推荐起步）**

```bash
bash k8s-inspect.sh --ai
# 检测到异常时，输出可粘贴给 Claude Code / Codex 的 prompt
```

**方案 B：AI 直连集群（进阶）**

```bash
claude "我的 k8s 集群有 pod 处于 CrashLoopBackOff，帮我定位根因"
# Claude Code 会自己跑 kubectl describe / logs --previous 等命令
```

## 五、执行方式汇总

```bash
# Shell 版
cd inspect
bash k8s-inspect.sh
bash k8s-inspect.sh --json
bash k8s-inspect.sh --ai

# Ansible 版（生产环境）
cd inspect
ansible-playbook -i inventory.ini k8s-inspect.yml
```

## 六、实战验证

脚本在 kind-k8s-lab 上真实抓出过 4 类问题：

| 问题 | 现象 | 根因 |
|------|------|------|
| oom-killer BackOff | 遗留 Pod | 之前实验没清理 |
| metrics-server Liveness 失败 | context deadline exceeded | 未加 `--kubelet-insecure-tls` |
| grafana Readiness 失败 | connection refused | 内存 limit 太小被 OOM |
| kube-proxy FailedToUpdateEndpoint | Unauthorized | RBAC 权限问题 |

这验证了脚本的价值——不靠人肉排查，一条命令就能把集群异常全揪出来。
