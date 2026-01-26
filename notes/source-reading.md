# Kata Containers 源码阅读记录

> **注意**: 本文档是详细的源码阅读记录和待办事项。  
> 对于架构概述和系统性分析，请参考：
> - [架构概述](./architecture-overview.md)
> - [核心组件分析](./components/)
> - [关键机制分析](./mechanisms/)

## 项目概述

Kata Containers 是一个开源项目，旨在构建轻量级虚拟机（VMs）的标准实现，提供容器般的体验和性能，同时具备 VM 的工作负载隔离和安全性优势。

## 项目结构

### 核心组件

#### 1. Agent (`src/agent/`)
- **语言**: Rust
- **功能**: 运行在 guest VM 内部的 agent，负责与 host 通信，管理容器生命周期
- **关键文件**:
  - `src/main.rs` - Agent 入口
  - `src/rpc.rs` - RPC 通信
  - `src/sandbox.rs` - Sandbox 管理
  - `src/device/` - 设备管理
  - `src/storage/` - 存储管理
  - `src/network.rs` - 网络管理

#### 2. Runtime (`src/runtime/`)
- **语言**: Go
- **功能**: Kata Containers 的 Go 运行时实现
- **关键目录**:
  - `cmd/kata-runtime/` - 运行时命令行工具
  - `cmd/containerd-shim-kata-v2/` - containerd shim v2 实现
  - `pkg/virtcontainers/` - 虚拟容器核心逻辑
  - `pkg/hypervisors/` - 虚拟化管理器抽象

#### 3. Runtime-rs (`src/runtime-rs/`)
- **语言**: Rust
- **功能**: Kata Containers 的 Rust 运行时实现（新版本）
- **关键目录**:
  - `crates/service/` - 服务层
  - `crates/hypervisor/` - 虚拟化管理
  - `crates/shim/` - Shim 实现
  - `crates/agent/` - Agent 接口

#### 4. Dragonball (`src/dragonball/`)
- **语言**: Rust
- **功能**: 基于 KVM 的虚拟化框架
- **关键模块**:
  - `dbs_virtio_devices/` - Virtio 设备实现
  - `dbs_arch/` - 架构相关代码
  - `dbs_device/` - 设备管理
  - `dbs_vcpu/` - VCPU 管理

#### 5. Libraries (`src/libs/`)
- **语言**: Rust
- **功能**: 共享库和工具
- **关键库**:
  - `kata-types/` - 类型定义
  - `protocols/` - 协议定义
  - `shim-interface/` - Shim 接口

## 源码阅读记录

### Agent 模块

#### 入口点分析
- [ ] `src/agent/src/main.rs` - Agent 主入口
  - 启动流程
  - 初始化逻辑
  - 信号处理

#### RPC 通信机制
- [ ] `src/agent/src/rpc.rs` - RPC 实现
  - 通信协议
  - 消息处理
  - 错误处理

#### Sandbox 管理
- [ ] `src/agent/src/sandbox.rs` - Sandbox 生命周期
  - 创建流程
  - 配置管理
  - 资源管理

#### 设备管理
- [ ] `src/agent/src/device/` - 设备管理模块
  - 设备类型
  - 设备挂载
  - 设备权限

#### 存储管理
- [ ] `src/agent/src/storage/` - 存储管理
  - 文件系统操作
  - 卷管理
  - 挂载点管理

#### 网络管理
- [ ] `src/agent/src/network.rs` - 网络配置
  - 网络接口
  - 路由配置
  - DNS 配置

### Runtime 模块 (Go)

#### 运行时入口
- [ ] `src/runtime/cmd/kata-runtime/` - 运行时 CLI
  - 命令解析
  - 子命令实现

#### Virtcontainers
- [ ] `src/runtime/pkg/virtcontainers/` - 虚拟容器核心
  - Sandbox 管理
  - Container 管理
  - 资源管理

#### Hypervisor 抽象
- [ ] `src/runtime/pkg/hypervisors/` - 虚拟化管理器
  - QEMU 实现
  - Firecracker 实现
  - Cloud Hypervisor 实现

### Runtime-rs 模块 (Rust)

#### 服务层
- [ ] `src/runtime-rs/crates/service/` - 服务实现
  - API 定义
  - 请求处理
  - 响应生成

#### Hypervisor 管理
- [ ] `src/runtime-rs/crates/hypervisor/` - 虚拟化管理
  - Hypervisor trait
  - 具体实现
  - 资源管理

#### Shim 实现
- [ ] `src/runtime-rs/crates/shim/` - Shim v2 实现
  - 生命周期管理
  - 事件处理
  - 状态同步

### Dragonball 模块

#### 模块概述
Dragonball 是一个基于 KVM 的轻量级虚拟化管理器（VMM），专门为容器工作负载优化，具有以下特点：
- 容器镜像管理和加速服务
- 灵活且高性能的虚拟设备驱动
- 低 CPU 和内存开销
- 最小化启动时间
- 优化的并发启动速度

**架构支持**: x86-64, aarch64

**设计理念**: Dragonball 是 Kata Containers 3.0 的内置 VMM，提供开箱即用的体验，无需复杂的环境设置和配置。

#### 核心架构

##### 1. VMM 核心 (`src/dragonball/src/vmm.rs`)
**职责**: 全局协调器，管理 API 服务器、虚拟机、升级等

**对象模型**:
```
Vmm <-1:N-> Vm <-1:1-> Address Space Manager <-1:N-> GuestMemory
  ^           ^---1:1-> Device Manager <-1:N-> Device
  |           ^---1:1-> Resource Manager
  |           ^---1:N-> Vcpu
  |---<-1:N-> Event Manager
```

**关键功能**:
- `Vmm::new()` - 创建 VMM 实例，初始化 VM、事件上下文、epoll 管理器
- `Vmm::run_vmm_event_loop()` - 运行事件循环，处理 API 请求
  - 使用 epoll 进行事件管理
  - 处理 API 事件和退出事件
  - 调用 `VmmService::run_vmm_action()` 处理 VMM 操作
- `Vmm::stop()` - 优雅停止 VMM
  - 移除所有设备
  - 退出所有 vCPU 线程
  - 保存退出状态

**线程类型**:
- `ALL_THREADS` - 所有线程的 seccomp 限制
- `VMM_THREAD` - VMM 线程
- `VCPU_THREAD` - VCPU 线程

##### 2. VM 管理 (`src/dragonball/src/vm/mod.rs`)
**职责**: 虚拟机实例管理

**初始化流程** (`Vm::start_microvm()`):
1. 应用 seccomp 过滤器（安全沙箱）
2. 检查 VM 状态（防止重复启动）
3. 初始化 guest 内存 (`init_guest_memory()`)
   - 支持 `hugetlbfs` 和 `shmem` 两种内存类型
   - 配置 NUMA 区域
4. 初始化 VCPU 管理器 (`init_vcpu_manager()`)
5. 初始化微虚拟机 (`init_microvm()`)
   - x86_64: 初始化 TSS → 设置中断控制器 → 创建 PIT → 初始化设备
   - aarch64: 创建 VCPU → 设置 GIC → 初始化设备
   - 加载内核镜像
   - 创建启动 VCPU
6. 配置系统 (`init_configure_system()`)
7. 注册事件 (`register_events()`)
8. 启动 VCPU (`start_boot_vcpus()`)

**关键组件**:
- `KvmContext` - KVM 操作上下文
- `AddressSpaceMgr` - 地址空间管理器
- `DeviceManager` - 设备管理器
- `VcpuManager` - VCPU 管理器
- `ResourceManager` - 资源管理器

**配置结构**:
- `VmConfigInfo`: vCPU 数量、内存大小、CPU 拓扑、vPMU 特性等
- `KernelConfigInfo`: 内核路径、initrd 路径、启动参数
- `NumaRegionInfo`: NUMA 区域配置

##### 3. VCPU 管理 (`src/dragonball/src/vcpu/`)
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

##### 4. 设备管理 (`src/dragonball/src/device_manager/`)
**职责**: 虚拟设备的生命周期管理

**设备管理器类型**:
- `BlockDeviceMgr` - 块设备管理（virtio-blk, vhost-user-blk）
- `VirtioNetDeviceMgr` - 网络设备管理（virtio-net）
- `VhostNetDeviceMgr` - vhost-net 设备管理
- `VhostUserNetDeviceMgr` - vhost-user-net 设备管理
- `FsDeviceMgr` - 文件系统设备管理（virtio-fs, vhost-user-fs）
- `VsockDeviceMgr` - VSOCK 设备管理
- `ConsoleManager` - 控制台设备管理
- `LegacyDeviceManager` - 传统设备管理（串口、RTC 等）
- `PciSystemManager` - PCI 系统管理（VFIO 设备直通）

**设备注册流程**:
1. 创建设备实例
2. 分配资源（MMIO/PIO 地址、IRQ）
3. 注册到 IoManager
4. 添加到 epoll 管理器

**支持的设备类型**:
- Virtio 设备: block, net, fs, vsock, mem, balloon
- vhost 设备: vhost-net, vhost-user-net, vhost-user-blk, vhost-user-fs
- 直通设备: VFIO PCI 设备

##### 5. 地址空间管理 (`src/dragonball/src/address_space_manager.rs`)
**职责**: Guest 内存地址空间管理

**功能**:
- 创建和管理 Guest 内存区域
- 支持多种内存后端（hugetlbfs, shmem）
- NUMA 区域配置
- 内存区域映射到 KVM

##### 6. 事件管理 (`src/dragonball/src/event_manager.rs`)
**职责**: 事件循环和 epoll 管理

**功能**:
- 使用 epoll 进行事件监听
- 处理设备 I/O 事件
- 处理 VMM API 事件
- 管理事件文件描述符

##### 7. API 接口 (`src/dragonball/src/api/`)
**职责**: 提供 VMM 操作 API

**主要 API**:
- `ConfigureBootSource` - 配置启动源（内核、initrd、启动参数）
- `SetVmConfiguration` - 设置 VM 配置（vCPU、内存、拓扑等）
- `AddNetworkDevice` - 添加网络设备
- `AddBlockDevice` - 添加块设备
- `StartMicrovm` - 启动虚拟机
- `StopMicrovm` - 停止虚拟机

##### 8. 子模块 (dbs_*)
**dbs_virtio_devices**: Virtio 设备实现
- 支持 MMIO 和 PCI 两种传输方式
- 实现多种 Virtio 设备类型

**dbs_arch**: 架构相关代码
- x86_64 和 aarch64 特定实现
- GIC（ARM 中断控制器）支持
- PMU（性能监控单元）支持

**dbs_device**: 设备抽象层
- 设备 I/O 接口
- 资源管理（MMIO/PIO/IRQ）

**dbs_boot**: 启动相关
- 内核加载器
- 启动参数配置

**dbs_interrupt**: 中断管理
- KVM IRQ 管理
- 中断路由

**dbs_pci**: PCI 设备管理
- PCI 设备枚举
- VFIO 设备支持

**dbs_upcall**: Upcall 机制（可选）
- 用于热插拔通信
- 设备管理服务

**dbs_allocator**: 内存分配器
- Guest 内存分配
- 地址空间分配

**dbs_utils**: 工具库
- epoll 管理器
- 时间戳工具
- 其他通用工具

#### 关键特性

##### 1. 安全特性
- **Seccomp 过滤器**: 为不同线程类型应用系统调用限制
- **进程隔离**: 每个 VM 运行在独立进程中
- **最小权限**: 只使用必要的系统调用

##### 2. 性能优化
- **低开销**: 专为容器工作负载优化
- **快速启动**: 最小化启动时间
- **并发启动**: 支持多个 VM 并发启动
- **内存优化**: 支持大页内存（hugetlbfs）

##### 3. 可扩展性
- **热插拔**: 支持 CPU 和设备热插拔
- **模块化设计**: 各组件解耦，易于扩展
- **特性开关**: 通过 Cargo features 控制功能

##### 4. 设备支持
- **Virtio 设备**: 标准 Virtio 设备支持
- **vhost 设备**: 高性能 vhost 设备支持
- **设备直通**: VFIO 设备直通支持
- **传统设备**: 串口、RTC 等传统设备支持

#### 代码阅读建议

##### 启动流程追踪
1. `Vmm::new()` - 创建 VMM 实例
2. `Vmm::run_vmm_event_loop()` - 进入事件循环
3. `Vm::start_microvm()` - 启动虚拟机
4. `Vm::init_microvm()` - 初始化微虚拟机
5. `VcpuManager::start_boot_vcpus()` - 启动 VCPU

##### 设备添加流程
1. `DeviceManager::add_device()` - 添加设备
2. 设备特定的管理器（如 `BlockDeviceMgr::add_device()`）
3. 资源分配（MMIO/PIO/IRQ）
4. 设备注册到 IoManager
5. 添加到 epoll 管理器

##### 内存管理流程
1. `Vm::init_guest_memory()` - 初始化 Guest 内存
2. `AddressSpaceMgr::create_address_space()` - 创建地址空间
3. 内存区域映射到 KVM
4. Guest 内存区域注册

#### 待深入研究的问题

1. **VCPU 调度机制**: VCPU 线程如何与 KVM 交互？调度策略是什么？
2. **中断处理流程**: 中断如何从设备传递到 Guest？GIC 如何工作？
3. **内存映射机制**: Guest 内存如何映射到 Host？大页内存如何管理？
4. **设备 I/O 路径**: Virtio 设备的 I/O 请求如何从 Guest 传递到 Host？
5. **热插拔实现**: CPU 和设备热插拔的具体实现机制？
6. **Upcall 机制**: Upcall 如何用于热插拔通信？
7. **性能监控**: vPMU 如何工作？如何收集性能指标？
8. **安全沙箱**: Seccomp 过滤器如何限制系统调用？

## 关键概念理解

### 1. Sandbox vs Container
- **Sandbox**: 虚拟机实例，包含一个或多个容器
- **Container**: 运行在 Sandbox 内的容器实例

### 2. Agent 通信机制
- Agent 通过 vsock 或 virtio-serial 与 host 通信
- 使用 gRPC 协议进行 RPC 调用

### 3. 虚拟化架构
- 支持多种 hypervisor: QEMU, Firecracker, Cloud Hypervisor
- Dragonball 是基于 KVM 的轻量级 VMM

### 4. 安全模型
- 使用虚拟机隔离
- 支持 TEE (Trusted Execution Environment)
- 策略引擎 (OPA)

## 容器迁移研究指南

### 迁移概述

Kata Containers 中的容器迁移主要涉及两个方面：
1. **VM 模板和克隆** - 用于快速启动新容器（冷启动优化）
2. **实时迁移** - 在运行的 VM 之间迁移（热迁移，目前主要支持 Cloud Hypervisor）

### 1. VM 模板机制（Template）

#### 核心概念
VM 模板是一种优化技术，通过预先创建一个"模板 VM"并保存其状态，后续可以快速克隆出新的 VM，从而大幅减少容器启动时间。

#### 关键组件

##### Factory 机制 (`src/runtime/virtcontainers/factory/`)
- **Factory 接口**: 提供 VM 创建的统一接口
- **Template Factory** (`factory/template/`): 实现基于模板的 VM 创建
- **Direct Factory** (`factory/direct/`): 直接创建 VM（不使用模板）
- **Cache Factory** (`factory/cache/`): 带缓存的 VM 创建
- **VMCache** (`factory/grpccache/`): 基于 gRPC 的 VM 缓存服务

##### 模板创建流程
1. **创建模板 VM** (`template_linux.go::createTemplateVM()`)
   - 设置 `BootToBeTemplate = true`
   - 创建 VM 并启动
   - 暂停 VM (`vm.Pause()`)
   - 保存 VM 状态 (`vm.Save()`)
   - 状态保存在 `templatePath/memory` 和 `templatePath/state`

2. **从模板克隆 VM** (`template_linux.go::createFromTemplateVM()`)
   - 设置 `BootFromTemplate = true`
   - 使用 QEMU 的 migration incoming 机制
   - 从保存的状态文件恢复 VM

##### 关键代码位置
- `src/runtime/virtcontainers/factory/template/template_linux.go` - 模板实现
- `src/runtime/virtcontainers/qemu.go::bootFromTemplate()` - 从模板启动
- `src/runtime/virtcontainers/qemu.go::SaveVM()` - 保存 VM 状态
- `src/runtime/virtcontainers/vm.go::Save()` - VM 保存接口

##### QEMU 迁移机制
- **保存状态**: 使用 QEMU 的 `migrate` 命令，通过 `exec:cat > file` 保存到文件
- **恢复状态**: 使用 `migrate-incoming` 命令，通过 `exec:cat file` 从文件恢复
- **共享内存处理**: 模板机制需要忽略共享内存迁移能力 (`setIgnoreSharedMemoryMigrationCaps`)

#### 研究入口点

**1. 理解 Factory 模式**
```bash
# 查看 Factory 接口定义
src/runtime/virtcontainers/factory/factory.go

# 查看模板实现
src/runtime/virtcontainers/factory/template/template_linux.go

# 查看 Factory 创建逻辑
src/runtime/virtcontainers/factory/factory_linux.go
```

**2. 理解 QEMU 迁移命令**
```bash
# QMP 迁移相关命令
src/runtime/pkg/govmm/qemu/qmp.go
# 关键函数:
# - ExecSetMigrateArguments() - 设置迁移参数
# - ExecuteMigrationIncoming() - 接收迁移
# - ExecuteQueryMigration() - 查询迁移状态
```

**3. 理解 VM 生命周期**
```bash
# VM 创建和启动
src/runtime/virtcontainers/vm.go::NewVM()

# VM 保存和恢复
src/runtime/virtcontainers/qemu.go::SaveVM()
src/runtime/virtcontainers/qemu.go::bootFromTemplate()
```

### 2. 实时迁移（Live Migration）

#### 当前支持状态
- **Cloud Hypervisor**: 支持实时迁移（通过 API）
- **QEMU**: 主要支持模板机制，实时迁移支持有限
- **Dragonball**: 目前不支持迁移

#### Cloud Hypervisor 迁移

##### API 接口
- `SendMigrationData`: 发送迁移数据到目标 URL
  - `DestinationUrl`: 目标 URL
  - `Local`: 是否为本地迁移
- `ReceiveMigrationData`: 接收迁移数据
  - `ReceiverUrl`: 接收器 URL

##### 关键代码位置
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/api_default.go`
  - `SendVMCommand()` - 发送迁移命令
  - `ReceiveVMCommand()` - 接收迁移命令
- `src/runtime/virtcontainers/clh.go` - Cloud Hypervisor 实现

#### 研究入口点

**1. Cloud Hypervisor API**
```bash
# API 定义
src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/SendMigrationData.md
src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/ReceiveMigrationData.md

# API 实现
src/runtime/virtcontainers/pkg/cloud-hypervisor/client/api_default.go
```

**2. 迁移流程**
- 源端: 调用 `SendMigrationData` 开始迁移
- 目标端: 调用 `ReceiveMigrationData` 准备接收
- 迁移数据通过 URL 指定的通道传输（如 HTTP、TCP 等）

### 3. 迁移研究路线图

#### 阶段 1: 理解现有机制
1. **阅读 Factory 代码**
   - [ ] 理解 Factory 接口和实现
   - [ ] 理解 Template Factory 的工作流程
   - [ ] 理解 VM 状态保存和恢复机制

2. **阅读 QEMU 迁移代码**
   - [ ] 理解 QMP 迁移命令
   - [ ] 理解迁移状态查询
   - [ ] 理解共享内存处理

3. **阅读 Cloud Hypervisor 迁移代码**
   - [ ] 理解迁移 API
   - [ ] 理解迁移数据传输机制

#### 阶段 2: 深入理解迁移原理
1. **QEMU 迁移机制**
   - [ ] 研究 QEMU 迁移协议
   - [ ] 理解迁移数据格式
   - [ ] 理解脏页跟踪机制
   - [ ] 理解迁移过程中的设备状态处理

2. **内存迁移**
   - [ ] 理解内存快照机制
   - [ ] 理解增量迁移
   - [ ] 理解大页内存迁移

3. **设备迁移**
   - [ ] 理解 Virtio 设备状态保存
   - [ ] 理解网络设备迁移
   - [ ] 理解存储设备迁移

#### 阶段 3: 实现改进或新功能
1. **Dragonball 迁移支持**
   - [ ] 设计迁移接口
   - [ ] 实现状态保存
   - [ ] 实现状态恢复
   - [ ] 实现迁移数据传输

2. **实时迁移优化**
   - [ ] 优化迁移性能
   - [ ] 减少停机时间
   - [ ] 支持增量迁移

3. **迁移工具和测试**
   - [ ] 开发迁移测试工具
   - [ ] 性能基准测试
   - [ ] 故障恢复测试

### 4. 关键文件清单

#### Factory 和模板
- `src/runtime/virtcontainers/factory/factory.go` - Factory 接口
- `src/runtime/virtcontainers/factory/factory_linux.go` - Factory 实现
- `src/runtime/virtcontainers/factory/template/template_linux.go` - 模板实现
- `src/runtime/virtcontainers/factory/base/base.go` - 基础接口

#### QEMU 迁移
- `src/runtime/virtcontainers/qemu.go` - QEMU hypervisor 实现
  - `SaveVM()` - 保存 VM 状态
  - `bootFromTemplate()` - 从模板启动
  - `waitMigration()` - 等待迁移完成
- `src/runtime/pkg/govmm/qemu/qmp.go` - QMP 命令实现
  - `ExecSetMigrateArguments()` - 设置迁移参数
  - `ExecuteMigrationIncoming()` - 接收迁移
  - `ExecuteQueryMigration()` - 查询迁移状态

#### Cloud Hypervisor 迁移
- `src/runtime/virtcontainers/clh.go` - Cloud Hypervisor 实现
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/api_default.go` - API 实现
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/SendMigrationData.md` - 发送迁移 API
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/ReceiveMigrationData.md` - 接收迁移 API

#### VM 管理
- `src/runtime/virtcontainers/vm.go` - VM 接口和实现
  - `NewVM()` - 创建新 VM
  - `Save()` - 保存 VM
  - `Pause()` - 暂停 VM
- `src/runtime/virtcontainers/hypervisor.go` - Hypervisor 接口

### 5. 实验建议

#### 实验 1: 创建和使用模板
1. 配置 Kata 使用模板模式
2. 创建模板 VM
3. 从模板创建多个容器
4. 测量启动时间差异

#### 实验 2: 理解迁移数据
1. 使用 QEMU 保存 VM 状态
2. 分析状态文件内容
3. 理解内存和设备状态的保存格式

#### 实验 3: Cloud Hypervisor 迁移
1. 启动两个 Cloud Hypervisor VM
2. 执行迁移操作
3. 观察迁移过程
4. 分析迁移性能

### 6. 相关文档和资源

- [QEMU 迁移文档](https://www.qemu.org/docs/master/devel/migration.html)
- [Cloud Hypervisor 迁移文档](https://github.com/cloud-hypervisor/cloud-hypervisor)
- Kata Containers 设计文档中的迁移相关章节

### 7. 待深入研究的问题

1. **模板机制**
   - 模板 VM 的内存如何共享？
   - 从模板克隆的 VM 如何保证隔离？
   - 模板更新机制是什么？

2. **实时迁移**
   - 迁移过程中的网络连接如何处理？
   - 存储设备如何迁移？
   - 迁移失败时的回滚机制？

3. **性能优化**
   - 如何减少迁移停机时间？
   - 如何优化迁移数据传输？
   - 如何支持增量迁移？

4. **Dragonball 迁移**
   - 如何在 Dragonball 中实现迁移？
   - Dragonball 的迁移接口设计？
   - 与 QEMU 迁移的差异？

## 其他待深入研究的问题

1. Agent 如何与 Runtime 通信？
2. Sandbox 的创建和销毁流程？
3. 网络配置如何在 host 和 guest 之间同步？
4. 存储卷如何挂载到容器内？
5. VCPU 调度策略是什么？
6. 如何支持不同的虚拟化后端？

## 参考资料

- [Kata Containers 官方文档](https://katacontainers.io)
- [架构设计文档](docs/design/)
- [开发者指南](docs/Developer-Guide.md)

## 阅读时间线

- [日期] - 开始阅读项目结构
- [日期] - Agent 模块分析
- [日期] - Runtime 模块分析
- [日期] - Dragonball 模块分析

---

*最后更新: [日期]*

