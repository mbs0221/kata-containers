# Runtime-rs 模块分析

## 概述

Runtime-rs 是 Kata Containers 3.0 引入的 Rust 版本运行时，目前仍在积极开发中。

**位置**: `src/runtime-rs/`  
**语言**: Rust  
**状态**: 开发中，不建议在生产环境使用  
**特点**: 
- 异步 I/O，减少资源消耗
- 可扩展框架，支持多种服务、运行时和 Hypervisor
- 内置 Dragonball Sandbox，开箱即用

## 架构设计

### 整体架构

```
┌─────────────────────────────────────────────────────────┐
│              containerd-shim-kata-v2 (Rust)              │
│  ┌───────────────────────────────────────────────────┐   │
│  │  Shim (shim crate)                                │   │
│  │  - containerd shimv2 二进制协议实现                │   │
│  │  - start/delete/run 命令处理                       │   │
│  └──────────────────────┬────────────────────────────┘   │
│                         │                                 │
│  ┌──────────────────────▼────────────────────────────┐   │
│  │  Service (service crate)                           │   │
│  │  - TaskService (containerd shim 协议)              │   │
│  │  - 消息处理                                        │   │
│  └──────────────────────┬────────────────────────────┘   │
│                         │                                 │
│  ┌──────────────────────▼────────────────────────────┐   │
│  │  Runtime (runtimes crate)                         │   │
│  │  - VirtContainer (当前唯一实现)                    │   │
│  │  - Sandbox/Container 生命周期管理                   │   │
│  └──────────────────────┬────────────────────────────┘   │
│                         │                                 │
│  ┌──────────────────────▼────────────────────────────┐   │
│  │  Resource (resource crate)                         │   │
│  │  - Sandbox 资源: network, share-fs                 │   │
│  │  - Container 资源: rootfs, volume, cgroup          │   │
│  └──────────────────────┬────────────────────────────┘   │
│                         │                                 │
│  ┌──────────────────────▼────────────────────────────┐   │
│  │  Hypervisor (hypervisor crate)                     │   │
│  │  - Dragonball (内置)                                │   │
│  │  - Cloud Hypervisor (开发中)                        │   │
│  └──────────────────────┬────────────────────────────┘   │
│                         │                                 │
│  ┌──────────────────────▼────────────────────────────┐   │
│  │  Agent (agent crate)                               │   │
│  │  - KataAgent (与 guest Agent 通信)                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Crates 结构

```
runtime-rs/
├── crates/
│   ├── shim/              # Shim v2 实现
│   ├── service/           # 服务层
│   ├── runtimes/           # 运行时实现
│   ├── resource/          # 资源管理
│   ├── hypervisor/        # Hypervisor 抽象
│   ├── agent/             # Agent 接口
│   └── persist/           # 状态持久化
└── ...
```

## 核心 Crates

### 1. shim crate

**功能**: containerd shim v2 二进制协议实现

**关键功能**:
- `start`: 启动新的 shim 进程
- `delete`: 删除 shim 进程
- `run`: 运行 ttRPC 服务

**实现**:
- 处理 containerd 的二进制协议
- 创建和管理 shim 进程
- 提供 ttRPC 服务器

### 2. service crate

**功能**: 服务层，实现 containerd shim 协议

**当前实现**:
- `TaskService`: containerd shim 协议实现

**关键操作**:
- `Create`: 创建任务（Sandbox/Container）
- `Start`: 启动任务
- `Delete`: 删除任务
- `Exec`: 执行命令
- `Wait`: 等待任务退出

**消息处理**:
- 接收来自 containerd 的请求
- 转换为运行时消息
- 调用运行时处理
- 返回响应

### 3. runtimes crate

**功能**: 容器运行时实现

**当前实现**:
- `VirtContainer`: 虚拟容器运行时

**关键功能**:
- Sandbox 生命周期管理
- Container 生命周期管理
- 与 Hypervisor 交互
- 与 Agent 通信

### 4. resource crate

**功能**: 资源抽象和管理

**资源类型**:

**Sandbox 资源**:
- `Network`: 网络资源
- `ShareFs`: 共享文件系统资源

**Container 资源**:
- `Rootfs`: 根文件系统
- `Volume`: 存储卷
- `Cgroup`: Cgroup 资源

**资源管理**:
- 资源创建
- 资源绑定
- 资源清理

### 5. hypervisor crate

**功能**: Hypervisor 抽象层

**当前实现**:
- `Dragonball`: 内置 VMM
- `CloudHypervisor`: Cloud Hypervisor 支持（开发中）

**Hypervisor Trait**:
```rust
pub trait Hypervisor: Send + Sync {
    fn start_vm(&mut self, timeout: i32) -> Result<()>;
    fn stop_vm(&mut self) -> Result<()>;
    fn pause_vm(&mut self) -> Result<()>;
    fn resume_vm(&mut self) -> Result<()>;
    // ...
}
```

### 6. agent crate

**功能**: 与 guest Agent 通信的库

**当前实现**:
- `KataAgent`: Kata Agent 客户端

**关键功能**:
- ttRPC 客户端实现
- Agent API 调用封装
- 错误处理

### 7. persist crate

**功能**: 状态持久化

**关键功能**:
- 定义持久化 trait
- 帮助组件保存和加载状态
- 支持 Sandbox/Container 状态持久化

## 关键特性

### 1. 异步 I/O

- 使用 Rust 异步运行时（tokio）
- 减少资源消耗
- 提高并发性能

### 2. 可扩展框架

- 服务扩展: 可以添加新的服务类型
- 运行时扩展: 可以添加新的运行时实现
- Hypervisor 扩展: 可以添加新的 Hypervisor

### 3. 内置 Dragonball

- 开箱即用的体验
- 无需外部 Hypervisor
- 优化的容器工作负载

### 4. 资源抽象

- 统一的资源管理接口
- 清晰的资源生命周期
- 易于扩展新资源类型

## 与 Go Runtime 的对比

| 特性 | Go Runtime | Runtime-rs |
|------|-----------|------------|
| 语言 | Go | Rust |
| 状态 | 生产就绪 | 开发中 |
| 异步 I/O | 有限支持 | 完整支持 |
| 内置 VMM | 否 | 是（Dragonball） |
| 资源管理 | 分散 | 统一抽象 |
| 扩展性 | 中等 | 高 |

## 开发状态

### 已实现功能

- Shim v2 基本功能
- Sandbox/Container 创建和启动
- Dragonball Hypervisor 集成
- 基本资源管理

### 开发中功能

- Cloud Hypervisor 支持
- 完整的资源管理
- 性能优化
- 功能对等（与 Go Runtime）

### 路线图

参见 [architecture_3.0 路线图](../docs/design/architecture_3.0/README.md#roadmap)

## 使用场景

### 当前适用场景

- 开发和测试
- 功能验证
- 性能测试

### 不适用场景

- 生产环境（功能不完整）
- 需要完整功能支持的环境
- 需要稳定性的关键系统

## 待深入研究

1. **异步架构**: 异步 I/O 如何提高性能？
2. **资源管理**: 资源抽象如何简化管理？
3. **扩展机制**: 如何添加新的服务/运行时/Hypervisor？
4. **状态持久化**: 状态如何保存和恢复？
5. **性能优化**: 相比 Go Runtime 的性能优势？

## 相关文档

- [Runtime-rs README](../src/runtime-rs/README.md)
- [Architecture 3.0](../docs/design/architecture_3.0/)

