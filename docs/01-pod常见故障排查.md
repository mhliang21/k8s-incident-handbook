# K8s 故障排查 SOP · 第一篇：Pod 常见故障

> 环境：kind v0.27 + kubectl v1.32 · 3 节点集群
> 本文是「可复现故障 + 排查步骤 + 根因 + 修复」的手册，每个故障都能在本地 kind 集群复现。

## 核心排查链路

```
describe → events → logs → exec
```

80% 的问题在 `kubectl describe pod` 的 Events 底部就能定位。剩下 20% 靠 `logs` 和 `exec`。

## 排查口诀速查

| 口诀 | 含义 |
|------|------|
| `describe pod` 先看 Events 底部 | 80% 的原因都在这里暴露 |
| `logs --previous` 是神器 | CrashLoopBackOff 容器反复重启，当前容器可能刚启动还没输出 |
| Exit Code 137 = OOM | 被内核 SIGKILL 一定是 137；Exit Code 1 = 应用自己退出 |
| NotReady 等 40 秒 | kubelet 心跳超时（node-monitor-grace-period）默认 40s |
| `-o wide` 看分布 | Pod 在哪个节点、IP 是什么 |

---

## 故障 1 · ImagePullBackOff（镜像拉取失败）

### 制造

```bash
kubectl run bad-image --image=nginx:99999 --port=80
```

### 排查

```bash
kubectl get pods                          # 看到 ImagePullBackOff / ErrImagePull
kubectl describe pod bad-image            # 看 Events 尾部
kubectl get events --field-selector involvedObject.name=bad-image
```

关键输出（describe Events 尾部）：

```
Warning  Failed  33s  kubelet  Failed to pull image "nginx:99999": rpc error: code = NotFound
Warning  Failed  33s  kubelet  Error: ErrImagePull
Normal   BackOff 18s  kubelet  Back-off pulling image "nginx:99999"
Warning  Failed  18s  kubelet  Error: ImagePullBackOff
```

### 根因

镜像标签 `nginx:99999` 不存在。生产常见变体：私有仓库缺 `imagePullSecrets`、镜像名拼错、网络隔离。

### 修复

```bash
kubectl set image pod/bad-image nginx=nginx:alpine
# 或删除重建
kubectl delete pod bad-image
```

---

## 故障 2 · CrashLoopBackOff（容器反复重启）

### 制造

```bash
kubectl run crash-loop --image=busybox --restart=Never -- /bin/sh -c "echo starting && exit 1"
```

### 排查

```bash
kubectl get pods                           # RESTARTS 列数字不断增大
kubectl describe pod crash-loop            # 看 Last State / Exit Code
kubectl logs crash-loop --previous         # 核心！拿崩溃前日志
```

关键输出（describe Last State）：

```
Last State:     Terminated
  Reason:       Error
  Exit Code:    1
```

关键输出（logs --previous）：

```
starting...
```

### 根因

容器主进程执行 `exit 1` 退出，RestartPolicy 触发重启，陷入 CrashLoopBackOff。

> 面试加分点：解释 `--previous` 原理——CrashLoopBackOff 容器反复重启，当前容器可能刚启动还没输出，只有 `--previous` 能看到上一次崩溃的真实原因。

---

## 故障 3 · OOMKilled（内存超限）

### 制造

```yaml
# oom-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-killer
spec:
  containers:
  - name: mem-eater
    image: python:3.11-alpine
    command: ["python", "-c", "a = bytearray(200 * 1024 * 1024)"]
    resources:
      limits:
        memory: "50Mi"
```

```bash
kubectl apply -f oom-pod.yaml
```

### 排查

```bash
kubectl get pods                          # OOMKilled → CrashLoopBackOff
kubectl describe pod oom-killer           # 看 Last State / Exit Code
kubectl top pod oom-killer                # 需装 metrics-server
```

关键输出：

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

### 根因

应用分配 200MB，limit 只有 50Mi，内核 OOM Killer 杀掉进程。

> 面试加分点：Exit Code 137 = 128 + 9 (SIGKILL)，OOMKilled 一定是 137；如果 Exit Code = 1，是应用自己退出的。

---

## 故障 4 · Pending（调度失败）

### 制造（资源不足）

```bash
kubectl run pending-res --image=nginx:alpine --requests=memory=1Ti
```

### 制造（PVC 不存在）

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pending-pvc
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: does-not-exist
```

### 排查

```bash
kubectl describe pod pending-res
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20
```

关键输出：

```
# 资源不足
Warning  FailedScheduling  2m  default-scheduler  0/3 nodes are available: 3 Insufficient memory.
# PVC 不存在
Warning  FailedScheduling  2m  default-scheduler  persistentvolumeclaim "does-not-exist" not found
```

### 根因

Scheduler 找不到合适的节点：PVC 缺失 / 资源不足 / nodeSelector 不匹配 / taint。

---

## 故障 5 · Node NotReady（节点宕机）

### 制造

```bash
docker ps | grep k8s-lab-worker   # 找 worker 容器名
docker stop k8s-lab-worker        # 停掉一个 worker
kubectl get nodes -w              # 等约 40 秒变 NotReady
```

### 排查

```bash
kubectl get nodes                       # STATUS 变 NotReady
kubectl describe node k8s-lab-worker    # 看 Conditions 段
kubectl get pods -o wide                # 看该节点上的 Pod 状态
```

关键输出（describe Conditions）：

```
Conditions:
  Type             Status  Reason
  Ready            False   KubeletNotReady
```

### 根因

kubelet 无法向 apiserver 发送心跳（默认 40s 超时）。生产常见：kubelet 挂 / 节点负载高 / 网络分区 / 磁盘满。

### 恢复

```bash
docker start k8s-lab-worker
kubectl get nodes -w   # 等待恢复 Ready
```

---

## 汇总：5 故障 1 张表

| # | 故障 | 制造方式 | 排查入口 | 典型根因 |
|---|------|---------|---------|---------|
| 1 | ImagePullBackOff | 镜像 tag 不存在 | describe → "Failed to pull image" | 仓库不通 / tag 错误 / imagePullSecrets |
| 2 | CrashLoopBackOff | 容器 exit 1 | `logs --previous` | 应用启动失败 / 配置错误 |
| 3 | OOMKilled | limit < 实际需求 | describe → Exit Code 137 | limit 过低 / 内存泄漏 |
| 4 | Pending | PVC 缺失 / 资源不足 | describe → FailedScheduling | PVC 缺失 / 节点资源不足 / taint |
| 5 | Node NotReady | 停 worker 容器 | describe node → Conditions | kubelet 挂 / 网络 / 磁盘 |
