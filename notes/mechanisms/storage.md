# 存储管理机制

## 概述

Kata Containers 的存储架构涉及多个层次：
1. **Guest Image**: VM 的 rootfs，通过 DAX 映射
2. **Container Rootfs**: 容器镜像，通过 virtio-fs 挂载
3. **Volumes**: 持久化存储卷，通过 virtio-blk 或 virtio-scsi

## 1. Guest Image (VM Rootfs)

### DAX (Direct Access)

**目的**: 高效地将 guest image 映射到 VM

**实现方式**:
- **QEMU**: NVDIMM 设备（Non-Volatile Dual In-line Memory Module）
- **Cloud Hypervisor**: PMEM 设备（Persistent Memory）

**优势**:
- **零拷贝**: Guest 直接访问 Host 内存页
- **按需加载**: 通过 page fault 按需加载页面
- **共享内存**: Host 可以共享内存页

**配置**:
```toml
[hypervisor.qemu]
enable_nvdimm = true
```

### 内存映射

```
Host Memory
    │
    │ mmap(MAP_SHARED)
    │
Guest Image File
    │
    │ DAX Mapping
    │
Guest VM Memory
    │
    │ /dev/pmem0 or /dev/nvdimm0
    │
Guest Kernel
    │
    │ root=/dev/pmem0
    │
VM Rootfs
```

## 2. Container Rootfs

### virtio-fs (推荐)

**目的**: 在 Host 和 Guest 之间共享文件系统

**架构**:
```
Host
    │
    │ virtio-fs
    │
virtiofsd (daemon)
    │
    │ FUSE
    │
Host Filesystem
    │
    │ Container Image
```

**优势**:
- **高性能**: 优化的文件系统性能
- **共享**: 多个容器可以共享同一文件系统
- **实时更新**: Host 的文件更改可以实时反映到 Guest

**配置**:
```toml
[hypervisor.qemu]
shared_fs = "virtio-fs"
virtio_fs_daemon = "/usr/libexec/kata-qemu/virtiofsd"
```

### virtio-9p (传统，不推荐)

**目的**: 传统的文件系统共享方式

**限制**:
- 性能较低
- 功能有限

**配置**:
```toml
[hypervisor.qemu]
shared_fs = "9p"
```

### 挂载流程

1. **Host 端**:
   - Runtime 启动 virtiofsd
   - virtiofsd 挂载容器镜像目录

2. **Guest 端**:
   - Hypervisor 创建 virtio-fs 设备
   - Agent 挂载 virtio-fs 到容器目录
   - 容器使用挂载的文件系统

## 3. 存储卷 (Volumes)

### 块设备 (virtio-blk)

**用途**: 块存储卷

**设备类型**:
- 本地块设备
- 网络块设备（iSCSI、NFS 等）

**配置**:
```toml
[hypervisor.qemu]
block_device_driver = "virtio-blk"
```

**流程**:
1. Runtime 识别存储卷
2. Hypervisor 创建 virtio-blk 设备
3. Agent 在 Guest 中识别设备
4. Agent 挂载设备到容器

### SCSI 设备 (virtio-scsi)

**用途**: SCSI 存储卷（支持更多特性）

**优势**:
- 支持更多 SCSI 命令
- 更好的性能
- 支持热插拔

**配置**:
```toml
[hypervisor.qemu]
block_device_driver = "virtio-scsi"
```

### 直接块设备分配

**用途**: 将 Host 块设备直接分配给 Guest

**实现**: VFIO 设备直通

**配置**:
```toml
[hypervisor.qemu]
enable_vfio = true
```

## 4. 存储类型

### 临时存储 (Ephemeral Storage)

**特点**:
- 生命周期与容器相同
- 容器删除时自动清理

**用途**:
- 临时文件
- 缓存数据

### 持久化存储 (Persistent Storage)

**特点**:
- 生命周期独立于容器
- 数据持久保存

**实现**:
- Kubernetes PersistentVolume
- Docker Volume

### 只读存储 (Read-Only Storage)

**特点**:
- 只读访问
- 不能修改

**用途**:
- 容器镜像
- 配置文件

## 5. 存储管理流程

### 容器创建时的存储设置

1. **解析 OCI 配置**:
   - 识别挂载点
   - 识别存储卷

2. **Host 端准备**:
   - 准备容器镜像（如果需要）
   - 准备存储卷
   - 启动 virtiofsd（如果是 virtio-fs）

3. **Guest 端设置**:
   - Agent 挂载 rootfs
   - Agent 挂载存储卷
   - Agent 设置挂载点

### 存储卷热插拔

**支持**: Cloud Hypervisor, QEMU

**流程**:
1. Runtime 调用 Hypervisor API 添加设备
2. Hypervisor 热插拔设备到 VM
3. Agent 检测新设备
4. Agent 挂载设备

## 6. 存储性能优化

### 大页内存

**用途**: 提高内存访问性能

**配置**:
```toml
[hypervisor.qemu]
memory_backing = "hugetlbfs"
```

### 缓存策略

- **写回缓存**: 提高写入性能
- **直接 I/O**: 绕过页面缓存

### 存储后端优化

- **本地存储**: 使用本地 SSD
- **网络存储**: 使用高性能网络存储

## 7. 存储安全

### 加密

**支持**: 存储卷加密

**实现**:
- LUKS 加密
- 设备映射器加密

### 访问控制

- 文件权限
- SELinux 标签
- 用户/组权限

## 8. 存储故障排查

### 常见问题

1. **virtio-fs 挂载失败**:
   - 检查 virtiofsd 是否运行
   - 检查设备是否正确创建

2. **存储卷无法访问**:
   - 检查设备权限
   - 检查挂载点配置

3. **性能问题**:
   - 检查存储后端性能
   - 检查网络性能（如果是网络存储）

### 调试工具

- `kata-runtime exec`: 进入 VM 检查存储
- `mount`: 检查挂载点
- `lsblk`: 检查块设备

## 9. 待深入研究

1. **DAX 机制**: DAX 如何实现零拷贝？
2. **virtio-fs 性能**: virtio-fs 的性能优化？
3. **存储卷管理**: 存储卷的生命周期管理？
4. **加密存储**: 存储加密的实现机制？
5. **性能优化**: 如何优化存储性能？

## 10. 相关文件

- `src/agent/src/storage/` - Agent 存储管理
- `src/runtime/virtcontainers/storage.go` - Runtime 存储管理
- `src/runtime/virtcontainers/device/` - 设备管理
- `docs/design/architecture/storage.md` - 存储架构文档

