# Hygon CSV2 Kata 部署包

## 用途与验证基线

本套介质用于在已具备 Hygon CSV2 主机能力的 Linux/Kubernetes 节点上部署 Kata CSV2 RuntimeClass，并启动 guest-pull 容器。它不是主机系统镜像，也不会替代主机固件、CSV-capable host kernel、Kubernetes 或 containerd。

本次 CSV2 工作负载在 `hygon-1` 上完成过一次真实验收：Kubernetes `v1.35.10`、`failCgroupV1: false`、containerd `v2.3.6`，Pod 输出 `CSV_WORKLOAD_OK` 与 `CSV_WORKLOAD_DONE`、退出码为 0。验收使用 Kata 源码提交 `d5c5c27a4877e3319543abfff303c0b4b6bebc11`，对应 Kata tar 包 SHA-256 为 `9a44609dbe7ea79228f49232d64bac815f83c47f592750b6d2cdb9ae27526c82`。详见 [CSV2 部署验收记录](hygon-kata-csv2-deployment.md)。

主要交付是带 Hygon CSV2 补丁的 Kata Containers。补丁加入 Hygon CPU/CSV guest 识别、CSV2 confidential guest 配置和 policy 7、Hygon QEMU/OVMF 与专用 guest kernel/initrd 选择、Kata agent/pause 组件装配，以及面向真实 Kubernetes guest-pull 工作负载的构建和运行修复。源代码在 `codex/hygon-csv-3.13` 分支；实际构建包对应提交 `d5c5c27a`。其余文件用于 K8s/containerd 配置与 Nydus guest-pull。

## 交付文件

| 文件 | 内容 |
| --- | --- |
| `kata-hygon-csv.tar.zst` | Kata Hygon runtime、QEMU、OVMF CSV 固件、guest kernel `5.10.134-hygon-csv`、guest initrd、CSV2 配置和运行所需文件。解包后安装前缀为 `/opt/kata-hygon`。 |
| `hygon-csv2-k8s-support.tar.zst` | Nydus snapshotter 二进制包、containerd/Nydus 配置、systemd 单元、Kubernetes/cgroup-v1 配置样例、RuntimeClass/Pod 清单、stack manifest、校验清单和本说明。 |
| `hygon-csv2-deployment.qcow2` | 本地生成的 ext4 QCOW2 数据盘，包含两个 tar、校验文件和技术文档。它可挂载读取，不是可独立启动的主机系统镜像。 |

两个 tar、技术文档与 `SHA256SUMS` 放在 `build/hygon-csv2-package/release/`。安装前先进入该目录并执行 `sha256sum -c SHA256SUMS`。QCOW2 不纳入 GitHub Release；其校验值单独保存在包目录旁的 `hygon-csv2-deployment.qcow2.sha256`。

## 主机前置条件

- Hygon C86 CSV2 物理机；BIOS/固件已启用硬件虚拟化和内存加密。
- 主机运行支持 CSV 的 Hygon Linux 内核，KVM 模块已启用相应 SEV/CSV 能力。已验收主机为 AliOS 7.2，内核 `5.10.134-hygon-csv`，启动参数含 `amd_iommu=on mem_encrypt=on kvm_amd.sev=1 kvm_amd.sev_es=1`。
- Kubernetes `v1.35.10`、containerd `v2.3.6`；cgroup v1 节点需在 kubelet 配置中设置 `failCgroupV1: false`。其他版本需单独验证。
- Nydus proxy snapshotter、CNI 网络和 `mount.fuse` 等主机依赖已安装配置。已验收环境使用 Nydus `v0.16.1` 和 Anolis `fuse-2.9.2-11.an7.x86_64` RPM。
- 本套部署包没有包含 Kubernetes、containerd、CNI、主机内核/内核 RPM、`fuse` RPM 或主机 OS 安装镜像。这些软件在原验收环境已单独安装，但其原始安装包未留在当前仓库构建目录中；因此本包不能单独安装出一台完整主机。主机必须先满足以上前置条件；包内 guest kernel 是 Kata CSV guest 内核，不能代替主机内核。

## 安装步骤

以下假设两个 tar 和校验文件已放在同一目录。先校验并解包：

```sh
sha256sum -c SHA256SUMS
sudo tar --use-compress-program=unzstd -xf kata-hygon-csv.tar.zst -C /
mkdir -p support
tar --use-compress-program=unzstd -xf hygon-csv2-k8s-support.tar.zst -C support
```

Kata tar 已带 `/opt/kata-hygon/bin/containerd-nydus-grpc`、`nydus-overlayfs`、QEMU、OVMF 和 CSV guest kernel/initrd。support tar 内的 `packages/nydus-snapshotter.tar.gz` 保存配套 Nydus 发布二进制；按目标主机既有目录布局安装，并确认服务执行路径指向 `/opt/kata-hygon/bin/containerd-nydus-grpc`。`support/kubernetes/` 保存 Hygon-1 的 kubeadm/cgroup-v1 与普通 Kata 配置样例；其中 IP、路径和 CNI 配置都是主机相关值，部署前要改成目标节点环境。

把 `support/config/containerd.toml.hygon` 中 `kata-hygon-csv2`、Nydus snapshotter 和 CNI 相关段落合并进目标节点的 containerd 配置。该文件来自验收主机，含 `/opt/kubernetes/bin/runc-v1.3.7`、socket、state 路径等环境路径；不要不加检查地覆盖另一台主机的完整配置。安装 `support/config/nydus-proxy.toml` 和两个 `support/systemd/` 单元前，也应按本机的 containerd 服务名、CNI 与防火墙策略检查路径及顺序。

配置 containerd 并重启后，创建 `support/kubernetes/runtimeclass.yaml`，再按需使用 `pod.yaml` 做 guest-pull 功能验收。CSV2 RuntimeClass 指向 `/opt/kata-hygon/share/defaults/kata-containers/configuration-qemu-csv2.toml`，guest policy 为 7。容器镜像、镜像代理和 Nydus 配置应按部署环境调整。

验收时检查实际容器输出和退出码，并确认 HAG 在 guest 运行时报告非零 `guest_count`、结束后回到 0。Kubernetes Pod 显示 `Running` 或 `Succeeded` 本身不足以证明 CSV2 工作负载成功。

## 可复现性与安全边界

- 包内 `csv-stack-manifest.txt` 记录 Kata、QEMU、OVMF、guest kernel/initrd 的来源和 SHA-256。guest kernel 的源码提交未知；发布前应确认目标主机允许使用该二进制。
- 当前 OVMF 不提供可用的 firmware hashes table，因此验收配置关闭 `kernel-hashes`。本次功能验收不代表固件测量、远程证明、AA/CDH/KBS 机密镜像拉取通过。
- 包内配置与 Hygon-1 环境绑定，特别是 CNI 转发 systemd 单元会修改 FORWARD 规则。应按目标节点策略审阅后再启用。
- 已记录的普通 Kata 对照运行使用另一套 guest kernel、QEMU、rootfs 和共享方式；不属于性能对比结果。
- 本次安装包整理没有重新启动容器或 VM；安装包可读性、文件清单和哈希可校验，目标节点部署仍需按上述运行验收步骤验证。
- QCOW2 使用 ext4 文件系统承载安装介质，需作为数据盘挂载读取；不含主机引导分区或 CSV-capable host kernel，不能直接作为启动盘。
- GitHub Release 交付包和文档，不上传 QCOW2 数据盘。
