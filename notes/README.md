# Kata Containers 源码阅读笔记

本目录包含 Kata Containers 项目的系统性源码阅读笔记和架构分析。

## 笔记结构

- [架构概述](./architecture-overview.md) - Kata Containers 整体架构分析
- [核心组件](./components/) - 各核心组件的详细分析
  - [Agent](./components/agent.md) - Agent 模块分析
  - [Runtime](./components/runtime.md) - Go Runtime 分析
  - [Runtime-rs](./components/runtime-rs.md) - Rust Runtime 分析
  - [Dragonball](./components/dragonball.md) - Dragonball VMM 分析
- [关键机制](./mechanisms/) - 关键机制深入分析
  - [容器迁移](./mechanisms/migration.md) - VM 模板和实时迁移机制
  - [通信机制](./mechanisms/communication.md) - Runtime-Agent 通信
  - [存储管理](./mechanisms/storage.md) - 存储和文件系统
  - [网络管理](./mechanisms/network.md) - 网络配置和管理
- [源码阅读记录](./source-reading.md) - 详细的源码阅读记录和待办事项

## 快速导航

### 核心概念

- **Sandbox**: 虚拟机实例，包含一个或多个容器
- **Container**: 运行在 Sandbox 内的容器实例
- **Agent**: 运行在 guest VM 内部的代理进程
- **Runtime**: 运行在 host 的运行时组件（shim）
- **Hypervisor/VMM**: 虚拟化管理器（QEMU、Cloud Hypervisor、Dragonball 等）

### 架构层次

```
Container Manager (containerd/CRI-O)
    ↓
Kata Runtime (shimv2)
    ↓
Hypervisor (QEMU/CH/Dragonball)
    ↓
Guest VM
    ↓
Agent
    ↓
Container(s)
```

## 参考资料

- [Kata Containers 官方文档](https://katacontainers.io)
- [架构设计文档](../docs/design/architecture/)
- [开发者指南](../docs/Developer-Guide.md)

