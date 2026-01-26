# 网络管理机制

## 概述

Kata Containers 的网络架构涉及：
1. **Host 网络配置**: CNI 插件配置网络
2. **VM 网络设备**: Hypervisor 创建虚拟网络设备
3. **Guest 网络配置**: Agent 在 Guest 中配置网络

## 1. 网络架构

### 整体架构

```
Container Manager (CNI)
    │
    │ CNI 配置
    │
Runtime
    │
    │ 网络命名空间创建
    │
Host Network Namespace
    │
    │ TAP/Bridge
    │
Hypervisor
    │
    │ virtio-net
    │
Guest VM
    │
    │ 网络接口
    │
Agent
    │
    │ 网络配置
    │
Container Network Namespace
```

### 网络层次

1. **Host 网络**: Host 系统的网络配置
2. **VM 网络**: VM 的网络命名空间和接口
3. **Container 网络**: 容器内的网络配置

## 2. CNI 集成

### CNI 插件

**支持**: 标准 CNI 插件

**常见插件**:
- `bridge`: 桥接网络
- `macvlan`: MACVLAN 网络
- `ipvlan`: IPVLAN 网络
- `flannel`: Flannel 网络
- `calico`: Calico 网络

### CNI 配置流程

1. **CNI 调用**:
   ```
   Container Manager → CNI Plugin: ADD
   ```

2. **网络命名空间创建**:
   ```
   CNI Plugin → Runtime: 创建网络命名空间
   ```

3. **网络接口创建**:
   ```
   CNI Plugin → Runtime: 创建 TAP/Bridge
   ```

4. **VM 启动**:
   ```
   Runtime → Hypervisor: 在网络命名空间中启动 VM
   ```

5. **网络设备创建**:
   ```
   Hypervisor → VM: 创建 virtio-net 设备
   ```

6. **Guest 网络配置**:
   ```
   Runtime → Agent: 配置网络接口
   Agent → Guest: 配置 IP、路由等
   ```

## 3. 网络设备类型

### virtio-net

**特点**: 标准 virtio 网络设备

**优势**:
- 高性能
- 低延迟
- 广泛支持

**配置**:
```toml
[hypervisor.qemu]
network_model = "virtio-net-pci"
```

### vhost-net

**特点**: 内核加速的 virtio-net

**优势**:
- 更高的性能
- 减少 VM 退出

**要求**:
- Host 内核支持 vhost-net
- 需要 TUN/TAP 设备

**配置**:
```toml
[hypervisor.qemu]
vhost_net = true
```

### vhost-user-net

**特点**: 用户空间实现的 vhost-net

**优势**:
- 更好的隔离
- 可扩展性

**用途**:
- DPDK 集成
- 高性能网络

## 4. 网络配置

### Host 端配置

**网络命名空间**:
- 每个 Sandbox 有独立的网络命名空间
- CNI 插件在命名空间中配置网络

**TAP/Bridge 设备**:
- TAP 设备用于 VM 连接
- Bridge 设备用于多 VM 连接

### Guest 端配置

**网络接口**:
- Agent 创建网络接口
- 配置 IP 地址
- 配置路由表

**DNS 配置**:
- 配置 DNS 服务器
- 配置 DNS 搜索域

## 5. 网络类型

### Pod 网络

**特点**:
- 每个 Pod 有独立的网络命名空间
- Pod 内的容器共享网络命名空间

**实现**:
- Kubernetes Pod 网络模型
- 通过 CNI 配置

### Host 网络

**特点**:
- 容器使用 Host 网络命名空间
- 没有网络隔离

**配置**:
```yaml
hostNetwork: true
```

### 服务网格集成

**支持**: 
- Istio
- Linkerd
- 其他服务网格

**实现**:
- Sidecar 容器
- 网络策略

## 6. 网络性能优化

### 大页内存

**用途**: 提高网络性能

**配置**:
```toml
[hypervisor.qemu]
memory_backing = "hugetlbfs"
```

### 多队列

**用途**: 提高网络并发性能

**配置**:
```toml
[hypervisor.qemu]
network_queues = 4
```

### SR-IOV

**用途**: 硬件加速网络

**实现**: VFIO 设备直通

**配置**:
```toml
[hypervisor.qemu]
enable_vfio = true
```

## 7. 网络安全

### 网络策略

**支持**: Kubernetes NetworkPolicy

**实现**:
- CNI 插件支持
- iptables 规则

### 防火墙

- Host 防火墙规则
- Guest 防火墙规则

### 网络隔离

- 网络命名空间隔离
- VLAN 隔离

## 8. 网络故障排查

### 常见问题

1. **网络不通**:
   - 检查网络命名空间
   - 检查网络接口配置
   - 检查路由表

2. **DNS 解析失败**:
   - 检查 DNS 配置
   - 检查 DNS 服务器可达性

3. **性能问题**:
   - 检查网络设备类型
   - 检查网络队列配置
   - 检查网络带宽

### 调试工具

- `ip netns`: 检查网络命名空间
- `ip addr`: 检查网络接口
- `ip route`: 检查路由表
- `ping`: 测试网络连通性
- `tcpdump`: 抓包分析

## 9. 网络管理 API

### Agent API

**AddInterface**:
```protobuf
message AddInterfaceRequest {
    string interface = 1;
    string ip = 2;
    // ...
}
```

**RemoveInterface**:
```protobuf
message RemoveInterfaceRequest {
    string interface = 1;
}
```

**UpdateRoutes**:
```protobuf
message UpdateRoutesRequest {
    repeated Route routes = 1;
}
```

## 10. 待深入研究

1. **CNI 集成**: CNI 插件如何与 Runtime 交互？
2. **网络性能**: 如何优化网络性能？
3. **多网络**: 如何支持多个网络接口？
4. **服务发现**: 服务发现如何工作？
5. **网络策略**: 网络策略如何实现？

## 11. 相关文件

- `src/agent/src/network.rs` - Agent 网络管理
- `src/runtime/virtcontainers/network.go` - Runtime 网络管理
- `src/runtime/virtcontainers/device/` - 网络设备管理
- `docs/design/architecture/networking.md` - 网络架构文档

