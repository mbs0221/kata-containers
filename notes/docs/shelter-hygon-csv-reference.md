# Shelter 海光 CSV 配置参考（用于 hygon-1 启动链排查）

核对日期：2026-11-22；以下过程记录保留当时的基线和判断，不作为当前状态。**2026-11-23 更新：** hygon-1 已完成真实 CSV2 RuntimeClass Pod 的 guest-pull 验收：Ubuntu 工作负载输出 `CSV_WORKLOAD_OK`、guest 内核版本及 `CSV_WORKLOAD_DONE`，退出码 0，运行时 HAG `guest_count=1`，清理后为 0。完整身份、原始证据与尚未解决的固件测量问题见 [hygon-1 Kata/CSV2 部署记录](hygon-kata-csv2-deployment.md)。本文件主要说明此前如何核对 Shelter 参考实现；后文“当前”“下一阶段”等词均指 2026-11-22 的历史诊断时点。

## 固定来源

用户给出的 Hygon C86 7365 `/proc/cpuinfo` 示例逐项见 [Shelter 的 HYGON.md](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/docs/HYGON.md)。这是 `inclavare-containers/Shelter`（Application Trust Sandboxing）项目的示例输出，不是对当前 hygon-1 机器的独立检测。仓库 `main` 在核对时为 `1696099539380e1451d2fdd9ab06c712f67f052a`；README 推荐的 `0.1.0` tag 为 `2b4e349ddff92482e96735a1f2c419075df0f341`。此处引用固定提交，避免随 `main` 变化。未找到该仓库 README 指向的专门论文；以下按开源实现和 HYGON.md 核对，不臆测论文实验配置。[Shelter README](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/README.md)

## Shelter 实际配置

| 环节 | Shelter 一手证据 |
| --- | --- |
| Host 引导参数 | `amd_iommu=on csv_mem_percentage=50 kvm_amd.sev_es=1 kvm_amd.sev=1`，文档要求 `grubby` 后重启。[HYGON.md](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/docs/HYGON.md) |
| QEMU/内存/CPU | 默认配置 `bin=/usr/libexec/qemu-kvm`、`mem=4G`、`cpus=2`，`image_type=initrd`。[shelter.hygon.conf](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/shelter.hygon.conf) |
| OVMF | `shelter.hygon.conf` 指向 `/usr/share/edk2/ovmf/OVMF_CODE.cc.fd`；同一提交的 HYGON.md 写成 `OVMF_CODE.cc`（少 `.fd`），路径不一致。实际部署须检查存在的文件，而非照抄文档路径。[配置](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/shelter.hygon.conf)；[指南](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/docs/HYGON.md) |
| CSV 参数 | `-object sev-guest,id=sev0,policy=0x1,cbitpos=47,reduced-phys-bits=5 -machine q35,memory-encryption=sev0`。这是 Shelter 的示例 policy；不能无验证地宣称与当前 Kata `0x5` 等价。[配置](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/shelter.hygon.conf) |
| 引导方式 | `-accel kvm -nographic -cpu host -kernel <Shelter image/kernel> -initrd <Shelter image/initrd> -append '... console=ttyS0'`，并加 pflash 固件、virtio RNG、vsock、网卡。`shelter build` 把当前 host `/boot/vmlinuz-$(uname -r)` 复制为 guest kernel，并把对应 `/usr/lib/modules/$(uname -r)` 加进 mkosi 构建的 initrd。[Shelter 源码](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/shelter) |
| 工作负载验收 | 示例执行 `shelter run cat /proc/cpuinfo`；运行期间再用 `hag csv platform_status` 核对 CSV guest 数量。文档明确 `guest_count` 不包含普通 guest。[HYGON.md](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/docs/HYGON.md) |

## 对 hygon-1 的直接影响

当前已知 hygon-1 有 `5.10.134-hygon-csv` host kernel、`mem_encrypt=on` 与两项 `kvm_amd.sev*` 参数，HAG 已检测 CSV/CSV2 且一次失败引导中出现过 `guest_count=1`。因此现阶段缺口不是单纯打开 SEV 开关，而是 **QEMU—固件—guest kernel/initrd 的可引导组合**。Shelter 的例子没有规定 QEMU 版本或补丁提交，只写发行版路径；不能凭其参数证明现有 `/opt/kata/bin/qemu-system-x86_64` 与 `OVMFCSV.fd`/`AMDSEV.fd` 兼容。[Shelter 配置](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/shelter.hygon.conf)

此前对 hygon-1 的只读检查显示，Shelter 指定的 `/usr/libexec/qemu-kvm` 和 `/usr/share/edk2/ovmf/OVMF_CODE.cc[.fd]` 均不存在，只有 Kata 栈中的 QEMU 与 `/opt/kata/share/hygon/OVMFCSV.fd`、`/opt/kata/share/ovmf/AMDSEV.fd`。所以 **Shelter 配置不是该主机可直接运行的现成替换项**。它最有用的对照是：采用与 host 匹配的 guest kernel 加模块匹配的 initrd、明确 pflash 加载方式、使用 `-cpu host`，先执行真实 guest 命令并核对退出码，再考虑接入 Kata。`csv_mem_percentage=50` 和 `policy=0x1` 可作为待检变量，但当前 CSV2 guest 已能创建，不能将它们直接断定为引导失败根因。

进一步只读检查确认：当前 `/opt/kata/bin/qemu-system-x86_64` 为 Kata 静态构建的 QEMU 10.2.1，系统未安装 `qemu-kvm` 或 `edk2-ovmf` RPM；现有 `kata-ubuntu-20.04-confidential.initrd` 的 `lsinitrd` 列表不含 `/lib/modules`，而 host `5.10.134-hygon-csv` 的配置将 `CONFIG_VIRTIO_VSOCKETS`、`CONFIG_VIRTIO_NET` 等设为模块。这是后续 Kata agent 通道和网络的独立缺口，但它不能解释当前更早发生的 OVMF `QemuLoadKernelImage: LoadImage(): Not Found` / `No bootable option was found`。应先解决固件到内核的引导交接，再用匹配模块的 guest initrd 验收 Kata 工作负载。以上为本机只读诊断与既有失败日志，不是新一轮 VM 成功运行。

已从 [OpenAnolis 官方镜像目录](https://mirrors.openanolis.cn/anolis/8/AppStream/x86_64/os/Packages/)取得 `edk2-ovmf-20220126gitbb1bba3d77-13.0.1.an8.10.noarch.rpm`，仅保存于 hygon-1 的 `/tmp/edk2-ovmf-an8.10-inspect.rpm` 作只读检查（SHA-256 `d467b30e4acbf7d90d7da06d4138b00dd5e6398f74ee8da5eb3a098afc0f99f8`）。RPM 文件表确有 `/usr/share/edk2/ovmf/OVMF_CODE.cc.fd`，但目标系统尚未导入其 RPM 签名密钥，签名状态显示 `NOKEY`，故未安装。对应 Anolis QEMU core RPM 的 SHA-256 为 `82b772d36d82fe4be247845b561abc00f5f629837c05124407938cea33e4b2e0`；`rpm -Uvh --test` 显示目标 AliOS 缺少 `libfdt`、`libgcrypt`、`libgnutls`、`libibverbs`、`libpmem` 等多项依赖和同版本 QEMU 子包。不能将其视作可直接安装的匹配 QEMU 栈。

现有 Kata `tools/packaging/static-build/qemu` 接受 `qemu_repo`/`qemu_version`，但当前主线的 `configure-hypervisor.sh` 包含若干针对较新 QEMU 的选项，不能预设它可无修改构建海光 6.2 分支；`codex/hygon-csv-3.13` 的 `versions.yaml` 仍指向通用 QEMU `v9.1.2`、通用 EDK2 和 Linux `v6.12.8`。固定海光 QEMU/OVMF/guest kernel 来源并核对构建兼容性，是下一道源码门槛，不是已完成的 CSV2 VM 门槛。

Shelter README 展示的是 `shelter build/run/start/exec/stop` 独立命令，仓库中的 Hygon 配置是其自身 QEMU 启动器；未见其给 Kata shim、containerd CRI 或 Kubernetes RuntimeClass 的接入配置。因此它能提供 CSV VM 对照启动链，**不能替代 Kata/Kubernetes Pod 验收**。[Shelter README](https://github.com/inclavare-containers/Shelter/blob/1696099539380e1451d2fdd9ab06c712f67f052a/README.md)；[Kata 的 containerd/CRI 接入文档](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/containerd-kata.md)
