# Dragonball 架构详解

## 概述

Dragonball 是 Kata Containers 3.0 内置的轻量级虚拟化管理器（VMM），使用 Rust 编写，基于 Linux KVM。它专门为容器工作负载优化，具有以下特点：

- **轻量级**: 低 CPU 和内存开销
- **快速启动**: 最小化启动时间
- **高性能**: 优化的并发启动速度
- **容器优化**: 针对容器镜像管理和加速服务优化
- **灵活设备**: 高性能虚拟设备驱动

## 整体架构

### 对象模型

```
Vmm (VMM 管理器)
    │
    ├─> 1:1 -> API Server (HTTP/ttRPC)
    │
    ├─> 1:N -> Vm (虚拟机实例)
    │   │
    │   ├─> 1:1 -> AddressSpaceManager (地址空间管理)
    │   │       └─> 1:N -> GuestMemory (Guest 内存)
    │   │
    │   ├─> 1:1 -> DeviceManager (设备管理)
    │   │       └─> 1:N -> Device (虚拟设备)
    │   │
    │   ├─> 1:1 -> ResourceManager (资源管理)
    │   │
    │   └─> 1:N -> Vcpu (虚拟 CPU)
    │
    └─> 1:N -> EventManager (事件管理)
```

### 核心组件层次

```
┌─────────────────────────────────────────────────────────┐
│                    API Layer                             │
│  (HTTP/ttRPC API Server, VmmService)                     │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    VMM Layer                            │
│  (Vmm, EventManager, EpollManager)                      │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    VM Layer                              │
│  (Vm, VcpuManager, DeviceManager, AddressSpaceManager)  │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    KVM Layer                            │
│  (KvmContext, VmFd, VcpuFd, KVM ioctls)                │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    Linux Kernel                         │
│  (KVM, /dev/kvm)                                        │
└─────────────────────────────────────────────────────────┘
```

## 核心组件详解

### 1. VMM (Virtual Machine Monitor)

**文件**: `src/dragonball/src/vmm.rs`

**职责**:
- 全局协调器，管理 API 服务器、虚拟机、升级等
- 管理事件循环
- 协调多个 VM 实例（当前支持 1:1，未来支持 1:N）

**关键结构**:

```rust
pub struct Vmm {
    pub(crate) event_ctx: EventContext,      // 事件上下文
    epoll_manager: EpollManager,             // Epoll 管理器
    vm: Vm,                                  // 虚拟机实例
    seccomp_filters: HashMap<String, BpfProgram>,  // Seccomp 过滤器
}
```

**主要方法**:
- `new()`: 创建 VMM 实例
- `run_vmm_event_loop()`: 运行事件循环，处理 API 请求
- `stop()`: 停止 VMM

**事件循环**:

```rust
pub fn run_vmm_event_loop(vmm: Arc<Mutex<Vmm>>, mut service: VmmService) -> i32 {
    let mut event_mgr = EventManager::new(&vmm, epoll_mgr)?;
    
    'poll: loop {
        match event_mgr.handle_events(-1) {
            Ok(_) => {
                // 处理 API 事件
                if v.event_ctx.api_event_triggered {
                    service.run_vmm_action(&mut v, &mut event_mgr)?;
                }
                // 处理退出事件
                if v.event_ctx.exit_evt_triggered {
                    return v.stop(EXIT_CODE_OK);
                }
            }
            Err(e) => {
                // 错误处理
                return v.stop(EXIT_CODE_GENERIC_ERROR);
            }
        }
    }
}
```

### 2. VM (Virtual Machine)

**文件**: `src/dragonball/src/vm/mod.rs`

**职责**:
- 管理单个虚拟机实例
- 协调地址空间、设备、VCPU 等组件
- 处理虚拟机生命周期（创建、启动、停止）

**关键结构**:

```rust
pub struct Vm {
    kvm: KvmContext,                         // KVM 上下文
    vm_fd: Arc<VmFd>,                        // VM 文件描述符
    resource_manager: Arc<ResourceManager>, // 资源管理器
    device_manager: DeviceManager,           // 设备管理器
    address_space: AddressSpaceMgr,         // 地址空间管理器
    vcpu_manager: Option<VcpuManager>,      // VCPU 管理器
    vm_config: VmConfigInfo,                // VM 配置
    shared_info: Arc<RwLock<InstanceInfo>>, // 共享信息
    // ...
}
```

**主要方法**:
- `new()`: 创建 VM 实例
- `start_microvm()`: 启动微虚拟机
- `init_microvm()`: 初始化微虚拟机
- `init_guest_memory()`: 初始化 Guest 内存
- `init_devices()`: 初始化设备

### 3. AddressSpaceManager (地址空间管理器)

**文件**: `src/dragonball/src/address_space_manager.rs`

**职责**:
- 管理虚拟机的物理地址空间
- 分配和映射 Guest 内存
- 管理 MMIO 地址范围
- 支持 NUMA 配置

**地址空间用途**:
1. **Guest 虚拟内存映射**: 映射 Guest 物理内存
2. **MMIO 范围**: 虚拟设备的 MMIO 地址（如 virtio-fs DAX 窗口）
3. **直通设备**: PCI 设备 BAR 的 MMIO 映射
4. **vCPU 相关**: 本地 APIC 等 vCPU 专用 MMIO

**关键类型**:

```rust
// Guest 地址空间实现
pub type GuestAddressSpaceImpl = Arc<GuestMemoryMmap>;

// Guest 内存实现
pub type GuestMemoryImpl = <Arc<GuestMemoryMmap> as GuestAddressSpace>::M;
```

**内存管理**:
- 支持多种内存类型：`hugetlbfs`、`shmem`、匿名内存
- 支持内存预分配
- 支持 NUMA 节点配置
- 管理 KVM 内存槽

### 4. DeviceManager (设备管理器)

**文件**: `src/dragonball/src/device_manager/mod.rs`

**职责**:
- 管理所有虚拟设备
- 处理设备热插拔
- 管理设备资源分配
- 处理设备 IO 操作

**关键结构**:

```rust
pub struct DeviceManager {
    io_manager: Arc<ArcSwap<IoManager>>,    // IO 管理器（支持热插拔）
    io_lock: Arc<Mutex<()>>,                // IO 锁
    irq_manager: Arc<KvmIrqManager>,       // 中断管理器
    res_manager: Arc<ResourceManager>,      // 资源管理器
    vm_fd: Arc<VmFd>,                       // VM 文件描述符
    
    // 各种设备管理器
    con_manager: ConsoleManager,            // 控制台管理器
    legacy_manager: Option<LegacyDeviceManager>,  // 传统设备管理器
    block_manager: BlockDeviceMgr,          // 块设备管理器
    virtio_net_manager: VirtioNetDeviceMgr, // Virtio 网络设备管理器
    fs_manager: Arc<Mutex<FsDeviceMgr>>,   // 文件系统设备管理器
    vsock_manager: VsockDeviceMgr,         // VSock 设备管理器
    mem_manager: MemDeviceMgr,              // 内存设备管理器
    balloon_manager: BalloonDeviceMgr,      // Balloon 设备管理器
    vfio_manager: Arc<Mutex<VfioDeviceMgr>>,  // VFIO 设备管理器
    pci_system_manager: Arc<Mutex<PciSystemManager>>,  // PCI 系统管理器
}
```

**支持的设备类型**:

1. **Virtio 设备**:
   - `virtio-blk`: 块设备
   - `virtio-net`: 网络设备
   - `virtio-fs`: 文件系统设备
   - `virtio-vsock`: VSock 设备
   - `virtio-mem`: 内存设备
   - `virtio-balloon`: Balloon 设备

2. **传统设备**:
   - Serial/Console: 串口和控制台
   - RTC: 实时时钟
   - i8042: 键盘控制器

3. **直通设备**:
   - VFIO PCI 设备

4. **vhost 设备**:
   - `vhost-net`: vhost 网络后端
   - `vhost-user-net`: vhost-user 网络后端

### 5. ResourceManager (资源管理器)

**文件**: `src/dragonball/src/resource_manager.rs`

**职责**:
- 管理虚拟机的所有资源
- 分配和释放资源
- 防止资源冲突

**管理的资源类型**:

1. **中断资源**:
   - Legacy IRQ: 传统中断（5-15 for x86_64）
   - MSI IRQ: 消息信号中断（24-1023）
   - 共享 IRQ: IRQ 5（用于多个设备共享）

2. **IO 地址空间**:
   - PIO (Port I/O): 端口映射 IO（0x0-0xFFFF）
   - MMIO (Memory-Mapped IO): 内存映射 IO

3. **内存资源**:
   - Guest 物理内存地址范围
   - KVM 内存槽号（x86_64: 509, aarch64: 512）

**资源分配算法**:

使用 `IntervalTree` 数据结构管理资源池：

```rust
pub struct ResourceManager {
    legacy_irq_pool: Mutex<IntervalTree<()>>,  // Legacy IRQ 池
    msi_irq_pool: Mutex<IntervalTree<()>>,     // MSI IRQ 池
    pio_pool: Mutex<IntervalTree<()>>,        // PIO 地址池
    mmio_pool: Mutex<IntervalTree<()>>,        // MMIO 地址池
    mem_pool: Mutex<IntervalTree<()>>,        // 内存地址池
    kvm_mem_slot_pool: Mutex<IntervalTree<()>>,  // KVM 内存槽池
}
```

**资源分配示例**:

```rust
// 分配 Legacy IRQ
let irq = resource_manager.allocate_legacy_irq(shared: false, fixed: None)?;

// 分配 MMIO 地址
let mmio_base = resource_manager.allocate_mmio_address_aligned(size, align)?;

// 分配设备资源
let resources = resource_manager.allocate_device_resources(&constraints, shared_irq)?;
```

### 6. VcpuManager (VCPU 管理器)

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs`

**职责**:
- 管理所有 VCPU
- 创建和销毁 VCPU
- 控制 VCPU 生命周期（启动、暂停、恢复、退出）
- 处理 VCPU 热插拔

**关键结构**:

```rust
pub struct VcpuManager {
    vcpu_infos: Vec<VcpuInfo>,              // VCPU 信息列表
    vcpu_config: VcpuConfig,                // VCPU 配置
    vm_fd: Arc<VmFd>,                       // VM 文件描述符
    vm_as: GuestAddressSpaceImpl,          // Guest 地址空间
    io_manager: Option<IoManagerCached>,    // IO 管理器
    shared_info: Arc<RwLock<InstanceInfo>>, // 共享信息
    // ...
}
```

**VCPU 状态机**:

```
Paused → Running → WaitingExit → Exited
   ↑         ↓
   └─────────┘
```

**VCPU 线程模型**:
- 每个 VCPU 运行在独立的线程中
- 线程名: `vcpu-{index}`
- 每个线程运行 `KVM_RUN` 循环

### 7. IoManager (IO 管理器)

**文件**: `src/dragonball/src/io_manager.rs`

**职责**:
- 处理 Guest 的 IO 操作（PIO 和 MMIO）
- 路由 IO 请求到相应的设备
- 支持设备热插拔（使用 `ArcSwap`）

**关键特性**:
- **热插拔支持**: 使用 `ArcSwap` 和 `Cache` 实现无锁设备更新
- **IO 路由**: 根据地址将 IO 请求路由到正确的设备
- **性能优化**: 缓存设备查找结果

**IO 处理流程**:

```
Guest IO 操作
    ↓
KVM_EXIT_IO / KVM_EXIT_MMIO
    ↓
VCPU 线程
    ↓
IoManager
    ↓
Device::read() / Device::write()
```

### 8. EventManager (事件管理器)

**文件**: `src/dragonball/src/event_manager.rs`

**职责**:
- 管理 VMM 事件循环
- 处理 API 请求事件
- 处理退出事件
- 集成 EpollManager

**关键结构**:

```rust
pub struct EventManager {
    epoll_mgr: EpollManager,                // Epoll 管理器
    subscriber_id: SubscriberId,            // 订阅者 ID
    vmm_event_count: Arc<AtomicUsize>,     // VMM 事件计数
}
```

**事件类型**:
- `EPOLL_EVENT_EXIT`: 退出事件
- `EPOLL_EVENT_API_REQUEST`: API 请求事件

## 子模块架构

### dbs_arch (架构相关)

**位置**: `dbs_arch/`

**职责**: CPU 架构特定的常量和工具

**支持架构**:
- **x86_64**: CPUID、MSR、GDT、中断处理
- **aarch64**: 寄存器、GIC、PMU

**关键组件**:
- `cpuid/`: CPUID 配置和转换
- `msr.rs`: MSR（Model-Specific Register）管理
- `regs.rs`: 寄存器设置
- `gic/`: GIC（Generic Interrupt Controller）支持

### dbs_boot (启动相关)

**位置**: `dbs_boot/`

**职责**: 虚拟机启动配置

**组件**:
- **x86_64**: MPSpec、MPTable、BootParam
- **aarch64**: FDT（Flattened Device Tree）

### dbs_device (设备抽象)

**位置**: `dbs_device/`

**职责**: 设备抽象和 IO 管理

**组件**:
- `device_manager.rs`: 设备管理器接口
- `resources.rs`: 设备资源定义

### dbs_interrupt (中断管理)

**位置**: `dbs_interrupt/`

**职责**: 中断管理

**组件**:
- `manager.rs`: 中断管理器
- `kvm/`: KVM 中断处理（Legacy、MSI、MSI-X）

### dbs_pci (PCI 支持)

**位置**: `dbs_pci/`

**职责**: PCI 总线和设备管理

**组件**:
- `bus.rs`: PCI 总线
- `device.rs`: PCI 设备
- `virtio_pci.rs`: Virtio PCI 设备
- `vfio.rs`: VFIO PCI 设备

### dbs_virtio_devices (Virtio 设备)

**位置**: `dbs_virtio_devices/`

**职责**: Virtio 设备实现

**支持的设备**:
- `block/`: Virtio Block 设备
- `net.rs`: Virtio Net 设备
- `fs/`: Virtio FS 设备
- `vsock/`: Virtio VSock 设备
- `balloon.rs`: Virtio Balloon 设备
- `mem.rs`: Virtio Mem 设备
- `mmio/`: MMIO 传输层
- `vhost/`: vhost 后端支持

### dbs_address_space (地址空间)

**位置**: `dbs_address_space/`

**职责**: 地址空间抽象和管理

**组件**:
- `address_space.rs`: 地址空间接口
- `region.rs`: 地址空间区域
- `memory/`: 内存管理（hybrid、raw_region）
- `numa.rs`: NUMA 支持

### dbs_utils (工具库)

**位置**: `dbs_utils/`

**职责**: 通用工具

**组件**:
- `epoll_manager.rs`: Epoll 事件管理
- `rate_limiter.rs`: 速率限制器
- `time.rs`: 时间工具
- `net/`: 网络工具（TAP、MAC 地址等）

### dbs_upcall (Upcall 机制)

**位置**: `dbs_upcall/`

**职责**: Upcall 机制，用于 Host 和 Guest 之间的通信

**用途**:
- 设备热插拔通知
- 设备管理请求
- Host-Guest 通信

## 数据流

### 1. VM 创建流程（详细版）

#### 1.1 入口：start_microvm()

**文件**: `src/dragonball/src/vm/mod.rs`

```rust
pub fn start_microvm(
    &mut self,
    event_mgr: &mut EventManager,
    seccomp_filters: HashMap<String, BpfProgram>,
) -> Result<(), StartMicroVmError>
```

**详细步骤**:

```
1. 应用 Seccomp 过滤器
   ├─> apply_filter_all_threads(process_seccomp_filter)
   └─> 如果失败且不是 EmptyFilter，返回错误

2. 检查 VM 状态
   └─> is_vm_initialized()? 如果已初始化，返回 MicroVMAlreadyRunning

3. 记录启动时间戳
   ├─> request_ts = TimestampUs::default()
   ├─> start_instance_request_ts = request_ts.time_us
   └─> start_instance_request_cpu_ts = request_ts.cputime_us

4. 初始化 dmesg logger
   └─> init_dmesg_logger()

5. 健康检查
   └─> check_health()?

6. 更新状态为 Starting
   └─> shared_info.state = InstanceState::Starting

7. 初始化 Guest 内存 ⭐
   └─> init_guest_memory() (见 1.2)

8. 获取 Guest 地址空间
   └─> vm_as = vm_as().cloned()?

9. 初始化 VCPU 管理器 ⭐
   └─> init_vcpu_manager(vm_as, vcpu_seccomp_filter) (见 1.3)

10. 初始化 MicroVM ⭐
    └─> init_microvm(epoll_mgr, vm_as, request_ts) (见 1.4)

11. 配置系统 ⭐
    └─> init_configure_system(&vm_as) (见 1.5)

12. 初始化 Upcall (如果启用)
    └─> init_upcall()?

13. 注册事件
    └─> register_events(event_mgr)?

14. 启动 VCPU 线程 ⭐
    └─> vcpu_manager().start_boot_vcpus(seccomp_filter) (见 1.6)

15. 更新状态为 Running
    └─> shared_info.state = InstanceState::Running
```

#### 1.2 初始化 Guest 内存：init_guest_memory()

**文件**: `src/dragonball/src/vm/mod.rs:551`

**详细流程**:

```
1. 检查是否已初始化
   └─> if address_space.is_initialized() { return Ok(()) }

2. 计算内存大小
   └─> mem_size = (vm_config.mem_size_mib as u64) << 20

3. 确定内存类型和路径
   ├─> mem_type = vm_config.mem_type.clone()
   └─> if mem_type == "hugetlbfs" {
           mem_file_path = "{mem_file_path}/dragonball/{instance_id}"
       }

4. 准备 VCPU ID 列表
   └─> vcpu_ids = (0..max_vcpu_count).collect()

5. 创建 NUMA 区域信息
   └─> numa_regions = vec![NumaRegionInfo {
           size: mem_size_mib,
           host_numa_node_id: None,
           guest_numa_node_id: Some(0),
           vcpu_ids,
       }]

6. 创建地址空间参数
   └─> address_space_param = AddressSpaceMgrBuilder::new(&mem_type, &mem_file_path)?

7. 设置 KVM VM fd
   └─> address_space_param.set_kvm_vm_fd(vm_fd.clone())

8. 创建地址空间 ⭐
   └─> address_space.create_address_space(resource_manager, &numa_regions, param)
```

**create_address_space() 详细流程**:

**文件**: `src/dragonball/src/address_space_manager.rs:262`

```
1. 遍历 NUMA 区域信息
   └─> for info in numa_region_infos.iter() {

2. 计算区域大小（MiB → 字节）
   └─> size = info.size << 20

3. 处理 MMIO 空洞（x86_64）
   ├─> if start_addr > MMIO_LOW_END || start_addr + size <= MMIO_LOW_START {
   │       // 不跨越 MMIO 空洞，直接创建区域
   │       region = create_region(start_addr, size, info, param)?
   │   } else {
   │       // 跨越 MMIO 空洞，分割为两个区域
   │       ├─> below_size = MMIO_LOW_START - start_addr
   │       ├─> if below_size < MINIMAL_SPLIT_SPACE {
   │       │       below_size = 0  // 不分割
   │       │   } else {
   │       │       region_below = create_region(start_addr, below_size, info, param)?
   │       │   }
   │       └─> region_above = create_region(MMIO_LOW_END + 1, above_size, info, param)?
   │   }

4. create_region() 详细流程
   ├─> 分配 KVM 内存槽
   │   └─> kvm_slot = res_mgr.allocate_kvm_mem_slot(1, None)?
   │
   ├─> 创建内存文件（根据 mem_type）
   │   ├─> if mem_type == "hugetlbfs" {
   │   │       file = open(mem_file_path, O_CREAT | O_RDWR)?
   │   │       ftruncate(file, size)?
   │   │   } else if mem_type == "shmem" {
   │   │       file = shm_open(...)?
   │   │       ftruncate(file, size)?
   │   │   } else {
   │   │       file = memfd_create(...)?  // 匿名内存
   │   │       ftruncate(file, size)?
   │   │   }
   │   └─>
   │
   ├─> 内存映射
   │   └─> mmap_region = MmapRegion::new(file, size, offset, prot_flags)?
   │
   ├─> NUMA 绑定（如果指定）
   │   └─> if host_numa_node_id.is_some() {
   │           madvise(MADV_BIND, numa_node)?
   │       }
   │
   ├─> 创建 GuestMemory 区域
   │   └─> guest_region = GuestRegionMmap::new(mmap_region, guest_addr)?
   │
   ├─> 映射到 KVM ⭐
   │   └─> map_to_kvm(res_mgr, param, region, mmap_region) (见下方)
   │
   └─> 创建 AddressSpaceRegion
       └─> AddressSpaceRegion::new(guest_addr, size, type, ...)

5. map_to_kvm() 详细流程
   ├─> 分配 KVM 内存槽（如果未分配）
   │   └─> slot = res_mgr.allocate_kvm_mem_slot(1, None)?
   │
   ├─> 获取 Host 虚拟地址
   │   └─> host_addr = mmap_reg.get_host_address(MemoryRegionAddress(0))?
   │
   ├─> 构建 kvm_userspace_memory_region
   │   └─> mem_region = kvm_userspace_memory_region {
   │           slot,
   │           guest_phys_addr: reg.start_addr().raw_value(),
   │           memory_size: reg.len(),
   │           userspace_addr: host_addr as u64,
   │           flags: 0,
   │       }
   │
   ├─> 调用 KVM ioctl ⭐
   │   └─> vmfd.set_user_memory_region(mem_region)?
   │       └─> KVM_SET_USER_MEMORY_REGION ioctl
   │
   └─> 保存 GPA -> Slot 映射
       └─> base_to_slot.insert(guest_addr, slot)

6. 创建 GuestMemory 对象
   └─> vm_memory = GuestMemoryMmap::new()
       └─> for reg in regions.iter() {
               vm_memory = vm_memory.insert_region(guest_region)?
           }

7. 创建 AddressSpace 对象
   └─> address_space = AddressSpace::from_regions(regions, layout)
```

**关键 KVM 调用**:
- `KVM_SET_USER_MEMORY_REGION`: 设置 Guest 内存映射

#### 1.3 初始化 VCPU 管理器：init_vcpu_manager()

**文件**: `src/dragonball/src/vm/mod.rs:414`

**详细流程**:

```
1. 创建 VcpuManager 实例
   └─> VcpuManager::new(
           vm_fd.clone(),
           &kvm,
           &vm_config,
           vm_as,
           vcpu_seccomp_filter,
           shared_info.clone(),
           device_manager.io_manager(),
           epoll_manager.clone(),
       )?

2. VcpuManager::new() 详细流程
   ├─> 检查 VCPU 数量限制
   │   └─> if max_vcpu_count > kvm_max_vcpu_count {
   │           return Err(MaxVcpuLimitation)
   │       }
   │
   ├─> 初始化 VCPU 信息向量
   │   └─> vcpu_infos = Vec::with_capacity(max_vcpu_count)
   │
   ├─> 创建 VCPU 状态事件通道
   │   ├─> (tx, rx) = channel()
   │   └─> vcpu_state_event = EventFd::new(EFD_NONBLOCK)?
   │
   ├─> 获取支持的 CPUID (x86_64)
   │   └─> supported_cpuid = kvm_context.supported_cpuid(KVM_MAX_CPUID_ENTRIES)?
   │
   ├─> 确定 vPMU 特性级别
   │   └─> vpmu_feature_level = match vm_config.vpmu_feature {
   │           1 => LimitedlyEnabled,
   │           2 => FullyEnabled,
   │           _ => Disabled,
   │       }
   │
   ├─> 创建 VcpuManager 对象
   │   └─> VcpuManager {
   │           vcpu_infos,
   │           vcpu_config: VcpuConfig { ... },
   │           vm_fd,
   │           vm_as,
   │           io_manager,
   │           ...
   │       }
   │
   └─> 注册 VCPU Epoll 处理器
       └─> epoll_manager.add_subscriber(VcpuEpollHandler { ... })
```

#### 1.4 初始化 MicroVM：init_microvm()

**文件**: `src/dragonball/src/vm/x86_64.rs:168` (x86_64) 或 `aarch64.rs:72` (aarch64)

**x86_64 详细流程**:

```
1. 初始化 TSS ⭐
   └─> init_tss()?
       └─> vm_fd.set_tss_address(KVM_TSS_ADDRESS)?
           └─> KVM_SET_TSS_ADDR ioctl

2. 设置中断控制器 ⭐
   └─> setup_interrupt_controller()?
       └─> vm_fd.create_irq_chip()?
           └─> KVM_SET_IRQCHIP ioctl
           └─> 创建 IOAPIC 和 PIC

3. 创建 PIT ⭐
   └─> create_pit()?
       └─> vm_fd.create_pit2(pit_config)?
           └─> KVM_SET_PIT2 ioctl
           └─> pit_config.flags = KVM_PIT_SPEAKER_DUMMY

4. 初始化设备 ⭐
   └─> init_devices(epoll_mgr)? (见 1.4.1)

5. 设置 Reset EventFD
   └─> reset_event_fd = device_manager.get_reset_eventfd()?
       └─> vcpu_manager().set_reset_event_fd(reset_event_fd)?

6. CPU 电源管理（如果启用）
   └─> if vm_config.cpu_pm == "on" {
           // TODO: 实现 CPU PM 支持
       }

7. 加载内核 ⭐
   └─> load_kernel(vm_memory)? (见 1.4.2)

8. 创建启动 VCPU ⭐
   └─> vcpu_manager().create_boot_vcpus(request_ts, kernel_load)?
       └─> create_vcpus(boot_vcpu_count, request_ts, entry_addr) (见 1.6.1)
```

**aarch64 详细流程**:

```
1. 创建 Reset EventFD
   └─> reset_event_fd = EventFd::new(EFD_NONBLOCK)?
       └─> vcpu_manager().set_reset_event_fd(reset_event_fd)?

2. 加载内核（必须在创建 VCPU 之前）
   └─> load_kernel(vm_memory)? (见 1.4.2)

3. 创建启动 VCPU（必须在设置 IRQ chip 之前）
   └─> vcpu_manager().create_boot_vcpus(request_ts, kernel_load)?
       └─> create_vcpus(max_vcpu_count, request_ts, entry_addr) (见 1.6.1)

4. 设置中断控制器（GIC）
   └─> setup_interrupt_controller()?
       └─> create_gic(vm_fd, vcpu_count)?
           └─> KVM_CREATE_DEVICE (VGIC)

5. 设置 PMU 设备
   └─> setup_pmu_devices()?

6. 初始化设备
   └─> init_devices(epoll_mgr)? (见 1.4.1)
```

**关键 KVM 调用**:
- `KVM_SET_TSS_ADDR` (x86_64): 设置 TSS 地址
- `KVM_SET_IRQCHIP` (x86_64): 设置 IRQ chip
- `KVM_SET_PIT2` (x86_64): 设置 PIT
- `KVM_CREATE_DEVICE` (aarch64): 创建 VGIC 设备

#### 1.4.1 初始化设备：init_devices()

**文件**: `src/dragonball/src/vm/mod.rs:473`

**详细流程**:

```
1. 创建中断管理器
   └─> device_manager.create_interrupt_manager()?
       └─> KvmIrqManager::new(vm_fd)?
           └─> 初始化 IRQ routing 表

2. 创建设备上下文
   └─> ctx = DeviceOpContext::new(
           Some(epoll_mgr),
           self,
           Some(vm_as),
           address_space,
           false,
           Some(vm_config),
           shared_info,
       )

3. 创建设备
   └─> device_manager.create_devices(vm_as, epoll_mgr, kernel_config, dmesg_fifo, address_space, vm_config)? (见 1.4.1.1)

4. 启动设备
   └─> device_manager.start_devices(vm_as)?
       └─> vfio_manager.start_devices(vm_as)? (如果启用 VFIO)
```

**1.4.1.1 create_devices() 详细流程**:

**文件**: `src/dragonball/src/device_manager/mod.rs:845`

```
1. 创建传统设备
   └─> create_legacy_devices(&mut ctx)?
       ├─> 创建 Serial (COM1, COM2)
       ├─> 创建 RTC
       └─> 创建 i8042 (x86_64)

2. 初始化传统设备
   └─> init_legacy_devices(dmesg_fifo, com1_sock_path, &mut ctx)?
       ├─> 设置 Guest 内核日志流（COM2）
       └─> 创建控制台（COM1）

3. 创建块设备（如果启用）
   └─> block_manager.attach_devices(&mut ctx)?
       ├─> 为每个块设备：
       │   ├─> 分配资源（MMIO 地址、IRQ）
       │   ├─> 创建 Virtio Block 设备
       │   ├─> 注册到 IoManager
       │   └─> 设置 IRQ routing
       └─> 生成内核启动参数

4. 创建文件系统设备（如果启用）
   └─> fs_manager.attach_devices(&mut ctx)?
       ├─> 分配资源（MMIO 地址、IRQ）
       ├─> 创建 Virtio FS 设备
       ├─> 注册到 IoManager
       └─> 设置 IRQ routing

5. 创建网络设备（如果启用）
   └─> virtio_net_manager.attach_devices(&mut ctx)?
       ├─> 分配资源（MMIO 地址、IRQ）
       ├─> 创建 Virtio Net 设备
       ├─> 注册到 IoManager
       └─> 设置 IRQ routing

6. 创建 VSock 设备（如果启用）
   └─> vsock_manager.attach_devices(&mut ctx)?
       ├─> 分配资源（MMIO 地址、IRQ）
       ├─> 创建 Virtio VSock 设备
       ├─> 注册到 IoManager
       └─> 设置 IRQ routing

7. 创建 vhost 设备（如果启用）
   ├─> vhost_net_manager.attach_devices(&mut ctx)?
   └─> vhost_user_net_manager.attach_devices(&mut ctx)?

8. 创建 VFIO 设备（如果启用）
   └─> vfio_manager.attach_devices(&mut ctx)?
       ├─> 为每个 VFIO 设备：
       │   ├─> 打开 VFIO 设备
       │   ├─> 分配 PCI 地址
       │   ├─> 映射 BAR
       │   └─> 设置 IRQ

9. 生成内核启动参数
   └─> ctx.generate_kernel_boot_args(kernel_config)?

10. 生成设备信息（aarch64）
    └─> ctx.generate_virtio_device_info()?
        └─> 用于 FDT 生成
```

**设备创建的关键步骤**:

对于每个设备：

```
1. 分配设备资源
   └─> resources = resource_manager.allocate_device_resources(&constraints, shared_irq)?
       ├─> 分配 MMIO 地址（或 PIO 地址）
       ├─> 分配 IRQ（Legacy 或 MSI）
       └─> 分配 KVM 内存槽（如果需要）

2. 创建设备对象
   └─> device = VirtioDevice::new(resources, config)?

3. 注册到 IoManager
   └─> io_manager.register_device(device)?
       └─> 将设备添加到 IO 地址映射表

4. 设置 IRQ routing
   └─> irq_manager.service_irq(irq, device)?
       └─> KVM_SET_GSI_ROUTING (如果使用 IRQFD)
```

#### 1.4.2 加载内核：load_kernel()

**文件**: `src/dragonball/src/vm/mod.rs:680`

**详细流程**:

```
1. 计算高内存地址（x86_64）
   └─> high_mem_addr = calculate_high_mem_addr(vm_memory)?

2. 加载内核镜像
   └─> kernel_loader_result = linux_loader::loader::load_kernel(
           vm_memory,
           Some(GuestAddress(kernel_start)),
           kernel_file,
           Some(high_mem_addr),
       )?
       ├─> 读取内核文件
       ├─> 解析内核格式（bzImage、vmlinux 等）
       ├─> 将内核代码加载到 Guest 内存
       └─> 返回内核入口地址

3. 返回结果
   └─> KernelLoaderResult {
           kernel_load: entry_addr,
           ...
       }
```

#### 1.5 配置系统：init_configure_system()

**文件**: `src/dragonball/src/vm/mod.rs:770`

**详细流程**:

```
1. 获取内核命令行
   └─> cmdline = kernel_config.cmdline()?

2. 配置系统架构特定设置
   └─> configure_system_arch(vm_memory, cmdline, initrd)? (见 1.5.1)
```

**1.5.1 configure_system_arch() 详细流程**:

**x86_64** (`src/dragonball/src/vm/x86_64.rs:209`):

```
1. 加载内核命令行
   └─> linux_loader::loader::load_cmdline(vm_memory, cmdline_addr, cmdline)?
       └─> 将 cmdline 写入 Guest 内存的 CMDLINE_START 地址

2. 配置系统（MPSpec）
   └─> configure_system(
           vm_memory,
           address_space,
           cmdline_addr,
           cmdline_size,
           initrd,
           vcpu_count,
           max_vcpu_count,
           pci_legacy_irqs,
       )?
       ├─> 创建 MPSpec 表
       ├─> 创建 MPTable
       ├─> 设置 ACPI 表（如果启用）
       └─> 加载 initrd（如果提供）
```

**aarch64** (`src/dragonball/src/vm/aarch64.rs:156`):

```
1. 获取 FDT 信息
   ├─> fdt_vm_info = get_fdt_vm_info(vm_memory, cmdline, initrd, vcpu_manager)?
   ├─> fdt_numa_info = get_fdt_numa_info()?
   └─> fdt_device_info = get_fdt_device_info()?

2. 创建 FDT
   └─> dbs_boot::fdt::create_fdt(fdt_vm_info, fdt_numa_info, fdt_device_info)?
       ├─> 创建 FDT 结构
       ├─> 添加 CPU 节点
       ├─> 添加内存节点
       ├─> 添加设备节点（GIC、virtio 设备等）
       └─> 将 FDT 写入 Guest 内存
```

#### 1.6 启动 VCPU：start_boot_vcpus()

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:393`

**详细流程**:

```
1. 创建启动 VCPU
   └─> create_boot_vcpus(request_ts, entry_addr)? (见 1.6.1)

2. 启动 VCPU 线程
   └─> start_boot_vcpus(vmm_seccomp_filter)? (见 1.6.2)
```

**1.6.1 create_boot_vcpus() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:371`

```
1. 确定要创建的 VCPU 数量
   ├─> if aarch64 {
   │       boot_vcpu_count = max_vcpu_count  // 必须创建所有 VCPU
   │   } else {
   │       boot_vcpu_count = boot_vcpu_count
   │   }

2. 创建 VCPU
   └─> create_vcpus(boot_vcpu_count, request_ts, entry_addr)? (见 1.6.1.1)
```

**1.6.1.1 create_vcpus() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:403`

```
1. 检查 VCPU 数量
   └─> if vcpu_count > max_vcpu_count {
           return Err(ExpectedVcpuExceedMax)
       }

2. 计算可用的 VCPU ID
   └─> available_cpus = calculate_available_vcpus(vcpu_count)?

3. 为每个 VCPU 创建
   └─> for cpu_id in available_cpus {
           create_vcpu(cpu_id, request_ts, entry_addr)? (见 1.6.1.2)
       }
```

**1.6.1.2 create_vcpu() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:470+`

```
1. 创建 VCPU fd ⭐
   └─> kvm_vcpu = vm_fd.create_vcpu(cpu_id as u64)?
       └─> KVM_CREATE_VCPU ioctl

2. 创建 VCPU 对象（架构特定）
   └─> vcpu = create_vcpu_arch(cpu_id, kvm_vcpu, request_ts)? (见 1.6.1.3)

3. 配置 VCPU ⭐
   └─> vcpu.configure(entry_addr)? (见 1.6.1.4)

4. 保存 VCPU 引用
   └─> vcpu_infos[cpu_id].vcpu = Some(vcpu)
```

**1.6.1.3 create_vcpu_arch() 详细流程**:

**x86_64** (`src/dragonball/src/vcpu/x86_64.rs`):

```
1. 映射 VCPU 运行结构
   └─> vcpu_run_size = kvm.get_vcpu_mmap_size()?
       └─> mmap(vcpu_fd, vcpu_run_size)?
           └─> 映射 KVM_RUN 结构

2. 创建 VCPU 对象
   └─> Vcpu::new(
           cpu_id,
           kvm_vcpu,
           vm_fd,
           vm_as,
           io_manager,
           shared_info,
           request_ts,
       )?
```

**aarch64** (`src/dragonball/src/vcpu/aarch64.rs`):

```
1. 获取首选目标
   └─> preferred_target = vcpu_fd.get_preferred_target()?

2. 创建 VCPU 对象
   └─> Vcpu::new(
           cpu_id,
           kvm_vcpu,
           vm_fd,
           vm_as,
           io_manager,
           shared_info,
           request_ts,
       )?
```

**1.6.1.4 configure() 详细流程**:

**x86_64** (`src/dragonball/src/vcpu/x86_64.rs`):

```
1. 设置 CPUID ⭐
   └─> set_cpuid(&vcpu_config)?
       └─> vcpu_fd.set_cpuid2(&cpuid_entries)?
           └─> KVM_SET_CPUID2 ioctl

2. 设置 MSR ⭐
   └─> set_msrs(&vcpu_config)?
       └─> vcpu_fd.set_msrs(&msr_entries)?
           └─> KVM_SET_MSRS ioctl

3. 设置通用寄存器 ⭐
   └─> set_regs(entry_addr)?
       └─> vcpu_fd.set_regs(&regs)?
           └─> KVM_SET_REGS ioctl
           └─> regs.rip = entry_addr.raw_value()
           └─> regs.rsp = stack_addr

4. 设置特殊寄存器 ⭐
   └─> set_sregs()?
       └─> setup_sregs(memory, vcpu_fd, pgtable_addr, gdt_table, gdt_addr, idt_addr)?
           └─> vcpu_fd.set_sregs(&sregs)?
               └─> KVM_SET_SREGS ioctl
           └─> 设置段寄存器、控制寄存器、页表等

5. 设置 FPU 状态 ⭐
   └─> set_fpu()?
       └─> vcpu_fd.set_fpu(&fpu)?
           └─> KVM_SET_FPU ioctl
```

**aarch64** (`src/dragonball/src/vcpu/aarch64.rs`):

```
1. 初始化 VCPU ⭐
   └─> vcpu_init()?
       └─> kvi = kvm_vcpu_init::default()
           └─> kvi.features[0] |= 1 << KVM_ARM_VCPU_PSCI_0_2
           └─> vcpu_fd.vcpu_init(&kvi)?
               └─> KVM_ARM_VCPU_INIT ioctl

2. 设置寄存器 ⭐
   └─> set_regs(entry_addr)?
       └─> vcpu_fd.set_one_reg(reg_id, value)?
           └─> KVM_SET_ONE_REG ioctl
       └─> 设置 PC、SP、PSTATE 等
```

**关键 KVM 调用**:
- `KVM_CREATE_VCPU`: 创建 VCPU
- `KVM_SET_CPUID2` (x86_64): 设置 CPUID
- `KVM_SET_MSRS` (x86_64): 设置 MSR
- `KVM_SET_REGS`: 设置通用寄存器
- `KVM_SET_SREGS` (x86_64): 设置特殊寄存器
- `KVM_SET_FPU` (x86_64): 设置 FPU
- `KVM_ARM_VCPU_INIT` (aarch64): 初始化 ARM VCPU
- `KVM_SET_ONE_REG` (aarch64): 设置单个寄存器

**1.6.2 start_boot_vcpus() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:393`

```
1. 启动 VCPU
   └─> start_vcpus(boot_vcpu_count, vmm_seccomp_filter, need_resume: true)? (见 1.6.2.1)
```

**1.6.2.1 start_vcpus() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:425`

```
1. 注册 VCPU kick 信号处理器
   └─> Vcpu::register_kick_signal_handler()?

2. 激活 VCPU
   └─> activate_vcpus(vcpu_count, need_resume)? (见 1.6.2.2)

3. 应用 Seccomp 过滤器（VMM 线程）
   └─> apply_filter(&vmm_seccomp_filter)?
```

**1.6.2.2 activate_vcpus() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs:500+`

```
1. 为每个 VCPU 创建线程
   └─> for cpu_id in 0..vcpu_count {
           let vcpu = vcpu_infos[cpu_id].vcpu.clone()?;
           
           let thread = thread::Builder::new()
               .name(format!("vcpu-{}", cpu_id))
               .spawn(move || {
                   // VCPU 线程逻辑
                   vcpu.run(seccomp_filter)? (见 1.6.2.3)
               })?;
           
           vcpu_infos[cpu_id].thread = Some(thread);
       }

2. 如果需要恢复，发送 Resume 事件
   └─> if need_resume {
           resume_vcpus(&vcpu_ids)?
       }
```

**1.6.2.3 Vcpu::run() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_impl.rs`

```
1. 应用 Seccomp 过滤器
   └─> apply_filter(seccomp_filter)?

2. 初始化线程本地数据
   └─> init_thread_local_data()?

3. 启动状态机
   └─> StateMachine::run(self, Self::paused)
       └─> 状态转换: Paused → Running → ...
```

**VCPU 运行循环** (`running()` 状态):

```
loop {
    1. 运行 VCPU 模拟
       └─> run_emulation()? (见 1.6.2.4)

    2. 检查事件
       └─> check_events()?
           ├─> Resume → continue
           ├─> Pause → return Paused
           └─> Exit → return Exited
}
```

**1.6.2.4 run_emulation() 详细流程**:

**文件**: `src/dragonball/src/vcpu/vcpu_impl.rs`

```
1. 调用 KVM_RUN ⭐
   └─> match vcpu_fd.run() {
           Ok(run) => {
               match run {
                   VcpuExit::IoOut(addr, data) => {
                       // 处理 IO 输出
                       handle_io(addr, data)?
                   }
                   VcpuExit::Mmio(addr, data) => {
                       // 处理 MMIO 访问
                       handle_mmio(addr, data)?
                   }
                   VcpuExit::Hlt => {
                       // Guest 执行了 HLT 指令
                       info!("Received KVM_EXIT_HLT")
                   }
                   VcpuExit::Shutdown => {
                       // Guest 关机
                       info!("Received KVM_EXIT_SHUTDOWN")
                   }
                   VcpuExit::SystemEvent(event) => {
                       // 系统事件（Reset 等）
                       handle_system_event(event)?
                   }
                   // ... 其他退出原因
               }
               Ok(VcpuEmulation::Handled)
           }
           Err(e) => {
               Err(VcpuError::Kvm(e))
           }
       }
```

**关键 KVM 调用**:
- `KVM_RUN`: 运行 VCPU（循环调用）

## 完整流程图总结

```
API Request (StartVM)
    ↓
Vm::start_microvm()
    │
    ├─> 1. 应用 Seccomp 过滤器
    ├─> 2. 检查 VM 状态
    ├─> 3. 记录时间戳
    ├─> 4. 初始化 dmesg logger
    ├─> 5. 健康检查
    ├─> 6. 更新状态为 Starting
    │
    ├─> 7. init_guest_memory() ⭐
    │   ├─> 计算内存大小和类型
    │   ├─> 创建 NUMA 区域信息
    │   └─> address_space.create_address_space()
    │       ├─> 为每个 NUMA 区域：
    │       │   ├─> 分配 KVM 内存槽
    │       │   ├─> 创建内存文件（hugetlbfs/shmem/memfd）
    │       │   ├─> 内存映射（mmap）
    │       │   ├─> NUMA 绑定（如果指定）
    │       │   ├─> 创建 GuestMemory 区域
    │       │   └─> map_to_kvm()
    │       │       └─> KVM_SET_USER_MEMORY_REGION ⭐
    │       └─> 创建 GuestMemory 和 AddressSpace 对象
    │
    ├─> 8. init_vcpu_manager() ⭐
    │   ├─> 检查 VCPU 数量限制
    │   ├─> 创建 VCPU 状态事件通道
    │   ├─> 获取支持的 CPUID (x86_64)
    │   ├─> 确定 vPMU 特性
    │   └─> 创建 VcpuManager 对象
    │
    ├─> 9. init_microvm() ⭐
    │   ├─> [x86_64] init_tss() → KVM_SET_TSS_ADDR
    │   ├─> setup_interrupt_controller()
    │   │   ├─> [x86_64] create_irq_chip() → KVM_SET_IRQCHIP
    │   │   └─> [aarch64] create_gic() → KVM_CREATE_DEVICE (VGIC)
    │   ├─> [x86_64] create_pit() → KVM_SET_PIT2
    │   ├─> init_devices()
    │   │   ├─> create_interrupt_manager()
    │   │   └─> create_devices()
    │   │       ├─> 创建传统设备（Serial、RTC、i8042）
    │   │       ├─> 创建块设备（virtio-blk）
    │   │       ├─> 创建文件系统设备（virtio-fs）
    │   │       ├─> 创建网络设备（virtio-net）
    │   │       ├─> 创建 VSock 设备（virtio-vsock）
    │   │       ├─> 创建 vhost 设备
    │   │       └─> 创建 VFIO 设备（如果启用）
    │   │       └─> 每个设备：
    │   │           ├─> 分配资源（MMIO、IRQ、内存槽）
    │   │           ├─> 创建设备对象
    │   │           ├─> 注册到 IoManager
    │   │           └─> 设置 IRQ routing
    │   ├─> 设置 Reset EventFD
    │   ├─> load_kernel()
    │   │   └─> linux_loader::load_kernel()
    │   │       └─> 加载内核镜像到 Guest 内存
    │   └─> create_boot_vcpus()
    │       └─> create_vcpus()
    │           └─> 为每个 VCPU：
    │               ├─> KVM_CREATE_VCPU ⭐
    │               ├─> 映射 VCPU 运行结构
    │               └─> configure()
    │                   ├─> [x86_64] KVM_SET_CPUID2
    │                   ├─> [x86_64] KVM_SET_MSRS
    │                   ├─> KVM_SET_REGS
    │                   ├─> [x86_64] KVM_SET_SREGS
    │                   ├─> [x86_64] KVM_SET_FPU
    │                   └─> [aarch64] KVM_ARM_VCPU_INIT
    │                   └─> [aarch64] KVM_SET_ONE_REG
    │
    ├─> 10. init_configure_system() ⭐
    │   ├─> [x86_64] 加载 cmdline、创建 MPSpec、MPTable
    │   └─> [aarch64] 创建 FDT
    │
    ├─> 11. init_upcall() (如果启用)
    ├─> 12. register_events()
    │
    └─> 13. start_boot_vcpus() ⭐
        └─> start_vcpus()
            └─> activate_vcpus()
                └─> 为每个 VCPU 创建线程
                    └─> Vcpu::run()
                        └─> 状态机: Paused → Running
                            └─> 循环调用 KVM_RUN ⭐
                                └─> 处理退出原因（IO、MMIO、HLT 等）
```

## 关键 KVM 调用序列

### 完整序列

```
1. KVM_CREATE_VM                    # 创建虚拟机（在 Vm::new() 中）
2. KVM_SET_USER_MEMORY_REGION       # 设置 Guest 内存（每个内存区域）
3. [x86_64] KVM_SET_TSS_ADDR        # 设置 TSS 地址
4. [x86_64] KVM_SET_IRQCHIP         # 设置 IRQ chip
5. [x86_64] KVM_SET_PIT2            # 设置 PIT
6. KVM_SET_GSI_ROUTING              # 设置中断路由（每个设备）
7. KVM_CREATE_VCPU                  # 创建 VCPU（每个 VCPU）
8. [x86_64] KVM_SET_CPUID2          # 设置 CPUID（每个 VCPU）
9. [x86_64] KVM_SET_MSRS            # 设置 MSR（每个 VCPU）
10. KVM_SET_REGS                     # 设置通用寄存器（每个 VCPU）
11. [x86_64] KVM_SET_SREGS           # 设置特殊寄存器（每个 VCPU）
12. [x86_64] KVM_SET_FPU             # 设置 FPU（每个 VCPU）
13. [aarch64] KVM_ARM_VCPU_INIT      # 初始化 ARM VCPU（每个 VCPU）
14. [aarch64] KVM_SET_ONE_REG        # 设置寄存器（每个 VCPU，多次调用）
15. [aarch64] KVM_CREATE_DEVICE      # 创建 VGIC 设备
16. KVM_RUN                          # 运行 VCPU（每个 VCPU 线程循环调用）
```

## 时间线

```
T0: API Request (StartVM)
T1: 应用 Seccomp 过滤器
T2: 初始化 Guest 内存（分配、映射、KVM_SET_USER_MEMORY_REGION）
T3: 初始化 VCPU 管理器
T4: 初始化中断控制器
T5: 创建和初始化设备
T6: 加载内核镜像
T7: 创建和配置 VCPU
T8: 配置系统（MPSpec/FDT）
T9: 启动 VCPU 线程
T10: VCPU 进入 KVM_RUN 循环
T11: Guest 开始执行
```

## 错误处理

每个步骤都有相应的错误处理：

- **资源分配失败**: 返回 `NoAvailResource` 错误
- **KVM ioctl 失败**: 返回相应的 KVM 错误
- **设备创建失败**: 返回设备特定错误
- **VCPU 创建失败**: 返回 VCPU 管理器错误

如果任何步骤失败，会执行清理：
1. 停止所有 VCPU 线程
2. 移除所有设备
3. 释放内存
4. 关闭 VM fd

### 2. IO 处理流程

```
Guest 执行 IO 操作
    ↓
KVM_EXIT_IO / KVM_EXIT_MMIO
    ↓
Vcpu::run_emulation()
    ↓
IoManager::pio_read/write() 或 mmio_read/write()
    ↓
Device::read() / Device::write()
    ↓
设备特定处理（如 Virtio Queue 操作）
```

### 3. 中断处理流程

```
设备触发中断
    ↓
Device::signal_used_queue()
    ↓
KvmIrqManager::service_irq()
    ↓
KVM_IRQ_LINE / KVM_IRQFD
    ↓
注入中断到 Guest
```

## 线程模型

### 线程类型

1. **VMM 主线程**:
   - 运行事件循环
   - 处理 API 请求
   - 管理 VM 生命周期

2. **VCPU 线程**:
   - 每个 VCPU 一个线程
   - 运行 `KVM_RUN` 循环
   - 处理 IO、MMIO、中断等

3. **设备线程**:
   - 某些设备可能有后台线程
   - 处理设备特定任务

### Seccomp 支持

Dragonball 支持 Seccomp 过滤器，可以为不同线程类型应用不同的安全策略：

- `ALL_THREADS`: 所有线程
- `VMM_THREAD`: VMM 线程
- `VCPU_THREAD`: VCPU 线程

## 性能优化

### 1. 内存管理

- **大页支持**: 使用 `hugetlbfs` 减少 TLB miss
- **内存预分配**: 支持内存预分配，减少运行时开销
- **NUMA 感知**: 支持 NUMA 节点配置

### 2. IO 优化

- **IO 管理器缓存**: 使用 `ArcSwap` 和 `Cache` 实现无锁设备查找
- **批量 IO**: 支持批量 IO 操作
- **vhost 支持**: 使用 vhost 将设备处理卸载到内核

### 3. 中断优化

- **IRQFD**: 使用 IRQFD 直接注入中断，减少 VMM 参与
- **共享 IRQ**: 多个设备可以共享一个 IRQ
- **MSI/MSI-X**: 支持现代中断机制

### 4. 并发优化

- **异步架构**: 使用 Tokio 运行时处理异步操作
- **无锁数据结构**: 使用 `ArcSwap`、`Atomic` 等实现无锁操作
- **线程本地存储**: 减少锁竞争

## 安全特性

### 1. Seccomp 过滤器

- 限制系统调用
- 为不同线程类型应用不同策略

### 2. 内存安全

- Rust 的类型系统保证内存安全
- 避免缓冲区溢出等常见漏洞

### 3. 资源隔离

- 每个 VM 有独立的资源管理器
- 防止资源冲突和泄漏

## 扩展性

### 1. 设备热插拔

- 支持运行时添加/删除设备
- 使用 `ArcSwap` 实现无锁设备更新

### 2. VCPU 热插拔

- 支持运行时添加/删除 VCPU
- aarch64 需要在启动时创建所有 VCPU

### 3. 多 VM 支持

- 架构支持 1 VMM 管理多个 VM（当前实现为 1:1）

## 相关文件

### 核心文件
- `src/vmm.rs`: VMM 主对象
- `src/vm/mod.rs`: VM 对象
- `src/device_manager/mod.rs`: 设备管理器
- `src/resource_manager.rs`: 资源管理器
- `src/address_space_manager.rs`: 地址空间管理器
- `src/vcpu/vcpu_manager.rs`: VCPU 管理器
- `src/io_manager.rs`: IO 管理器
- `src/event_manager.rs`: 事件管理器
- `src/kvm_context.rs`: KVM 上下文

### 架构特定
- `src/vm/x86_64.rs`: x86_64 VM 实现
- `src/vm/aarch64.rs`: aarch64 VM 实现
- `src/vcpu/x86_64.rs`: x86_64 VCPU 实现
- `src/vcpu/aarch64.rs`: aarch64 VCPU 实现

### 子模块
- `dbs_arch/`: 架构相关
- `dbs_boot/`: 启动相关
- `dbs_device/`: 设备抽象
- `dbs_interrupt/`: 中断管理
- `dbs_pci/`: PCI 支持
- `dbs_virtio_devices/`: Virtio 设备
- `dbs_address_space/`: 地址空间
- `dbs_utils/`: 工具库

## 总结

Dragonball 是一个模块化、高性能、安全的 VMM，专门为容器工作负载优化。其架构特点：

1. **清晰的层次结构**: VMM → VM → 组件
2. **模块化设计**: 各组件职责明确，易于扩展
3. **性能优化**: 内存、IO、中断等多方面优化
4. **安全可靠**: Rust 类型安全 + Seccomp
5. **容器优化**: 针对容器场景的特殊优化

通过这种架构设计，Dragonball 能够提供轻量级、高性能的虚拟化解决方案，满足 Kata Containers 的需求。

