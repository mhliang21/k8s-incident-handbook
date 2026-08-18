# k8s-incident-handbook

K8s 故障手册——可复现的故障、排查步骤、根因与修复方案。每篇都附实战踩坑记录，全部能在本地 kind 集群复现验证。

## 📚 笔记目录

| # | 笔记 | 主题 |
|---|------|------|
| 1 | [Pod 常见故障](./docs/01-pod常见故障排查.md) | ImagePullBackOff / CrashLoopBackOff / OOMKilled / Pending / Node NotReady |
| 2 | [监控搭建与全链路验证](./docs/02-监控搭建与全链路验证.md) | Prometheus 监控体系 + 5 条告警规则 + 制造故障验证告警链路 |
| 3 | [用 Ansible/Shell 写集群巡检脚本](./docs/03-用Ansible和Shell写集群巡检脚本.md) | Shell + Ansible 双版本巡检脚本 + AI 辅助排障 |
| 4 | [CI/CD 与 GitOps 交付实践](./docs/04-CICD与GitOps交付实践.md) | GitHub Actions + Helm Chart + Argo CD，Git 提交即自动部署 |
| 5 | [Go 语言速成与实践](./docs/05-Go语言速成与实践.md) | Go Tour + 前 10 章 + 两个工具，练 goroutine/interface/error |

## 🗂 目录结构

```
docs/                # 五篇笔记
inspect/             # 巡检脚本（Shell + Ansible）
monitoring/          # 监控相关配置
faults/              # 可复现故障的 yaml
```

## 🚀 配套 Demo 项目

- [pod-health-api](https://github.com/mhliang21/pod-health-api)——一个查询 K8s Pod 健康度的 FastAPI 服务，演示第四篇笔记里的 CI/CD + Helm + Argo CD 全链路。
- [go-tools](https://github.com/mhliang21/go-tools)——Go 语言实践的两个工具（httpprobe / wordstats），演示第五篇笔记里的三大核心概念。

## 🧭 学习路径

```
排查问题 → 监控预警 → 巡检自动化 → CI/CD 交付 → Go 语言进阶
 （笔记1）  （笔记2）   （笔记3）    （笔记4）    （笔记5）
```
