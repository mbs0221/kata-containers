# Agent 模块分析

## 概述

Agent (`kata-agent`) 是运行在 guest VM 内部的长驻进程，负责管理容器生命周期和与 Runtime 通信。

**位置**: `src/agent/`  
**语言**: Rust  
**职责**: 容器管理、设备管理、存储管理、网络管理

## 架构设计

### 核心组件

```
kata-agent
├── RPC Server (ttRPC)
│   ├── CreateSandbox
│   ├── DestroySandbox
│   ├── CreateContainer
│   ├── StartContainer
│   ├── StopContainer
│   └── ...
├── Sandbox Manager
│   ├── Sandbox 生命周期
│   ├── 资源管理
│   └── 配置管理
├── Container Manager
│   ├── Container 创建
│   ├── Process 管理
│   └── Namespace/Cgroup 管理
├── Device Manager
│   ├── 块设备
│   ├── 网络设备
│   └── 文件系统设备
├── Storage Manager
│   ├── 文件系统操作
│   ├── 卷管理
│   └── 挂载点管理
└── Network Manager
    ├── 网络接口配置
    ├── 路由配置
    └── DNS 配置
```

## 关键文件分析

### 1. 入口点 (`src/main.rs`)

**功能**:
- Agent 进程启动
- 初始化 RPC 服务器
- 信号处理
- 日志配置

**关键流程**:
1. 解析命令行参数和配置
2. 初始化日志系统
3. 创建 RPC 服务器
4. 启动 RPC 服务循环
5. 处理信号（SIGTERM, SIGINT 等）

### 2. RPC 通信 (`src/rpc.rs`)

**协议**: ttRPC（基于 gRPC 的轻量级协议）

**通信方式**:
- VSOCK: `vsock://-1:1024`（默认）
- virtio-serial: 备用方案

**主要 API**:
- `CreateSandbox`: 创建 Sandbox
- `DestroySandbox`: 销毁 Sandbox
- `CreateContainer`: 创建容器
- `StartContainer`: 启动容器
- `StopContainer`: 停止容器
- `RemoveContainer`: 删除容器
- `WaitProcess`: 等待进程退出
- `UpdateContainer`: 更新容器资源
- `UpdateEphemeralMounts`: 更新临时挂载

### 3. Sandbox 管理 (`src/sandbox.rs`)

**Sandbox 结构**:
- Sandbox ID
- 网络命名空间
- 共享文件系统
- 设备列表
- 容器列表

**关键操作**:
- `create_sandbox()`: 创建 Sandbox
  - 创建网络命名空间
  - 配置网络接口
  - 设置共享文件系统
- `destroy_sandbox()`: 销毁 Sandbox
  - 清理所有容器
  - 卸载文件系统
  - 清理网络配置

### 4. 设备管理 (`src/device/`)

**设备类型**:
- **块设备** (`block.rs`): virtio-blk, virtio-scsi
- **网络设备** (`network.rs`): virtio-net
- **文件系统设备** (`fs.rs`): virtio-fs, virtio-9p
- **VSOCK 设备** (`vsock.rs`): virtio-vsock

**设备操作**:
- `add_device()`: 添加设备
- `remove_device()`: 移除设备
- `update_device()`: 更新设备配置

### 5. 存储管理 (`src/storage/`)

**存储类型**:
- **文件系统存储**: 基于 virtio-fs 的共享文件系统
- **块存储**: 基于 virtio-blk 的块设备
- **临时存储**: 临时挂载点

**关键操作**:
- `mount()`: 挂载文件系统
- `unmount()`: 卸载文件系统
- `create_volume()`: 创建存储卷
- `remove_volume()`: 删除存储卷

### 6. 网络管理 (`src/network.rs`)

**网络配置**:
- 网络接口创建和配置
- 路由表配置
- DNS 配置
- CNI 集成

**关键操作**:
- `setup_network()`: 设置网络
- `add_interface()`: 添加网络接口
- `remove_interface()`: 移除网络接口
- `update_routes()`: 更新路由

## 容器生命周期管理

### 创建流程

1. **CreateSandbox**:
   ```
   Runtime → Agent: CreateSandbox
   Agent:
     - 创建网络命名空间
     - 配置网络接口
     - 设置共享文件系统
     - 初始化设备管理器
   Agent → Runtime: Sandbox Created
   ```

2. **CreateContainer**:
   ```
   Runtime → Agent: CreateContainer
   Agent:
     - 创建容器目录
     - 挂载 rootfs
     - 创建 namespaces
     - 创建 cgroups
     - 准备容器环境
   Agent → Runtime: Container Created
   ```

3. **StartContainer**:
   ```
   Runtime → Agent: StartContainer
   Agent:
     - 设置环境变量
     - 配置资源限制
     - 启动进程
   Agent → Runtime: Container Started
   ```

### 销毁流程

1. **StopContainer**:
   ```
   Runtime → Agent: StopContainer
   Agent:
     - 发送信号给进程
     - 等待进程退出
     - 清理资源
   ```

2. **DestroySandbox**:
   ```
   Runtime → Agent: DestroySandbox
   Agent:
     - 停止所有容器
     - 卸载文件系统
     - 清理网络配置
     - 清理设备
   ```

## 进程管理

### Process 结构

- PID: 进程 ID
- 标准 I/O: stdin, stdout, stderr
- 环境变量
- 工作目录
- 用户/组 ID

### 关键操作

- `spawn_process()`: 启动进程
- `wait_process()`: 等待进程退出
- `signal_process()`: 发送信号给进程
- `read_stdout()`: 读取标准输出
- `read_stderr()`: 读取标准错误

## 安全特性

### 1. Namespace 隔离

- **PID Namespace**: 进程隔离
- **Mount Namespace**: 文件系统隔离
- **Network Namespace**: 网络隔离
- **UTS Namespace**: 主机名隔离
- **IPC Namespace**: IPC 隔离
- **User Namespace**: 用户隔离

### 2. Cgroup 限制

- CPU 限制
- 内存限制
- I/O 限制
- 进程数限制

### 3. Seccomp 支持

Agent 支持在容器中应用 seccomp 过滤器，限制系统调用。

## 配置选项

Agent 支持通过内核命令行参数配置：

| 选项 | 描述 | 默认值 |
|------|------|--------|
| `agent.server_addr` | RPC 服务器地址 | `vsock://-1:1024` |
| `agent.log` | 日志级别 | `info` |
| `agent.debug_console` | 启用调试控制台 | `false` |
| `agent.hotplug_timeout` | 热插拔超时（秒） | `3` |
| `agent.container_pipe_size` | 容器管道大小 | `0` |

## 通信协议

### ttRPC 协议

ttRPC 是基于 gRPC 的轻量级协议，专为容器运行时设计：

- **更小的开销**: 相比标准 gRPC，减少序列化开销
- **Unix Domain Socket**: 支持本地通信
- **VSOCK**: 支持 VM 间通信

### 协议定义

协议定义在 `src/libs/protocols/protos/agent.proto`:

```protobuf
service AgentService {
    rpc CreateSandbox(CreateSandboxRequest) returns (CreateSandboxResponse);
    rpc DestroySandbox(DestroySandboxRequest) returns (DestroySandboxResponse);
    rpc CreateContainer(CreateContainerRequest) returns (CreateContainerResponse);
    rpc StartContainer(StartContainerRequest) returns (StartContainerResponse);
    // ...
}
```

## 待深入研究

1. **进程监控机制**: Agent 如何监控容器进程状态？
2. **资源限制**: Cgroup 如何与容器进程关联？
3. **文件系统管理**: virtio-fs 的挂载和管理机制？
4. **网络配置**: CNI 插件如何与 Agent 交互？
5. **设备热插拔**: 设备热插拔的实现机制？

## 相关文件

- `src/agent/src/main.rs` - Agent 入口
- `src/agent/src/rpc.rs` - RPC 服务器实现
- `src/agent/src/sandbox.rs` - Sandbox 管理
- `src/agent/src/device/` - 设备管理
- `src/agent/src/storage/` - 存储管理
- `src/agent/src/network.rs` - 网络管理
- `src/libs/protocols/protos/agent.proto` - 协议定义

