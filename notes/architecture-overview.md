# Kata Containers 架构概述

## 1. 项目定位

Kata Containers 是一个开源项目，旨在构建轻量级虚拟机（VMs）的标准实现，提供容器般的体验和性能，同时具备 VM 的工作负载隔离和安全性优势。

### 核心价值

- **安全性**: 使用硬件虚拟化技术提供第二层隔离
- **兼容性**: 兼容 OCI 运行时规范和 Kubernetes CRI
- **性能**: 优化的启动时间和资源开销
- **灵活性**: 支持多种 hypervisor 和架构

## 2. 系统架构

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Container Manager                         │
│              (containerd / CRI-O / Kubelet)                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       │ OCI Runtime Spec / CRI
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    Kata Runtime                              │
│              (containerd-shim-kata-v2)                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  virtcontainers (Go) / runtime-rs (Rust)              │   │
│  │  - Sandbox 管理                                        │   │
│  │  - Container 管理                                      │   │
│  │  - 资源管理                                            │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       │ Hypervisor API
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    Hypervisor / VMM                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  QEMU    │  │ Cloud    │  │Dragonball│  │Firecracker│   │
│  │          │  │Hypervisor│  │          │  │          │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       │ KVM / Hardware Virtualization
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    Guest VM                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Guest Kernel                                         │   │
│  │  ┌────────────────────────────────────────────────┐  │   │
│  │  │  Agent (kata-agent)                           │  │   │
│  │  │  - Container 生命周期管理                       │  │   │
│  │  │  - 设备管理                                    │  │   │
│  │  │  - 存储管理                                    │  │   │
│  │  │  - 网络管理                                    │  │   │
│  │  └────────────────────────────────────────────────┘  │   │
│  │  ┌────────────────────────────────────────────────┐  │   │
│  │  │  Container(s)                                  │  │   │
│  │  │  - Namespaces                                  │  │   │
│  │  │  - Cgroups                                     │  │   │
│  │  │  - Workload                                    │  │   │
│  │  └────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 环境层次

Kata Containers 定义了三个主要环境层次：

| 环境类型 | 名称 | 虚拟化 | 容器化 | rootfs | 描述 |
|---------|------|--------|--------|--------|------|
| Host | Host | 否 | 否 | Host 特定 | 物理或虚拟化主机环境 |
| VM root | Guest VM | 是 | 否 | Guest Image | VM 的根环境，包含 guest kernel |
| VM container root | Container | 是 | 是 | Container Image | 容器环境，基于 OCI bundle |

### 2.3 通信架构

#### Shim v2 架构

Kata Containers 使用 containerd shim v2 架构：

- **单进程模型**: 一个 shim 进程管理多个容器
- **gRPC 通信**: 通过 Unix socket 进行双向通信
- **Pod 支持**: 一个 VM 可以运行多个容器（Kubernetes Pod）

#### Runtime-Agent 通信

- **协议**: ttRPC（基于 gRPC 的轻量级协议）
- **传输**: VSOCK 或 virtio-serial
- **功能**:
  - 容器生命周期管理命令
  - 标准 I/O 流传输（stdout/stderr/stdin）
  - 设备管理
  - 存储和网络配置

## 3. 核心组件

### 3.1 Runtime（运行时）

**位置**: `src/runtime/` (Go) 或 `src/runtime-rs/` (Rust)

**职责**:
- 实现 OCI runtime 规范和 containerd shim v2 API
- 管理 Sandbox 和 Container 生命周期
- 启动和管理 Hypervisor
- 与 Agent 通信

**关键模块**:
- `virtcontainers`: 虚拟容器核心库（Go）
- `hypervisors`: Hypervisor 抽象层
- `containerd-shim-v2`: Shim v2 实现

### 3.2 Agent（代理）

**位置**: `src/agent/`

**语言**: Rust

**职责**:
- 运行在 guest VM 内部
- 管理容器生命周期
- 处理 Runtime 的 RPC 请求
- 管理设备、存储、网络

**关键模块**:
- `rpc.rs`: RPC 服务器实现
- `sandbox.rs`: Sandbox 管理
- `device/`: 设备管理
- `storage/`: 存储管理
- `network.rs`: 网络管理

### 3.3 Hypervisor / VMM

Kata Containers 支持多种虚拟化管理器：

#### QEMU
- **特点**: 功能完整，兼容性好
- **设备**: virtio-net, virtio-blk, virtio-fs, VFIO
- **特性**: 热插拔、DAX (NVDIMM)

#### Cloud Hypervisor
- **特点**: 轻量级，专为云工作负载优化
- **设备**: virtio-net, virtio-blk, virtio-fs, virtio-pmem
- **特性**: 热插拔、VFIO、seccomp 过滤器

#### Dragonball
- **特点**: Kata 3.0 内置 VMM，开箱即用
- **语言**: Rust
- **特性**: 容器工作负载优化、快速启动

#### Firecracker
- **特点**: 极轻量级，适合 FaaS
- **限制**: 不支持文件系统共享、VFIO、热插拔

### 3.4 Dragonball VMM（详细）

**位置**: `src/dragonball/`

**架构**:
```
Vmm (全局协调器)
  ├── Vm (虚拟机实例)
  │   ├── AddressSpaceMgr (地址空间管理)
  │   ├── DeviceManager (设备管理)
  │   ├── VcpuManager (VCPU 管理)
  │   └── ResourceManager (资源管理)
  ├── EventManager (事件管理)
  └── API Server (API 接口)
```

**核心模块**:
- `dbs_virtio_devices`: Virtio 设备实现
- `dbs_arch`: 架构相关代码（x86_64, aarch64）
- `dbs_device`: 设备抽象层
- `dbs_vcpu`: VCPU 管理
- `dbs_boot`: 启动相关
- `dbs_interrupt`: 中断管理
- `dbs_pci`: PCI 设备管理

## 4. 容器创建流程

### 4.1 创建步骤

1. **用户请求**: Container Manager 调用 OCI runtime
2. **Runtime 启动**: 创建 shim 进程（如果不存在）
3. **配置加载**: Runtime 加载配置文件
4. **Sandbox 创建**:
   - Runtime 调用 `CreateSandbox`
   - 启动 Hypervisor
   - Hypervisor 创建并启动 VM
   - Guest Image 通过 DAX 映射到 VM
   - OCI bundle 通过 virtio-fs 挂载到 VM
5. **Agent 启动**: Agent 作为 VM 启动的一部分启动
6. **Container 创建**:
   - Runtime 调用 Agent 的 `CreateSandbox` API
   - Agent 创建容器环境（namespaces, cgroups）
   - Agent 启动 workload 进程
7. **Container 启动**:
   - Runtime 调用 Agent 的 `StartContainer` API
   - Workload 开始运行

### 4.2 关键机制

#### DAX (Direct Access)

- **目的**: 高效地将 guest image 映射到 VM
- **实现**: 
  - QEMU: NVDIMM 设备
  - Cloud Hypervisor: PMEM 设备
- **优势**: 
  - 零拷贝访问
  - 按需加载（page fault）
  - 共享内存页

#### Virtio FS

- **目的**: 在 Host 和 Guest 之间共享文件系统
- **用途**: 挂载 OCI bundle（容器 rootfs）
- **优势**: 高性能文件系统共享

## 5. 存储架构

### 5.1 存储层次

1. **Guest Image**: VM 的 rootfs，通过 DAX 映射
2. **Container Rootfs**: 容器镜像，通过 virtio-fs 挂载
3. **Volumes**: 持久化存储卷，通过 virtio-blk 或 virtio-scsi

### 5.2 存储设备类型

- **virtio-blk**: 块设备
- **virtio-scsi**: SCSI 设备（支持更多特性）
- **virtio-fs**: 文件系统共享
- **virtio-9p**: 传统文件系统共享（不推荐）

## 6. 网络架构

### 6.1 网络模型

- **CNI 集成**: 支持标准 CNI 插件
- **网络命名空间**: 每个 Sandbox 有独立的网络命名空间
- **设备类型**: virtio-net, vhost-net, vhost-user-net

### 6.2 网络配置流程

1. Container Manager 配置网络
2. Runtime 在 Host 网络命名空间中配置
3. Hypervisor 创建 virtio-net 设备
4. Agent 在 Guest 中配置网络接口

## 7. 安全特性

### 7.1 隔离层次

1. **硬件虚拟化**: VM 级别的隔离
2. **容器隔离**: Namespaces 和 Cgroups
3. **Seccomp**: 系统调用过滤
4. **SELinux**: 强制访问控制（可选）

### 7.2 安全机制

- **最小权限**: 只使用必要的系统调用
- **进程隔离**: 每个 VM 运行在独立进程
- **资源限制**: Cgroups 限制资源使用
- **策略引擎**: OPA (Open Policy Agent) 支持

## 8. 性能优化

### 8.1 启动优化

- **VM 模板**: 预创建模板 VM，快速克隆
- **最小资源**: VM 以最小资源启动，按需热插拔
- **并发启动**: 支持多个 VM 并发启动

### 8.2 运行时优化

- **大页内存**: 支持 hugetlbfs
- **CPU 固定**: 支持 CPU 亲和性
- **设备优化**: 使用高性能 virtio 设备

## 9. 兼容性

### 9.1 标准兼容

- **OCI Runtime Spec**: 完全兼容
- **Kubernetes CRI**: 通过 containerd/CRI-O 支持
- **容器镜像**: 支持标准容器镜像格式

### 9.2 平台支持

| 架构 | 虚拟化技术 |
|------|-----------|
| x86_64 | Intel VT-x, AMD SVM |
| aarch64 | ARM Hyp |
| ppc64le | IBM Power |
| s390x | IBM Z & LinuxONE SIE |

## 10. 架构演进

### Kata 1.x → 2.x

- **Shim v2**: 从多进程模型迁移到单进程模型
- **移除 Proxy**: VSOCK 直接通信，不再需要独立的 proxy 进程

### Kata 2.x → 3.0

- **Runtime-rs**: Rust 版本的运行时（开发中）
- **Dragonball**: 内置 VMM，开箱即用
- **架构优化**: 异步 I/O，更好的资源管理

## 11. 关键设计决策

### 11.1 为什么使用 VM？

- **安全性**: 硬件级别的隔离
- **兼容性**: 无需修改应用代码
- **隔离性**: 比容器更强的隔离

### 11.2 为什么需要 Agent？

- **隔离**: Runtime 无法直接访问 Guest 内部
- **管理**: 需要进程管理容器生命周期
- **抽象**: 提供统一的容器管理接口

### 11.3 为什么支持多种 Hypervisor？

- **灵活性**: 不同场景需要不同的 VMM
- **性能**: 不同 VMM 有不同的性能特征
- **兼容性**: 支持不同的部署环境

## 12. 待深入研究的问题

1. **VCPU 调度**: VCPU 线程如何与 KVM 交互？调度策略是什么？
2. **中断处理**: 中断如何从设备传递到 Guest？GIC 如何工作？
3. **内存管理**: Guest 内存如何映射到 Host？大页内存如何管理？
4. **设备 I/O**: Virtio 设备的 I/O 请求如何从 Guest 传递到 Host？
5. **热插拔**: CPU 和设备热插拔的具体实现机制？
6. **迁移机制**: VM 模板和实时迁移的实现细节？

## 参考资料

- [Kata Containers Architecture](../docs/design/architecture/README.md)
- [Virtualization in Kata Containers](../docs/design/virtualization.md)
- [Kata Containers 3.0 Architecture](../docs/design/architecture_3.0/)

