# 容器迁移机制

## 概述

Kata Containers 中的容器迁移主要涉及两个方面：
1. **VM 模板机制** - 用于快速启动新容器（冷启动优化）
2. **实时迁移** - 在运行的 VM 之间迁移（热迁移，目前主要支持 Cloud Hypervisor）

## 1. VM 模板机制（Template）

### 核心概念

VM 模板是一种优化技术，通过预先创建一个"模板 VM"并保存其状态，后续可以快速克隆出新的 VM，从而大幅减少容器启动时间。

### 关键组件

#### Factory 机制

**位置**: `src/runtime/virtcontainers/factory/`

**Factory 类型**:
- `Template Factory`: 基于模板的 VM 创建
- `Direct Factory`: 直接创建 VM（不使用模板）
- `Cache Factory`: 带缓存的 VM 创建
- `VMCache`: 基于 gRPC 的 VM 缓存服务

#### 模板创建流程

1. **创建模板 VM** (`template_linux.go::createTemplateVM()`)
   ```
   - 设置 BootToBeTemplate = true
   - 创建 VM 并启动
   - 暂停 VM (vm.Pause())
   - 保存 VM 状态 (vm.Save())
   - 状态保存在 templatePath/memory 和 templatePath/state
   ```

2. **从模板克隆 VM** (`template_linux.go::createFromTemplateVM()`)
   ```
   - 设置 BootFromTemplate = true
   - 使用 QEMU 的 migration incoming 机制
   - 从保存的状态文件恢复 VM
   ```

### QEMU 迁移机制

#### 保存状态

使用 QEMU 的 `migrate` 命令，通过 `exec:cat > file` 保存到文件：

```go
// 保存 VM 状态
migrateCmd := &govmmQemu.MigrateCommand{
    Exec: &govmmQemu.MigrateExecCommand{
        Env: []string{"cat", ">", statePath},
    },
}
```

#### 恢复状态

使用 `migrate-incoming` 命令，通过 `exec:cat file` 从文件恢复：

```go
// 从文件恢复 VM 状态
migrateIncomingCmd := &govmmQemu.MigrateIncomingCommand{
    Exec: &govmmQemu.MigrateExecCommand{
        Env: []string{"cat", statePath},
    },
}
```

#### 共享内存处理

模板机制需要忽略共享内存迁移能力 (`setIgnoreSharedMemoryMigrationCaps`)，因为模板 VM 的内存是共享的。

### 关键代码位置

- `src/runtime/virtcontainers/factory/factory.go` - Factory 接口
- `src/runtime/virtcontainers/factory/factory_linux.go` - Factory 实现
- `src/runtime/virtcontainers/factory/template/template_linux.go` - 模板实现
- `src/runtime/virtcontainers/qemu.go::SaveVM()` - 保存 VM 状态
- `src/runtime/virtcontainers/qemu.go::bootFromTemplate()` - 从模板启动
- `src/runtime/virtcontainers/vm.go::Save()` - VM 保存接口

### QMP 迁移命令

**位置**: `src/runtime/pkg/govmm/qemu/qmp.go`

**关键函数**:
- `ExecSetMigrateArguments()` - 设置迁移参数
- `ExecuteMigrationIncoming()` - 接收迁移
- `ExecuteQueryMigration()` - 查询迁移状态

### 模板优势

- **快速启动**: 避免完整的 VM 启动过程
- **资源优化**: 共享内存页（Copy-on-Write）
- **并发启动**: 支持多个 VM 并发克隆

### 模板限制

- **内存共享**: 模板 VM 的内存是共享的，需要特殊处理
- **设备状态**: 某些设备状态可能无法完全保存
- **Hypervisor 支持**: 主要支持 QEMU

## 2. 实时迁移（Live Migration）

### 当前支持状态

- **Cloud Hypervisor**: 支持实时迁移（通过 API）
- **QEMU**: 主要支持模板机制，实时迁移支持有限
- **Dragonball**: 目前不支持迁移

### Cloud Hypervisor 迁移

#### API 接口

**发送迁移** (`SendMigrationData`):
```rust
SendMigrationData {
    destination_url: String,  // 目标 URL
    local: bool,              // 是否为本地迁移
}
```

**接收迁移** (`ReceiveMigrationData`):
```rust
ReceiveMigrationData {
    receiver_url: String,     // 接收器 URL
}
```

#### 关键代码位置

- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/api_default.go`
  - `SendVMCommand()` - 发送迁移命令
  - `ReceiveVMCommand()` - 接收迁移命令
- `src/runtime/virtcontainers/clh.go` - Cloud Hypervisor 实现

#### 迁移流程

1. **源端**: 调用 `SendMigrationData` 开始迁移
2. **目标端**: 调用 `ReceiveMigrationData` 准备接收
3. **数据传输**: 迁移数据通过 URL 指定的通道传输（如 HTTP、TCP 等）
4. **状态同步**: 同步内存和设备状态
5. **切换**: 切换到目标 VM
6. **清理**: 清理源 VM

### 迁移数据

迁移数据包括：
- **内存状态**: Guest 内存的完整快照
- **CPU 状态**: VCPU 寄存器状态
- **设备状态**: 虚拟设备的状态
- **其他状态**: 其他 VM 状态信息

## 3. 迁移研究路线图

### 阶段 1: 理解现有机制

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

### 阶段 2: 深入理解迁移原理

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

### 阶段 3: 实现改进或新功能

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

## 4. 关键文件清单

### Factory 和模板

- `src/runtime/virtcontainers/factory/factory.go` - Factory 接口
- `src/runtime/virtcontainers/factory/factory_linux.go` - Factory 实现
- `src/runtime/virtcontainers/factory/template/template_linux.go` - 模板实现
- `src/runtime/virtcontainers/factory/base/base.go` - 基础接口

### QEMU 迁移

- `src/runtime/virtcontainers/qemu.go` - QEMU hypervisor 实现
  - `SaveVM()` - 保存 VM 状态
  - `bootFromTemplate()` - 从模板启动
  - `waitMigration()` - 等待迁移完成
- `src/runtime/pkg/govmm/qemu/qmp.go` - QMP 命令实现
  - `ExecSetMigrateArguments()` - 设置迁移参数
  - `ExecuteMigrationIncoming()` - 接收迁移
  - `ExecuteQueryMigration()` - 查询迁移状态

### Cloud Hypervisor 迁移

- `src/runtime/virtcontainers/clh.go` - Cloud Hypervisor 实现
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/api_default.go` - API 实现
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/SendMigrationData.md` - 发送迁移 API
- `src/runtime/virtcontainers/pkg/cloud-hypervisor/client/docs/ReceiveMigrationData.md` - 接收迁移 API

### VM 管理

- `src/runtime/virtcontainers/vm.go` - VM 接口和实现
  - `NewVM()` - 创建新 VM
  - `Save()` - 保存 VM
  - `Pause()` - 暂停 VM
- `src/runtime/virtcontainers/hypervisor.go` - Hypervisor 接口

## 5. 待深入研究的问题

### 模板机制

1. **内存共享**: 模板 VM 的内存如何共享？
2. **隔离性**: 从模板克隆的 VM 如何保证隔离？
3. **模板更新**: 模板更新机制是什么？
4. **性能影响**: 模板机制对性能的影响？

### 实时迁移

1. **网络连接**: 迁移过程中的网络连接如何处理？
2. **存储设备**: 存储设备如何迁移？
3. **迁移失败**: 迁移失败时的回滚机制？
4. **性能影响**: 迁移对性能的影响？

### 性能优化

1. **停机时间**: 如何减少迁移停机时间？
2. **数据传输**: 如何优化迁移数据传输？
3. **增量迁移**: 如何支持增量迁移？
4. **并发迁移**: 如何支持多个 VM 并发迁移？

### Dragonball 迁移

1. **接口设计**: 如何在 Dragonball 中设计迁移接口？
2. **状态保存**: Dragonball 的状态如何保存？
3. **状态恢复**: Dragonball 的状态如何恢复？
4. **差异分析**: 与 QEMU 迁移的差异是什么？

## 6. 实验建议

### 实验 1: 创建和使用模板

1. 配置 Kata 使用模板模式
2. 创建模板 VM
3. 从模板创建多个容器
4. 测量启动时间差异

### 实验 2: 理解迁移数据

1. 使用 QEMU 保存 VM 状态
2. 分析状态文件内容
3. 理解内存和设备状态的保存格式

### 实验 3: Cloud Hypervisor 迁移

1. 启动两个 Cloud Hypervisor VM
2. 执行迁移操作
3. 观察迁移过程
4. 分析迁移性能

## 7. 参考资料

- [QEMU 迁移文档](https://www.qemu.org/docs/master/devel/migration.html)
- [Cloud Hypervisor 迁移文档](https://github.com/cloud-hypervisor/cloud-hypervisor)
- Kata Containers 设计文档中的迁移相关章节

