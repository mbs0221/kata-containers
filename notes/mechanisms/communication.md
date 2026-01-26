# 通信机制分析

## 概述

Kata Containers 中的通信机制主要包括：
1. **Container Manager ↔ Runtime**: OCI Runtime Spec / containerd shim v2 API
2. **Runtime ↔ Agent**: ttRPC 协议（通过 VSOCK 或 virtio-serial）
3. **Runtime ↔ Hypervisor**: Hypervisor 特定 API（QMP、HTTP API 等）

## 1. Container Manager ↔ Runtime

### OCI Runtime Spec

**协议**: OCI Runtime Specification  
**传输**: Unix Domain Socket  
**格式**: JSON

**主要操作**:
- `create`: 创建容器
- `start`: 启动容器
- `kill`: 杀死容器
- `delete`: 删除容器
- `state`: 查询容器状态

### containerd Shim v2 API

**协议**: containerd shim v2 API  
**传输**: Unix Domain Socket  
**格式**: gRPC (ttRPC)

**架构优势**:
- **单进程模型**: 一个 shim 进程管理多个容器
- **双向通信**: 通过 Unix socket 进行双向通信
- **Pod 支持**: 一个 VM 可以运行多个容器

**主要操作**:
- `Create`: 创建任务（Sandbox/Container）
- `Start`: 启动任务
- `Delete`: 删除任务
- `Exec`: 执行命令
- `Wait`: 等待任务退出
- `Shutdown`: 关闭 shim

**关键文件**:
- `src/runtime/cmd/containerd-shim-kata-v2/` - Shim v2 实现
- `src/runtime/pkg/containerd-shim-v2/` - Shim v2 库

## 2. Runtime ↔ Agent

### ttRPC 协议

**协议**: ttRPC (基于 gRPC 的轻量级协议)  
**传输**: VSOCK 或 virtio-serial  
**格式**: Protocol Buffers

**ttRPC 特点**:
- **轻量级**: 相比标准 gRPC，减少序列化开销
- **Unix Domain Socket**: 支持本地通信
- **VSOCK**: 支持 VM 间通信

### 通信通道

#### VSOCK（默认）

**地址格式**: `vsock://-1:1024`

**优势**:
- 高性能
- 低延迟
- 专为 VM 间通信设计

**实现**:
- Host: 使用 VSOCK socket
- Guest: Agent 监听 VSOCK 端口

#### virtio-serial（备用）

**用途**: 当 VSOCK 不可用时使用

**实现**:
- Host: 通过 virtio-serial 设备
- Guest: Agent 监听串口设备

### 协议定义

**位置**: `src/libs/protocols/protos/agent.proto`

**主要服务**:

```protobuf
service AgentService {
    // Sandbox 管理
    rpc CreateSandbox(CreateSandboxRequest) returns (CreateSandboxResponse);
    rpc DestroySandbox(DestroySandboxRequest) returns (DestroySandboxResponse);
    
    // Container 管理
    rpc CreateContainer(CreateContainerRequest) returns (CreateContainerResponse);
    rpc StartContainer(StartContainerRequest) returns (StartContainerResponse);
    rpc StopContainer(StopContainerRequest) returns (StopContainerResponse);
    rpc RemoveContainer(RemoveContainerRequest) returns (RemoveContainerResponse);
    
    // 进程管理
    rpc ExecProcess(ExecProcessRequest) returns (ExecProcessResponse);
    rpc SignalProcess(SignalProcessRequest) returns (SignalProcessResponse);
    rpc WaitProcess(WaitProcessRequest) returns (WaitProcessResponse);
    
    // I/O 流
    rpc ReadStdout(ReadStreamRequest) returns (ReadStreamResponse);
    rpc ReadStderr(ReadStreamRequest) returns (ReadStreamResponse);
    rpc WriteStdin(WriteStreamRequest) returns (WriteStreamResponse);
    
    // 资源管理
    rpc UpdateContainer(UpdateContainerRequest) returns (UpdateContainerResponse);
    rpc UpdateEphemeralMounts(UpdateEphemeralMountsRequest) returns (UpdateEphemeralMountsResponse);
    
    // 网络管理
    rpc AddInterface(AddInterfaceRequest) returns (AddInterfaceResponse);
    rpc RemoveInterface(RemoveInterfaceRequest) returns (RemoveInterfaceResponse);
    rpc UpdateRoutes(UpdateRoutesRequest) returns (UpdateRoutesResponse);
    
    // 存储管理
    rpc AddStorage(AddStorageRequest) returns (AddStorageResponse);
    rpc RemoveStorage(RemoveStorageRequest) returns (RemoveStorageResponse);
}
```

### 通信流程

#### Sandbox 创建

```
Runtime → Agent: CreateSandbox
  - Sandbox ID
  - 网络配置
  - 共享文件系统配置
Agent → Runtime: Sandbox Created
  - Sandbox ID
```

#### Container 创建

```
Runtime → Agent: CreateContainer
  - Container ID
  - OCI 配置
  - Rootfs 路径
Agent → Runtime: Container Created
  - Container ID
```

#### Container 启动

```
Runtime → Agent: StartContainer
  - Container ID
Agent → Runtime: Container Started
```

#### 进程等待

```
Runtime → Agent: WaitProcess (阻塞调用)
Agent → Runtime: Process Exited
  - Exit Code
```

### 标准 I/O 流

**stdout/stderr 读取**:
```
Runtime → Agent: ReadStdout/ReadStderr (阻塞调用)
Agent → Runtime: Data Available
  - Data
```

**stdin 写入**:
```
Runtime → Agent: WriteStdin
  - Data
Agent → Runtime: Written
```

### 错误处理

**错误类型**:
- 网络错误: VSOCK 连接失败
- 协议错误: 消息格式错误
- 业务错误: Agent 返回的错误

**重试机制**:
- 连接重试
- 请求重试（可配置）

## 3. Runtime ↔ Hypervisor

### QEMU (QMP)

**协议**: QEMU Machine Protocol (QMP)  
**传输**: Unix Domain Socket  
**格式**: JSON

**主要操作**:
- `query-kvm`: 查询 KVM 支持
- `query-machines`: 查询机器类型
- `migrate`: 迁移 VM
- `migrate-incoming`: 接收迁移
- `query-migration`: 查询迁移状态

**关键文件**:
- `src/runtime/pkg/govmm/qemu/qmp.go` - QMP 实现

### Cloud Hypervisor (HTTP API)

**协议**: HTTP REST API  
**传输**: HTTP  
**格式**: JSON

**主要操作**:
- `PUT /vm.boot`: 启动 VM
- `PUT /vm.shutdown`: 关闭 VM
- `PUT /vm.pause`: 暂停 VM
- `PUT /vm.resume`: 恢复 VM
- `PUT /vm.migrate`: 迁移 VM

**关键文件**:
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/` - HTTP 客户端

### Dragonball (Rust API)

**协议**: Rust API（进程内调用）  
**传输**: 函数调用  
**格式**: Rust 类型

**主要操作**:
- `ConfigureBootSource`: 配置启动源
- `SetVmConfiguration`: 设置 VM 配置
- `AddNetworkDevice`: 添加网络设备
- `AddBlockDevice`: 添加块设备
- `StartMicrovm`: 启动 VM

**关键文件**:
- `src/dragonball/src/api/` - API 定义
- `src/runtime-rs/crates/hypervisor/dragonball/` - Dragonball 集成

## 4. 通信优化

### 连接池

- 复用 VSOCK 连接
- 减少连接开销

### 异步 I/O

- Runtime-rs 使用异步 I/O
- 提高并发性能

### 批量操作

- 批量发送请求
- 减少通信次数

## 5. 安全考虑

### 认证

- VSOCK 提供基本的隔离
- 可以添加额外的认证机制

### 加密

- 当前未加密（本地通信）
- 可以添加 TLS 支持

### 访问控制

- Agent 策略引擎（OPA）
- 限制 API 调用

## 6. 调试和故障排查

### 日志

- 启用详细日志
- 记录通信消息

### 工具

- `agent-ctl`: Agent 控制工具
- `kata-runtime exec`: 进入 VM 调试

### 常见问题

1. **VSOCK 连接失败**: 检查 VSOCK 支持
2. **协议错误**: 检查协议版本兼容性
3. **超时**: 检查网络和性能

## 7. 待深入研究

1. **ttRPC 实现**: ttRPC 与 gRPC 的差异？
2. **VSOCK 性能**: VSOCK 的性能特征？
3. **错误恢复**: 通信失败时的恢复机制？
4. **流控**: 如何控制通信流量？
5. **监控**: 如何监控通信性能？

## 8. 相关文件

- `src/libs/protocols/protos/agent.proto` - Agent 协议定义
- `src/agent/src/rpc.rs` - Agent RPC 服务器
- `src/runtime/pkg/agent/` - Runtime Agent 客户端
- `src/runtime-rs/crates/agent/` - Runtime-rs Agent 客户端
- `src/tools/agent-ctl/` - Agent 控制工具

