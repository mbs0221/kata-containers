# Dragonball VMM 架构分析

## 概述

Dragonball 是 Kata Containers 3.0 的内置 VMM（Virtual Machine Monitor），基于 KVM，专为容器工作负载优化。

**位置**: `src/dragonball/`  
**语言**: Rust  
**特点**: 
- 轻量级，低 CPU 和内存开销
- 快速启动时间
- 优化的并发启动速度
- 开箱即用的体验

## 架构设计

### 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                    Vmm (全局协调器)                       │
│  ┌───────────────────────────────────────────────────┐  │
│  │  API Server                                       │  │
│  │  - ConfigureBootSource                            │  │
│  │  - SetVmConfiguration                             │  │
│  │  - AddNetworkDevice                               │  │
│  │  - AddBlockDevice                                 │  │
│  │  - StartMicrovm                                  │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Event Manager (epoll)                            │  │
│  │  - API 事件                                        │  │
│  │  - 设备 I/O 事件                                   │  │
│  │  - VCPU 事件                                       │  │
│  └───────────────────────────────────────────────────┘  │
└───────────────────────┬───────────────────────────────────┘
                        │
                        │ 1:N
                        │
┌───────────────────────▼───────────────────────────────────┐
│                    Vm (虚拟机实例)                        │
│  ┌───────────────────────────────────────────────────┐  │
│  │  AddressSpaceMgr (地址空间管理)                     │  │
│  │  - Guest 内存区域管理                              │  │
│  │  - NUMA 配置                                       │  │
│  │  - 内存映射到 KVM                                  │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  DeviceManager (设备管理)                          │  │
│  │  - BlockDeviceMgr                                 │  │
│  │  - VirtioNetDeviceMgr                             │  │
│  │  - FsDeviceMgr                                    │  │
│  │  - VsockDeviceMgr                                 │  │
│  │  - ConsoleManager                                 │  │
│  │  - PciSystemManager (VFIO)                        │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  VcpuManager (VCPU 管理)                          │  │
│  │  - VCPU 创建和启动                                 │  │
│  │  - VCPU 热插拔                                     │  │
│  │  - VCPU 退出处理                                   │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  ResourceManager (资源管理)                         │  │
│  │  - MMIO 地址分配                                   │  │
│  │  - PIO 地址分配                                    │  │
│  │  - IRQ 分配                                        │  │
│  └───────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

### 对象模型

```
Vmm <-1:N-> Vm <-1:1-> AddressSpaceMgr <-1:N-> GuestMemory
  ^           ^---1:1-> DeviceManager <-1:N-> Device
  |           ^---1:1-> ResourceManager
  |           ^---1:N-> Vcpu
  |---<-1:N-> EventManager
```

## 核心模块

### 1. VMM 核心 (`src/vmm.rs`)

**职责**: 全局协调器，管理 API 服务器、虚拟机、事件循环等

**关键功能**:

- `Vmm::new()`: 创建 VMM 实例
  - 初始化 VM
  - 创建事件上下文
  - 初始化 epoll 管理器

- `Vmm::run_vmm_event_loop()`: 运行事件循环
  - 使用 epoll 进行事件管理
  - 处理 API 事件和退出事件
  - 调用 `VmmService::run_vmm_action()` 处理 VMM 操作

- `Vmm::stop()`: 优雅停止 VMM
  - 移除所有设备
  - 退出所有 vCPU 线程
  - 保存退出状态

**线程类型**:
- `ALL_THREADS`: 所有线程的 seccomp 限制
- `VMM_THREAD`: VMM 线程
- `VCPU_THREAD`: VCPU 线程

### 2. VM 管理 (`src/vm/mod.rs`)

**职责**: 虚拟机实例管理

**初始化流程** (`Vm::start_microvm()`):

1. **应用 seccomp 过滤器**（安全沙箱）
2. **检查 VM 状态**（防止重复启动）
3. **初始化 guest 内存** (`init_guest_memory()`)
   - 支持 `hugetlbfs` 和 `shmem` 两种内存类型
   - 配置 NUMA 区域
4. **初始化 VCPU 管理器** (`init_vcpu_manager()`)
5. **初始化微虚拟机** (`init_microvm()`)
   - x86_64: 初始化 TSS → 设置中断控制器 → 创建 PIT → 初始化设备
   - aarch64: 创建 VCPU → 设置 GIC → 初始化设备
   - 加载内核镜像
   - 创建启动 VCPU
6. **配置系统** (`init_configure_system()`)
7. **注册事件** (`register_events()`)
8. **启动 VCPU** (`start_boot_vcpus()`)

**关键组件**:
- `KvmContext`: KVM 操作上下文
- `AddressSpaceMgr`: 地址空间管理器
- `DeviceManager`: 设备管理器
- `VcpuManager`: VCPU 管理器
- `ResourceManager`: 资源管理器

**配置结构**:
- `VmConfigInfo`: vCPU 数量、内存大小、CPU 拓扑、vPMU 特性等
- `KernelConfigInfo`: 内核路径、initrd 路径、启动参数
- `NumaRegionInfo`: NUMA 区域配置

### 3. VCPU 管理 (`src/vcpu/`)

**职责**: 虚拟 CPU 生命周期管理

**VcpuConfig 配置**:
- `boot_vcpu_count`: 初始 vCPU 数量
- `max_vcpu_count`: 最大 vCPU 数量（支持热插拔）
- CPU 拓扑信息: threads_per_core, cores_per_die, dies_per_socket, sockets
- `vpmu_feature`: vPMU 特性级别（Disabled/LimitedlyEnabled/FullyEnabled）

**VcpuManager 功能**:
- 创建和启动 VCPU
- VCPU 热插拔支持（hotplug feature）
- VCPU 退出和清理
- 设置重置事件文件描述符

**架构特定实现**:
- `x86_64.rs`: x86_64 架构的 VCPU 实现
- `aarch64.rs`: ARM64 架构的 VCPU 实现

**VCPU 生命周期**:
1. 创建 VCPU (`create_vcpu()`)
2. 初始化 VCPU (`init_vcpu()`)
3. 启动 VCPU 线程 (`start_vcpu()`)
4. VCPU 运行循环 (`run_vcpu()`)
5. VCPU 退出处理 (`handle_vcpu_exit()`)

### 4. 设备管理 (`src/device_manager/`)

**职责**: 虚拟设备的生命周期管理

**设备管理器类型**:
- `BlockDeviceMgr`: 块设备管理（virtio-blk, vhost-user-blk）
- `VirtioNetDeviceMgr`: 网络设备管理（virtio-net）
- `VhostNetDeviceMgr`: vhost-net 设备管理
- `VhostUserNetDeviceMgr`: vhost-user-net 设备管理
- `FsDeviceMgr`: 文件系统设备管理（virtio-fs, vhost-user-fs）
- `VsockDeviceMgr`: VSOCK 设备管理
- `ConsoleManager`: 控制台设备管理
- `LegacyDeviceManager`: 传统设备管理（串口、RTC 等）
- `PciSystemManager`: PCI 系统管理（VFIO 设备直通）

**设备注册流程**:
1. 创建设备实例
2. 分配资源（MMIO/PIO 地址、IRQ）
3. 注册到 IoManager
4. 添加到 epoll 管理器

**支持的设备类型**:
- Virtio 设备: block, net, fs, vsock, mem, balloon
- vhost 设备: vhost-net, vhost-user-net, vhost-user-blk, vhost-user-fs
- 直通设备: VFIO PCI 设备

### 5. 地址空间管理 (`src/address_space_manager.rs`)

**职责**: Guest 内存地址空间管理

**功能**:
- 创建和管理 Guest 内存区域
- 支持多种内存后端（hugetlbfs, shmem）
- NUMA 区域配置
- 内存区域映射到 KVM

**关键操作**:
- `create_address_space()`: 创建地址空间
- `add_region()`: 添加内存区域
- `remove_region()`: 移除内存区域
- `map_region_to_kvm()`: 映射区域到 KVM

### 6. 事件管理 (`src/event_manager.rs`)

**职责**: 事件循环和 epoll 管理

**功能**:
- 使用 epoll 进行事件监听
- 处理设备 I/O 事件
- 处理 VMM API 事件
- 管理事件文件描述符

**事件类型**:
- API 事件: VMM 操作请求
- 设备事件: 设备 I/O 就绪
- VCPU 事件: VCPU 退出事件
- 退出事件: VMM 停止请求

### 7. API 接口 (`src/api/`)

**职责**: 提供 VMM 操作 API

**主要 API**:
- `ConfigureBootSource`: 配置启动源（内核、initrd、启动参数）
- `SetVmConfiguration`: 设置 VM 配置（vCPU、内存、拓扑等）
- `AddNetworkDevice`: 添加网络设备
- `AddBlockDevice`: 添加块设备
- `AddFsDevice`: 添加文件系统设备
- `StartMicrovm`: 启动虚拟机
- `StopMicrovm`: 停止虚拟机

## 子模块 (dbs_*)

### dbs_virtio_devices

**功能**: Virtio 设备实现

**特性**:
- 支持 MMIO 和 PCI 两种传输方式
- 实现多种 Virtio 设备类型
- 设备状态管理
- 队列管理

### dbs_arch

**功能**: 架构相关代码

**支持架构**:
- x86_64: TSS、中断控制器、PIT 等
- aarch64: GIC（中断控制器）、PMU（性能监控单元）等

### dbs_device

**功能**: 设备抽象层

**特性**:
- 设备 I/O 接口
- 资源管理（MMIO/PIO/IRQ）
- 设备生命周期管理

### dbs_boot

**功能**: 启动相关

**特性**:
- 内核加载器
- 启动参数配置
- 启动镜像处理

### dbs_interrupt

**功能**: 中断管理

**特性**:
- KVM IRQ 管理
- 中断路由
- 中断注入

### dbs_pci

**功能**: PCI 设备管理

**特性**:
- PCI 设备枚举
- VFIO 设备支持
- PCI 配置空间管理

### dbs_upcall

**功能**: Upcall 机制（可选）

**特性**:
- 用于热插拔通信
- 设备管理服务
- Guest-Host 通信

### dbs_allocator

**功能**: 内存分配器

**特性**:
- Guest 内存分配
- 地址空间分配
- 内存池管理

### dbs_utils

**功能**: 工具库

**特性**:
- epoll 管理器
- 时间戳工具
- 其他通用工具

## 关键特性

### 1. 安全特性

- **Seccomp 过滤器**: 为不同线程类型应用系统调用限制
- **进程隔离**: 每个 VM 运行在独立进程中
- **最小权限**: 只使用必要的系统调用

### 2. 性能优化

- **低开销**: 专为容器工作负载优化
- **快速启动**: 最小化启动时间
- **并发启动**: 支持多个 VM 并发启动
- **内存优化**: 支持大页内存（hugetlbfs）

### 3. 可扩展性

- **热插拔**: 支持 CPU 和设备热插拔
- **模块化设计**: 各组件解耦，易于扩展
- **特性开关**: 通过 Cargo features 控制功能

### 4. 设备支持

- **Virtio 设备**: 标准 Virtio 设备支持
- **vhost 设备**: 高性能 vhost 设备支持
- **设备直通**: VFIO 设备直通支持
- **传统设备**: 串口、RTC 等传统设备支持

## 启动流程

### 详细步骤

1. **VMM 创建** (`Vmm::new()`)
   - 初始化事件管理器
   - 创建 API 服务器
   - 初始化 VM 实例

2. **VM 配置** (`SetVmConfiguration`)
   - 设置 vCPU 配置
   - 设置内存配置
   - 设置 CPU 拓扑

3. **启动源配置** (`ConfigureBootSource`)
   - 设置内核路径
   - 设置 initrd 路径
   - 设置启动参数

4. **设备添加** (`AddNetworkDevice`, `AddBlockDevice`, etc.)
   - 创建设备实例
   - 分配资源
   - 注册设备

5. **VM 启动** (`StartMicrovm`)
   - 初始化 guest 内存
   - 初始化 VCPU
   - 初始化设备
   - 加载内核
   - 启动 VCPU 线程

6. **事件循环** (`run_vmm_event_loop()`)
   - 处理 API 请求
   - 处理设备 I/O
   - 处理 VCPU 退出

## 代码阅读建议

### 启动流程追踪

1. `Vmm::new()` - 创建 VMM 实例
2. `Vmm::run_vmm_event_loop()` - 进入事件循环
3. `Vm::start_microvm()` - 启动虚拟机
4. `Vm::init_microvm()` - 初始化微虚拟机
5. `VcpuManager::start_boot_vcpus()` - 启动 VCPU

### 设备添加流程

1. `DeviceManager::add_device()` - 添加设备
2. 设备特定的管理器（如 `BlockDeviceMgr::add_device()`）
3. 资源分配（MMIO/PIO/IRQ）
4. 设备注册到 IoManager
5. 添加到 epoll 管理器

### 内存管理流程

1. `Vm::init_guest_memory()` - 初始化 Guest 内存
2. `AddressSpaceMgr::create_address_space()` - 创建地址空间
3. 内存区域映射到 KVM
4. Guest 内存区域注册

## 待深入研究的问题

1. **VCPU 调度机制**: VCPU 线程如何与 KVM 交互？调度策略是什么？
2. **中断处理流程**: 中断如何从设备传递到 Guest？GIC 如何工作？
3. **内存映射机制**: Guest 内存如何映射到 Host？大页内存如何管理？
4. **设备 I/O 路径**: Virtio 设备的 I/O 请求如何从 Guest 传递到 Host？
5. **热插拔实现**: CPU 和设备热插拔的具体实现机制？
6. **Upcall 机制**: Upcall 如何用于热插拔通信？
7. **性能监控**: vPMU 如何工作？如何收集性能指标？
8. **安全沙箱**: Seccomp 过滤器如何限制系统调用？

## 相关文档

- [Dragonball README](../src/dragonball/README.md)
- [Device Document](../src/dragonball/docs/device.md)
- [vCPU Document](../src/dragonball/docs/vcpu.md)
- [API Document](../src/dragonball/docs/api.md)
- [Upcall Document](../src/dragonball/docs/upcall.md)

