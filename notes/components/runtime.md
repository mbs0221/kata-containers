# Runtime 模块分析 (Go)

## 概述

Runtime 是 Kata Containers 的 Go 运行时实现，实现了 OCI runtime 规范和 containerd shim v2 API。

**位置**: `src/runtime/`  
**语言**: Go  
**职责**: Sandbox/Container 生命周期管理、Hypervisor 管理、与 Agent 通信

## 架构设计

### 核心组件

```
containerd-shim-kata-v2
├── Shim v2 API 实现
│   ├── Create
│   ├── Start
│   ├── Delete
│   ├── Exec
│   └── ...
├── virtcontainers 包
│   ├── Sandbox 管理
│   ├── Container 管理
│   ├── Hypervisor 抽象
│   └── 资源管理
└── Hypervisor 实现
    ├── QEMU
    ├── Cloud Hypervisor
    ├── Firecracker
    └── StratoVirt
```

## 关键目录结构

### 1. 命令行工具 (`cmd/`)

#### kata-runtime (`cmd/kata-runtime/`)

**功能**: 管理工具，提供管理命令

**主要命令**:
- `check`: 检查系统是否支持 Kata Containers
- `exec`: 进入 VM 调试控制台
- `policy`: 设置策略

#### containerd-shim-kata-v2 (`cmd/containerd-shim-kata-v2/`)

**功能**: containerd shim v2 实现，这是实际的运行时

**关键功能**:
- 实现 containerd shim v2 API
- 管理 Sandbox 和 Container 生命周期
- 与 containerd 通信（通过 Unix socket）

### 2. virtcontainers 包 (`pkg/virtcontainers/`)

**功能**: 虚拟容器核心库，提供硬件虚拟化容器的抽象

#### Sandbox 管理

**Sandbox 概念**:
- Sandbox = VM 实例
- 一个 Sandbox 可以包含多个 Container
- Sandbox 生命周期 = VM 生命周期

**关键操作**:
- `CreateSandbox()`: 创建 Sandbox（启动 VM）
- `StartSandbox()`: 启动 Sandbox
- `StopSandbox()`: 停止 Sandbox
- `DeleteSandbox()`: 删除 Sandbox
- `PauseSandbox()`: 暂停 Sandbox（用于模板）
- `ResumeSandbox()`: 恢复 Sandbox

#### Container 管理

**关键操作**:
- `CreateContainer()`: 在 Sandbox 中创建容器
- `StartContainer()`: 启动容器
- `StopContainer()`: 停止容器
- `DeleteContainer()`: 删除容器
- `UpdateContainer()`: 更新容器资源

#### Hypervisor 抽象 (`pkg/hypervisors/`)

**Hypervisor 接口**:
```go
type Hypervisor interface {
    CreateVM(ctx context.Context, id string, network Network, hypervisorConfig *HypervisorConfig) error
    StartVM(ctx context.Context, timeout int) error
    StopVM(ctx context.Context, waitOnly bool) error
    PauseVM(ctx context.Context) error
    SaveVM() error
    // ...
}
```

**支持的 Hypervisor**:
- `qemu`: QEMU/KVM 实现
- `clh`: Cloud Hypervisor 实现
- `firecracker`: Firecracker 实现
- `stratovirt`: StratoVirt 实现

#### Factory 机制 (`factory/`)

**Factory 模式**: 用于优化 VM 创建，支持模板机制

**Factory 类型**:
- `template`: 基于模板的 VM 创建
- `direct`: 直接创建 VM
- `cache`: 带缓存的 VM 创建
- `grpccache`: 基于 gRPC 的 VM 缓存服务

**模板机制**:
1. 创建模板 VM（暂停状态）
2. 保存 VM 状态
3. 从模板快速克隆新 VM

### 3. 设备管理 (`pkg/device/`)

**设备类型**:
- 块设备
- 网络设备
- 文件系统设备
- VFIO 设备

### 4. OCI 集成 (`pkg/oci/`)

**功能**: OCI 规范集成

- OCI bundle 解析
- OCI 配置转换
- 挂载点管理

## 关键流程

### Sandbox 创建流程

```
1. containerd → Runtime: Create (shimv2 API)
2. Runtime:
   - 解析 OCI bundle
   - 创建 Sandbox 配置
   - 选择 Hypervisor
   - 调用 Hypervisor.CreateVM()
   - Hypervisor 启动 VM
   - 等待 Agent 就绪
   - 调用 Agent.CreateSandbox()
3. Runtime → containerd: Sandbox Created
```

### Container 创建流程

```
1. containerd → Runtime: Create (shimv2 API)
2. Runtime:
   - 解析 Container 配置
   - 调用 Agent.CreateContainer()
   - Agent 创建容器环境
3. Runtime → containerd: Container Created
```

### Container 启动流程

```
1. containerd → Runtime: Start (shimv2 API)
2. Runtime:
   - 调用 Agent.StartContainer()
   - Agent 启动进程
3. Runtime → containerd: Container Started
```

## 通信机制

### Runtime-Agent 通信

**协议**: ttRPC  
**传输**: VSOCK 或 virtio-serial  
**客户端**: Runtime (Go)  
**服务器**: Agent (Rust)

**关键操作**:
- `CreateSandbox`: 创建 Sandbox
- `CreateContainer`: 创建容器
- `StartContainer`: 启动容器
- `WaitProcess`: 等待进程退出

### 协议定义

协议定义在 `src/libs/protocols/protos/agent.proto`，Go 代码通过 `protoc` 生成。

## 配置管理

### 配置文件

**位置**: `/opt/kata/share/defaults/kata-containers/configuration.toml`

**主要配置项**:
- `[hypervisor]`: Hypervisor 配置
- `[agent]`: Agent 配置
- `[runtime]`: Runtime 配置
- `[factory]`: Factory 配置

### 配置加载

Runtime 在启动时加载配置文件，配置影响：
- Hypervisor 选择
- VM 资源配置
- 网络配置
- 存储配置

## 资源管理

### CPU 管理

- vCPU 数量配置
- CPU 拓扑配置
- CPU 热插拔支持

### 内存管理

- 内存大小配置
- 大页内存支持
- NUMA 配置

### 存储管理

- 块设备管理
- 文件系统共享（virtio-fs）
- 卷管理

### 网络管理

- CNI 集成
- 网络命名空间管理
- 网络设备配置

## Factory 和模板机制

### 模板创建

1. **创建模板 VM**:
   ```
   - 设置 BootToBeTemplate = true
   - 创建并启动 VM
   - 暂停 VM
   - 保存 VM 状态
   ```

2. **从模板克隆**:
   ```
   - 设置 BootFromTemplate = true
   - 使用 QEMU migration incoming
   - 从状态文件恢复 VM
   ```

### 模板优势

- **快速启动**: 避免完整的 VM 启动过程
- **资源优化**: 共享内存页
- **并发启动**: 支持多个 VM 并发克隆

## 待深入研究

1. **virtcontainers 包**: 详细的数据结构和接口设计
2. **Hypervisor 抽象**: 不同 Hypervisor 的实现差异
3. **Factory 机制**: 模板创建和克隆的详细流程
4. **资源管理**: CPU、内存、存储的分配和管理
5. **网络集成**: CNI 插件如何与 Runtime 交互

## 相关文件

- `src/runtime/cmd/containerd-shim-kata-v2/` - Shim v2 实现
- `src/runtime/pkg/virtcontainers/` - 核心库
- `src/runtime/pkg/hypervisors/` - Hypervisor 实现
- `src/runtime/virtcontainers/factory/` - Factory 机制
- `src/runtime/pkg/oci/` - OCI 集成

