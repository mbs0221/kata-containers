# hygon-1：Kubernetes 上的 Kata/CSV2 guest-pull 验收

状态：2026-11-23 已通过一次真实工作负载；**不是性能结果，也不是固件/镜像远程证明通过**。Kata 源码提交为 `d5c5c27a4877e3319543abfff303c0b4b6bebc11`（`codex/hygon-csv-3.13`）。与此提交对应的固定包是 `build/kata-hygon-csv.tar.zst`，SHA-256 `9a44609dbe7ea79228f49232d64bac815f83c47f592750b6d2cdb9ae27526c82`。此前的包 SHA-256 为 `b7b098e1481ffa01a877ebe3b3e991a332252863377666e23ffc8314930ecd70`，不含最终 guest pause bundle，不应再用于部署。

## 运行环境与验收结果

主机：hygon-1，AliOS 7.2，host kernel `5.10.134-hygon-csv`。引导参数包含 `amd_iommu=on mem_encrypt=on kvm_amd.sev=1 kvm_amd.sev_es=1`；未设置 `csv_mem_percentage=50`。HAG 报告 `csv2 guest: 15`（平台能力）、实验前后 `guest_count: 0`。Kubernetes `v1.35.10`、containerd `v2.3.6`、cgroup v1；`/var/lib/kubelet/config.yaml` 显式设置 `failCgroupV1: false`。Node 为 Ready。

`kata-hygon-csv2` RuntimeClass 使用独立 `/opt/kata-hygon` 前缀、QEMU/OVMF/guest kernel、`csv_guest_policy=7`、`shared_fs=none`、Nydus proxy snapshotter。官方普通 `kata` handler 与 runc 均未改为这套 QEMU。测试 Pod UID `c53f045c-841a-44c0-bd97-d55eb84d42b0`，Ubuntu 镜像 `docker.m.daocloud.io/library/ubuntu@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289`。Pod 内真实输出：

```text
CSV_WORKLOAD_OK
5.10.134-hygon-csv
CSV_WORKLOAD_DONE
```

容器 `exitCode=0`、`reason=Completed`；运行期间 HAG `guest_count=1`，结束及删 Pod 后 `guest_count=0`。原始证据是 `artifacts/kata-hygon-1/csv/kata-hygon-csv2-current-workload.log`（SHA-256 `c88181af45bc07ab2ca98b8a0b3209d42f89f583b0935b0a10e2760a6a104244`）、`kata-hygon-csv2-current-pod.json`（`42bb03b07563bf28b45643e73c8c6abc9ff4df8679c138a0ba84b602033779ed`）和 `kata-hygon-csv2-current-hag-after.log`（`44ac94d475d867d16d36af29bce22706819946ae0d9b36dc0903be92ae6e677d`）。`guest_count=1` 证明运行中有 CSV guest；CSV2 路线另由 RuntimeClass 对应的 policy 7 配置与平台能力确认，未获取独立的单 guest CSV2 证明报告。

## 组成与可复用配置

| 组件 | 来源/身份 | 安装时 SHA-256 |
| --- | --- | --- |
| Hygon QEMU | `https://gitee.com/anolis/hygon-qemu.git`，提交 `21dd215a48e4d98690f550bbda40615129579361` | `695088f3c473c96cab59437b9e77af170f3b81a0e71bb987b970c151a720f550` |
| OVMF `OVMF_CODE.cc.fd` | OpenAnolis edk2 RPM，签名已验证 | `627dd1af8d4ce67899b3d3b73f4a32e4c0d76c6006cc12b14f04c6704f032f83` |
| guest kernel | 本机 `/boot/vmlinuz-5.10.134-hygon-csv`；源码提交未知 | `616fbd10958f60538a96ba79dded332576383d6a3cc250a79e1f4e6e2b5cc4d9` |
| Kata Go shim | 本分支源码构建 | `4d24ff006c7b8de1518b4931391f38545cff6004ea99920e847328b42399cf68` |
| guest initrd | Alpine 3.19、同版本内核模块、agent、pause 3.9 OCI bundle；Kata 原生脚本构建 | `14a5c86377268e2fd2b969905548a2b85fa4d7336114c81d4a947c93f51af4a8` |
| Nydus snapshotter | v0.16.1 release | `d03b6b288e576fb5a65358b4f9b51ca8e867eeeb92d89a6c0f68659bf52cc7e6` |
| Nydus overlay helper | 同一 release | `a08489f69f8cfb27782e2a83dd97d5685c3bc421d92d378ac6c523bfb16d3280` |

目标配置已保存于 `artifacts/kata-hygon-1/csv/`：`containerd.toml.hygon`、`nydus-proxy.toml`、`containerd-nydus.service`、`kata-k8s-cni-forward.service`、`runtimeclass.yaml`、`pod.yaml`。Nydus 仅分配给 `kata-hygon-csv2` handler；普通容器和官方 Kata 仍使用原 snapshotter。`containerd.toml.hygon` 安装 SHA-256 为 `6bf414e73505976f5d40392b19c92929e9e7f40f6101ada814c659c81b677dc5`。

主机原 yum 源不可用，另安装签名验证通过的 Anolis 7 `fuse-2.9.2-11.an7.x86_64.rpm`（SHA-256 `74cdb645e81d6fbd063d6d475978d2e7d410f038c3d8a63b609a9ea22078db77`），以提供 `mount.fuse`。Hygon CNI 原有 `FORWARD DROP` 且无 `cni0` 放行，连普通 runc Pod 的 DNS 都超时。加入 `cni0` 出站和已建立连接返回两条规则后，普通 Pod DNS 成功，CSV2 guest-pull 工作负载通过。用户已批准把相同规则置于 `kata-k8s-cni-forward.service`；服务已启用且运行。**未重启主机验证重启持久性**。

## 已知边界

- 安装的 OVMF 无可用 firmware hashes table；Kata Hygon shim 中的 `kernel-hashes=on` 会令 QEMU 在启动前失败，因此本版移除该选项。CSV 内存加密与工作负载已实测，但不能据此宣称 kernel/initrd 测量或远程证明完整。
- guest kernel 来自主机现成二进制，源码提交不可追溯；暂不能将本次结果称为源码全链可复现。
- initrd 中的 agent 支持 guest-pull，但没有完成 AA/CDH/KBS 机密镜像拉取和证明验收；本次使用公开 Ubuntu 镜像。
- 这是一次功能验收，未做普通 Kata 对照、统计重复或性能测量。FUSE/CNI 依赖、镜像代理和 HAG 状态必须纳入后续实验元数据。
- 固件校验、独立 CSV2 guest 证明、重启后的服务/网络恢复和普通 Kata 路线回归仍待单独验收。
