# hygon-1：Kubernetes 上的 Kata Redis 容器冒烟验证

状态：2026-11-25 已通过一次真实 Redis 工作负载验证。该记录证明当前普通 `kata-qemu` 路线能够经 Kubernetes 启动容器并执行 Redis 命令；**不代表 Hygon CSV2 RuntimeClass 验收，也不是性能或保密性结果**。

## 环境与测试路线

- 主机：`hygon-1`，AliOS 7.2，host kernel `5.10.134-hygon-csv`。
- Kubernetes：`v1.35.10`；containerd：`v2.3.6`；节点 Ready，当前为 cgroup v1，kubelet 配置 `failCgroupV1: false`。
- RuntimeClass：`kata-qemu`（containerd handler `kata`），使用既有普通 Kata QEMU 配置。
- 镜像：`docker.m.daocloud.io/library/redis:7-alpine`，解析摘要为 `sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe`。

本次没有使用 `kata-hygon-csv2` RuntimeClass，也没有从 HAG 读取 CSV guest 状态；因此结果只适用于普通 Kata 容器启动路径。虽然记录了宿主机内核版本，但没有在 Pod 内核验 guest kernel 版本。

## 工作负载与结果

Pod 在容器内启动 Redis server（关闭持久化，数据目录使用 `/tmp`），执行 `redis-cli ping`，然后关闭 Redis。Kubernetes Pod 使用 `kata-qemu`，最终 `phase=Succeeded`、容器 `exitCode=0`，实际命令输出为：

```text
PONG
```

测试完成后已删除 Pod，并确认该 Pod 不再存在。原始 Expect 记录：

- 成功运行：`/tmp/hygon-redis-kata-smoke-mirror.log`
- 首次镜像拉取失败：`/tmp/hygon-redis-kata-smoke.log`

## 失败尝试与解释

首次使用 `docker.io/library/redis:7-alpine` 时，节点连接 `registry-1.docker.io` 多次被重置，Pod 进入 `ImagePullBackOff`。当时 Kata VM/Redis 工作负载尚未启动，所以该失败是镜像拉取链路失败，不能归因于 Kata。清理失败 Pod 后，使用 Docker 镜像镜像源启动了新的测试 Pod；新尝试通过 Redis `PING` 并正常退出。

## 结论与边界

本次实测表明，hygon-1 当前 Kubernetes 集群能够通过普通 `kata-qemu` RuntimeClass 启动 Redis 容器并运行其服务端/客户端命令。它没有验证 `kata-hygon-csv2`、CSV2 内存加密、guest kernel 身份、cgroups v2，也没有构成性能对照数据。Docker Hub 直连失败说明该环境的镜像源可达性应作为部署前置条件单独处理。
