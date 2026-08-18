# K8s 故障排查 SOP · 第四篇：CI/CD 与 GitOps 交付实践

> 环境：GitHub Actions + Helm 3 + Argo CD · kind v0.27 3 节点集群
> 前三篇讲「怎么排查问题」，本篇讲「怎么把应用交付上线」。以一个 FastAPI 应用 `pod-health-api` 为例，记录从「手动 kubectl apply」演进到「Git 提交即自动部署」的完整交付链路：容器化 → CI 构建镜像 → Helm 打包 → Argo CD GitOps。

## 一、为什么需要 CI/CD + GitOps

手动运维的痛点：命令记不住、易出错、操作不可追溯、换人不会部署。工程化交付的价值是把「人肉操作」变成「可重复的自动化流水线」：

```
手动 kubectl apply         → 依赖个人记忆，易错、不可追溯
   ↓
Dockerfile 容器化          → 环境一致，一次构建、到处运行
   ↓
GitHub Actions CI          → 提交即自动跑测试 + 构建镜像
   ↓
Helm Chart 打包            → 参数化、可复用、可版本管理
   ↓
Argo CD GitOps             → Git 是唯一事实源，自动同步
```

一句话：**Git 提交 = 部署**。人不再手动操作集群，集群状态由 Git 仓库里的配置决定。

## 二、Demo 项目：pod-health-api

一个查询 K8s 集群 Pod 健康度的 FastAPI 服务，作为贯穿本片的交付对象。

```
pod-health-api/
├── app/main.py              # FastAPI 应用（核心逻辑）
├── tests/test_main.py       # 单元测试
├── Dockerfile               # 容器镜像
├── requirements.txt         # 依赖清单
├── pytest.ini               # 修 CI 导入路径
├── .github/workflows/ci.yml # GitHub Actions 流水线
├── charts/pod-health-api/   # Helm Chart
└── argocd-app.yaml          # Argo CD Application 定义
```

### 核心设计：双模式 K8s 客户端

```python
def get_k8s_client():
    if os.getenv("KUBERNETES_SERVICE_HOST"):
        config.load_incluster_config()   # 集群内：用 ServiceAccount
    else:
        config.load_kube_config()        # 本地：读 ~/.kube/config
    return client.CoreV1Api()
```

同一个服务，部署进集群用 ServiceAccount 权限，本地开发读 kubeconfig。这是真实 K8s 开发的标准写法。

### 双探针设计

| 路由 | 作用 | K8s 对应 |
|------|------|---------|
| `GET /healthz` | 恒返回 healthy | livenessProbe（活着就行） |
| `GET /readyz` | 真连 K8s API，连不上返 503 | readinessProbe（能干活才接流量） |
| `GET /pods` | 列所有 Pod 健康度 | 核心业务接口 |

> 面试点：liveness vs readiness 的区别——存活探针只判断「进程活着」，就绪探针判断「服务准备好接收流量」。`readyz` 真的去探 K8s API，体现了两者的本质差异。

## 三、Dockerfile：容器化三要点

```dockerfile
FROM python:3.11-slim        # 1. slim 而非完整版，镜像小、攻击面小

WORKDIR /app

COPY requirements.txt .      # 2. 先复制依赖，利用 Docker 层缓存
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/               # 再复制代码（改代码不重装依赖）

RUN useradd -m appuser       # 3. 非 root 运行（安全最佳实践）
USER appuser

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

三个加分点：**slim 基础镜像**、**依赖与代码分两层 COPY**（利用层缓存加速构建）、**非 root 用户**。

## 四、GitHub Actions CI：提交即测试 + 构建镜像

`.github/workflows/ci.yml` 分两个 job，`build-and-push` 依赖 `test` 成功才执行：

```yaml
name: CI
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  test:                          # Job 1：跑单元测试
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: |
          pip install -r requirements.txt
          pip install pytest
      - run: pytest -v

  build-and-push:                # Job 2：构建镜像推 GHCR
    needs: test                  # 测试通过才构建
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:latest
            ghcr.io/${{ github.repository }}:${{ github.sha }}
```

关键点：`needs: test` 让「测试不过不构建」；`GITHUB_TOKEN` 免配置即可登录 GHCR；tag 同时打 `latest` 和 `${{ github.sha }}`（commit 短哈希，可回溯）。

### ⚠️ 踩坑 1 · CI 里报 `No module named 'app'`

**现象**：本地 `pytest` 全绿，push 到 GitHub 后 CI 报 `ModuleNotFoundError: No module named 'app'`。

**根因**：本地习惯用 `python -m pytest`，它会自动把**当前目录**加进 `sys.path`，所以 `from app.main import app` 能找到。但 CI 里直接跑 `pytest`（不带 `-m`），不会加当前目录，`app` 包就 import 不进来了。

**修复**：加 `pytest.ini`，显式声明项目根目录：

```ini
[pytest]
pythonpath = .
testpaths = tests
```

> 教训：**本地能跑 ≠ CI 能跑**。两者运行环境、工作目录、命令前缀都可能不同，这类问题只在换环境时暴露，CI 是最后兜底。

### ⚠️ 踩坑 2 · CI 里 httpx 缺失

**现象**：`from fastapi.testclient import TestClient` 在 CI 报缺 `httpx`。

**根因**：`TestClient` 底层依赖 `httpx`，但 `httpx` 不在业务代码的显式依赖里（本地之前单独装过，没写进 `requirements.txt`）。CI 是干净环境，按 `requirements.txt` 装，自然缺。

**修复**：把 `httpx` 显式加进 `requirements.txt`：

```
httpx==0.28.1
```

> 教训：**测试依赖也要进 requirements.txt**。本地能跑是因为环境「脏」，CI 干净环境会把隐式依赖全暴露出来。

## 五、Helm Chart：参数化打包

```
charts/pod-health-api/
├── Chart.yaml               # chart 元数据
├── values.yaml              # 参数化配置（唯一改的地方）
└── templates/
    ├── _helpers.tpl         # 模板函数（fullname/labels）
    ├── deployment.yaml      # Deployment
    ├── service.yaml         # Service
    ├── serviceaccount.yaml  # ServiceAccount
    └── rbac.yaml            # ClusterRole + ClusterRoleBinding
```

### 关键设计

**1. 全参数化**：副本数、镜像 tag、资源、探针全在 `values.yaml`，不同环境用 `-f` 覆盖，不改模板：

```yaml
replicaCount: 3
image:
  repository: ghcr.io/mhliang21/pod-health-api
  tag: 'latest'
resources:
  limits:   { cpu: 500m, memory: 256Mi }
  requests: { cpu: 100m, memory: 128Mi }
fullnameOverride: pod-health-api   # 固定资源名，避免双名坑（见踩坑 3）
```

**2. RBAC 最小权限**：应用要调 K8s API 查 Pod，所以必须有 ServiceAccount + ClusterRole。但只给**只读**权限，不给写：

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]   # 只有读，没有 create/delete
```

**3. 双探针**：`liveness` 用 `/healthz`、`readiness` 用 `/readyz`，与代码里的双探针设计呼应。

### ⚠️ 踩坑 3 · Helm 资源名被拼成双份

**现象**：`helm install pod-health-api ...` 后，Service 名变成了 `pod-health-api-pod-health-api`，`kubectl port-forward svc/pod-health-api` 报 NotFound。

**根因**：Helm 的 `fullname` 是 `Release 名 + Chart 名` 拼接。这里 release 名和 chart 名恰好都叫 `pod-health-api`，拼起来就重复了。

**修复**：在 `values.yaml` 加 `fullnameOverride` 固定资源名：

```yaml
fullnameOverride: pod-health-api
```

之后所有资源名统一为 `pod-health-api`，Argo CD 引用也简洁。

## 六、Argo CD：GitOps 自动同步

### 1. 安装

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w          # 等全部 Ready（1-2 分钟）

# 暴露 UI（端口转发，别关这个窗口）
kubectl port-forward -n argocd svc/argocd-server 8080:443

# 获取初始密码
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
# 浏览器 https://localhost:8080（跳过证书警告），admin 登录
```

### 2. Application 定义

`argocd-app.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pod-health-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mhliang21/pod-health-api.git
    targetRevision: main
    path: charts/pod-health-api        # 指向 Helm Chart 目录
    helm:
      valueFiles: [ values.yaml ]
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  syncPolicy:
    automated:        # 自动同步
      prune: true     # 删除 Git 里删掉的资源
      selfHeal: true  # 集群被人为改动自动纠正
```

三个 `syncPolicy` 参数是 GitOps 的精髓：`automated`（自动检测变更）、`prune`（Git 删了集群也删）、`selfHeal`（集群被手改自动纠回）。

```bash
kubectl apply -f argocd-app.yaml
```

### 3. 验证 GitOps 闭环

1. Argo CD UI 里 `pod-health-api` 变 **Synced**（绿色）
2. 改 `values.yaml` 的 `replicaCount: 3` → `5`，`git push`
3. 几十秒后 Argo CD 自动检测到变更，`kubectl get pods -n demo` 变成 5 个副本
4. **全程没碰过 kubectl apply**——这就是 GitOps 的威力

### ⚠️ 踩坑 4 · Argo CD 报 `app path does not exist`

**现象**：Application 状态 `ComparisonError`，报 `charts/pod-health-api: app path does not exist`。

**根因**：Argo CD 是**从 Git 仓库拉配置**的（不是从本地）。Helm Chart 只存在本地、从未 `git push` 到 GitHub，Argo CD 自然在 Git 里找不到这个路径。

**修复**：把 chart 提交并推送到 Git 仓库后，Argo CD 自动重试（或 UI 手动 Sync），错误消除。

> 教训：GitOps 里 **Git 是唯一事实源**。本地改了不 push，集群不会知道；同理，绕过 Git 直接 `kubectl apply` 也会被 `selfHeal` 纠正回去。这个认知转变是 GitOps 的核心。

## 七、完整交付闭环

```
开发者 git push main
        │
        ▼
GitHub Actions CI ──► 跑测试 ──► 构建镜像 ──► 推送到 GHCR
        │
        ▼
Argo CD 监听 Git 仓库变化
        │
        ▼
拉取 Helm Chart ──► 渲染 ──► 应用到 kind 集群
        │
        ▼
pod-health-api 运行（3 副本 + 双探针 + RBAC 只读）
```

两条流水线的分工：
- **CI（GitHub Actions）**：负责「代码 → 镜像」，产出可部署的镜像到 GHCR
- **CD（Argo CD）**：负责「配置 → 集群」，把 Git 里的部署配置同步到集群

## 八、踩坑汇总

| # | 踩坑 | 现象 | 根因 | 修复 |
|---|------|------|------|------|
| 1 | CI import 失败 | `No module named 'app'` | 本地 `-m pytest` 加目录到 path，CI 直接 `pytest` 不加 | `pytest.ini` 设 `pythonpath = .` |
| 2 | CI httpx 缺失 | TestClient 报缺 httpx | 测试依赖没写进 requirements.txt | 显式加 `httpx` |
| 3 | Helm 双名 | 服务名 `pod-health-api-pod-health-api` | release 名 + chart 名拼接重复 | `fullnameOverride` 固定 |
| 4 | Argo CD 路径不存在 | `app path does not exist` | chart 只在本地，没 push 到 Git | push 到 Git 后重试同步 |

## 九、快速复现命令

```bash
# 1. 本地验证（不依赖集群的部分）
cd pod-health-api
python -m pytest -v

# 2. 本地 Helm 渲染检查（不装集群也能查语法）
helm lint charts/pod-health-api
helm template test charts/pod-health-api

# 3. 本地装到 kind 验证
helm install pod-health-api charts/pod-health-api -n demo --create-namespace
kubectl get pods -n demo
kubectl port-forward -n demo svc/pod-health-api 8000:80
curl localhost:8000/pods          # 应返回集群 Pod 健康度

# 4. 交给 Argo CD（Git 提交后自动部署）
kubectl apply -f argocd-app.yaml
```

## 附：本篇涉及的两个仓库

| 仓库 | 作用 | 地址 |
|------|------|------|
| pod-health-api | demo 应用（代码 + CI + Helm + Argo CD） | github.com/mhliang21/pod-health-api |
| k8s-incident-handbook | 本手册（四篇笔记） | github.com/mhliang21/k8s-incident-handbook |

本篇把前面的「故障排查」「监控」「巡检」串成一个可交付的工程：**排查发现问题 → 监控提前预警 → 巡检自动化检查 → CI/CD 交付上线**，形成 K8s 运维的完整闭环。
