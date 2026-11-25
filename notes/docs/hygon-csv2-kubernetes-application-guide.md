# Hygon CSV2 + Kata Containers 应用部署手册

本文说明如何在已部署 Hygon CSV2 Kata 的 Kubernetes 集群里，让指定 Pod 通过 CSV2 专用 Kata Runtime 启动。应用只需在 Pod spec 选择 `kata-hygon-csv2`；主机内核、KVM、containerd、Nydus 和 Kata 安装由集群管理员预先完成。

本手册适用于当前 hygon-1 验证栈，不表示它可直接复制到其他发行版、Hygon 主机或 Kubernetes/containerd 版本。安装包和主机前置条件见[离线部署包说明](hygon-csv2-offline-kit.md)及[既有部署验收记录](hygon-kata-csv2-deployment.md)。

本手册和 Redis smoke 清单是本次新增的源码树文件；此前构建的 `hygon-csv2-k8s-support.tar.zst` 尚未重新打包包含它们。

## 当前验证结论

2026-11-25 03:04:37–03:06:22 UTC 在 hygon-1 上用 Kubernetes 实际启动了 Redis Pod：RuntimeClass 为 `kata-hygon-csv2`，Redis 执行 `PING` 返回 `PONG`，Pod `Succeeded`，容器退出码为 0。Pod UID 为 `d82ac88d-17c5-4b8e-b720-ab0c5ca55c8b`，镜像为 `docker.m.daocloud.io/library/redis@sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe`。测试 Pod 已删除，且对应 QEMU sandbox 进程已退出。

本次运行期间实际 QEMU 命令使用 `/opt/kata-hygon/bin/qemu-system-x86_64`、CSV OVMF、`confidential-guest-support=sev` 和 `sev-guest ... policy=7`；其配置启用 `confidential_guest=true`、`csv_guest_policy=7`。这证明本次 Kubernetes 工作负载确实走到了已配置的 CSV2 Kata/QEMU 启动路径。验证日志在 `/tmp/hygon-redis-csv2-smoke.log`。

本次实际读取的安装组件身份：

| 组件 | SHA-256 |
| --- | --- |
| CSV2 Kata 配置 | `246b8c2493d4a699c0e888fbb65fb302fef2aed95e7f9a87545fb214dfd79565` |
| Hygon QEMU | `695088f3c473c96cab59437b9e77af170f3b81a0e71bb987b970c151a720f550` |
| Kata shim | `4d24ff006c7b8de1518b4931391f38545cff6004ea99920e847328b42399cf68` |
| guest kernel | `616fbd10958f60538a96ba79dded332576383d6a3cc250a79e1f4e6e2b5cc4d9` |
| guest initrd | `14a5c86377268e2fd2b969905548a2b85fa4d7336114c81d4a947c93f51af4a8` |
| CSV OVMF | `627dd1af8d4ce67899b3d3b73f4a32e4c0d76c6006cc12b14f04c6704f032f83` |

仍有一项平台侧证据缺口：本次主机上 `hag csv platform_status` 返回 `sudo: hag: command not found`，且没有找到 HAG RPM/服务。因此，本次**没有独立读取运行期间 `guest_count > 0` 以及清理后归零**，也没有做远程证明验收。应用运行结果通过；HAG guest 计数子项为 `runtime-unverified`。要完成平台侧复核，管理员需先按海光平台交付方式安装 HAG 工具，再按下文命令检查。

## 部署前提

集群管理员先确认：

- 节点是启用 CSV2 的 Hygon 主机，主机内核、KVM 和启动参数按平台要求开启内存加密/CSV。
- Kata Hygon CSV 包已安装在 `/opt/kata-hygon`，containerd 已加载 `io.containerd.kata-hygon.v2` handler。
- containerd 的 `kata-hygon-csv2` handler 指向 `/opt/kata-hygon/share/defaults/kata-containers/configuration-qemu-csv2.toml`，并使用配置要求的 Nydus snapshotter。
- 配置中的 `confidential_guest=true` 和 `csv_guest_policy=7` 与目标策略一致；节点具备可用的 CNI、镜像源/凭据和 Nydus 服务。
- Kubernetes 节点 Ready，RuntimeClass 已创建。hygon-1 当前为 Kubernetes `v1.35.10`、containerd `v2.3.6`、cgroup v1；kubelet 设置 `failCgroupV1: false`。其他版本需要单独验证。

在集群管理员终端检查：

```sh
kubectl get nodes -o wide
kubectl get runtimeclass kata-hygon-csv2 -o yaml
```

`RuntimeClass` 的 handler 应为 `kata-hygon-csv2`。不要把普通 `kata`/`kata-qemu` RuntimeClass 当作 CSV2，也不要修改普通 Kata 或 runc handler 来“代替”CSV2 专用 handler。

## 用 Redis 做一次应用试跑

仓库提供了可直接用于短时验收的 [Redis CSV2 smoke Pod 清单](../../artifacts/kata-hygon-1/csv/redis-csv2-smoke.yaml)。它指定 CSV2 RuntimeClass，启动 Redis、执行 `redis-cli ping`，等待 90 秒后关闭；适合确认基本容器启动和 Redis 命令，不是长期服务配置。

```sh
kubectl apply -f redis-csv2-smoke.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/redis-csv2-smoke --timeout=180s
kubectl get pod redis-csv2-smoke -o wide
kubectl logs redis-csv2-smoke
expect tools/testing/expect/run-kata-k8s-pod-smoke.exp hygon-1 redis-csv2-smoke kata-hygon-csv2 PONG /tmp/hygon-redis-csv2-smoke.log
```

期望输出是 `PONG`，Pod 为 `Succeeded` 且容器退出码为 0。`Running`/`Ready` 单独不足以说明应用工作正常。清理：

```sh
kubectl delete -f redis-csv2-smoke.yaml
```

当前 smoke 清单使用已验证镜像的固定 digest。更换成应用方自己的镜像时，应使用目标集群可访问的 registry 地址和凭据；首次部署可用 `imagePullPolicy: Always` 验证拉取链路。此次 Redis 试跑使用 `IfNotPresent`，所以它验证了 CSV2 Kata 下 Redis 的启动和实际 PING，但**没有单独验收冷缓存镜像拉取**。此前 Ubuntu 镜像的 CSV2 guest-pull 记录见部署验收文档。

## 长期应用的 Pod/Deployment 配置

把 `runtimeClassName: kata-hygon-csv2` 放在 Pod spec（Deployment 中是 `spec.template.spec`）。下面是 Redis Deployment 与 ClusterIP Service 示例；把镜像替换成应用方自己的、架构匹配且集群可拉取的镜像：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-csv2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-csv2
  template:
    metadata:
      labels:
        app: redis-csv2
    spec:
      runtimeClassName: kata-hygon-csv2
      automountServiceAccountToken: false
      containers:
        - name: redis
          image: docker.m.daocloud.io/library/redis@sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe
          imagePullPolicy: IfNotPresent
          args: ["--save", "", "--appendonly", "no"]
          ports:
            - name: redis
              containerPort: 6379
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            periodSeconds: 5
            timeoutSeconds: 2
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis-csv2
spec:
  selector:
    app: redis-csv2
  ports:
    - name: redis
      port: 6379
      targetPort: redis
```

保存为 `redis-csv2.yaml` 后部署并对应用做真实请求：

```sh
kubectl apply -f redis-csv2.yaml
kubectl rollout status deployment/redis-csv2 --timeout=180s
kubectl get pods -l app=redis-csv2 -o wide
kubectl exec deployment/redis-csv2 -- redis-cli ping
kubectl get service redis-csv2
```

`kubectl exec` 应返回 `PONG`。集群内其他应用可通过 `redis-csv2:6379` 访问；若业务依赖跨 Pod 网络，应另用真实客户端 Pod 做端到端请求验收。本次 CSV2 Redis smoke 只在 Redis Pod 内执行 localhost PING，没有验证该 Service 的跨 Pod 访问。若客户端本身也需要 CSV2 隔离，客户端 Pod 也必须设置 `runtimeClassName: kata-hygon-csv2`。删除示例应用：

```sh
kubectl delete -f redis-csv2.yaml
```

业务数据需要持久化时，为应用配置适配当前 CSV2 guest 的卷和存储方案；不要把示例中的无持久化参数直接用于生产 Redis，也不要假设普通容器的 hostPath、设备直通或存储加密设置会自动适用于机密 Guest。

## 管理员侧确认 CSV guest 状态

在 Pod 正在运行时，平台管理员可运行 HAG 提供的状态命令，要求 `guest_count` 非零；删除 Pod 后再次查询，要求回到 0：

```sh
sudo hag csv platform_status
```

如果系统提示找不到 `hag`，不要把 RuntimeClass 或 Pod 的 `Running` 状态当成 CSV guest 计数证明；应先安装/定位平台提供的 HAG 工具。当前 hygon-1 就处于此情况。本手册没有声称完成 HAG 计数验收或远程证明。

## 常见故障定位

- `ImagePullBackOff`：检查 registry DNS/连通性、镜像 digest、拉取凭据，以及 Nydus proxy snapshotter 的配置；普通 runc 能拉镜像不代表 CSV2 handler 的镜像路径一定正常。
- `FailedCreatePodSandbox` 或 Kata shim/QEMU 启动失败：确认 Pod 选择了 `kata-hygon-csv2`，containerd handler、CSV2 配置路径、Nydus 服务和 `/opt/kata-hygon` 文件均与安装包匹配。
- Pod 成功但业务请求失败：检查容器日志、readiness/liveness probe、Service selector、CNI/DNS 和应用自身监听地址。
- 需要判断是否启动了加密 guest：对照运行时 QEMU 参数及 `csv_guest_policy=7` 配置，并由平台管理员使用 HAG 检查；不要仅凭容器状态推断。

CSV2 Kata 只提供 Guest 隔离/内存加密启动路径；本次结果不证明 guest kernel/initrd 测量、远程证明、AA/CDH/KBS 机密镜像拉取或应用数据盘加密已配置完成。安装包与本手册描述的组件哈希应以离线包 manifest 和目标主机实际文件为准。
