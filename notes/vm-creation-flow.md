# Kata Containers 虚拟机创建流程

## 概述

Kata Containers 支持多种 Hypervisor，本文档主要描述 **Dragonball** VMM 的虚拟机创建流程。Dragonball 是 Kata 3.0 内置的轻量级 VMM，使用 Rust 编写，直接通过 KVM 接口创建和管理虚拟机。

## 整体架构

```
Container Manager (containerd/CRI-O)
    ↓
Kata Runtime (Go)
    ↓
Hypervisor Interface (Go)
    ↓
Dragonball VMM (Rust) ← 本文档重点
    ↓
KVM (Linux Kernel)
    ↓
Guest VM
```

## 虚拟机创建流程

### 阶段 1: Runtime 层初始化 (Go)

#### 1.1 创建 VM 对象

**文件**: `src/runtime/virtcontainers/vm.go`

```go
func NewVM(ctx context.Context, config VMConfig) (*VM, error) {
    // 1. 创建 Hypervisor 实例
    hypervisor, err := NewHypervisor(config.HypervisorType)
    
    // 2. 创建网络对象
    network, err := NewNetwork()
    
    // 3. 生成 VM ID
    id := uuid.Generate().String()
    
    // 4. 调用 Hypervisor.CreateVM
    if err = hypervisor.CreateVM(ctx, id, network, &config.HypervisorConfig); err != nil {
        return nil, err
    }
    
    // 5. 配置 Agent
    agent := newAagentFunc()
    err = agent.configure(ctx, hypervisor, id, vmSharePath, config.AgentConfig)
    
    // 6. 启动 VM
    if err = hypervisor.StartVM(ctx, VmStartTimeout); err != nil {
        return nil, err
    }
    
    // 7. 检查 Agent 状态
    err = agent.check(ctx)
}
```

**关键步骤**:
1. 创建 Hypervisor 实例（根据配置选择 QEMU/Cloud Hypervisor/Dragonball）
2. 调用 `CreateVM` 创建虚拟机（但尚未启动）
3. 配置 Agent（准备与 Guest 通信）
4. 调用 `StartVM` 启动虚拟机
5. 验证 Agent 是否正常运行

### 阶段 2: Dragonball VMM 初始化 (Rust)

#### 2.1 VMM 对象创建

**文件**: `src/dragonball/src/vmm.rs`

```rust
pub fn new(
    api_shared_info: Arc<RwLock<InstanceInfo>>,
    api_event_fd: EventFd,
    seccomp_filters: HashMap<String, BpfProgram>,
    kvm_fd: Option<RawFd>,
) -> Result<Self> {
    // 1. 创建 EpollManager
    let epoll_manager = EpollManager::default();
    
    // 2. 创建 VM 对象
    let vm = Vm::new(kvm_fd, api_shared_info, epoll_manager.clone())?;
    
    // 3. 创建事件上下文
    let event_ctx = EventContext::new(api_event_fd)?;
    
    Ok(Vmm {
        event_ctx,
        epoll_manager,
        vm,
        seccomp_filters,
    })
}
```

#### 2.2 VM 对象创建

**文件**: `src/dragonball/src/vm/mod.rs`

```rust
pub fn new(
    kvm_fd: Option<RawFd>,
    api_shared_info: Arc<RwLock<InstanceInfo>>,
    epoll_manager: EpollManager,
) -> Result<Self> {
    // 1. 创建 KVM 上下文
    let kvm = KvmContext::new(kvm_fd)?;
    
    // 2. 创建 VM fd (KVM_CREATE_VM)
    let vm_fd = Arc::new(kvm.create_vm()?);
    
    // 3. 创建资源管理器
    let resource_manager = Arc::new(ResourceManager::new(Some(kvm.max_memslots())));
    
    // 4. 创建设备管理器
    let device_manager = DeviceManager::new(
        vm_fd.clone(),
        resource_manager.clone(),
        epoll_manager.clone(),
        &logger,
        api_shared_info.clone(),
    )?;
    
    Ok(Vm {
        kvm,
        vm_fd,
        resource_manager,
        device_manager,
        address_space: AddressSpaceMgr::default(),
        vcpu_manager: None,
        vm_config: Default::default(),
        // ...
    })
}
```

**关键操作**:
- `KvmContext::new()`: 打开 `/dev/kvm`，检查 API 版本和能力
- `kvm.create_vm()`: 调用 `KVM_CREATE_VM` ioctl 创建虚拟机
- 初始化资源管理器（内存槽管理）
- 初始化设备管理器

### 阶段 3: 虚拟机启动 (StartVM)

#### 3.1 启动流程入口

**文件**: `src/dragonball/src/vm/mod.rs`

```rust
pub fn start_microvm(
    &mut self,
    event_mgr: &mut EventManager,
    seccomp_filters: HashMap<String, BpfProgram>,
) -> Result<(), StartMicroVmError> {
    // 1. 应用 Seccomp 过滤器
    if let Some(process_seccomp_filter) = seccomp_filters.get(ALL_THREADS) {
        apply_filter_all_threads(process_seccomp_filter)?;
    }
    
    // 2. 更新状态为 Starting
    self.shared_info.write().unwrap().state = InstanceState::Starting;
    
    // 3. 初始化 Guest 内存
    self.init_guest_memory()?;
    
    // 4. 初始化 VCPU 管理器
    self.init_vcpu_manager(vm_as.clone(), vcpu_seccomp_filter)?;
    
    // 5. 初始化 MicroVM
    self.init_microvm(event_mgr.epoll_manager(), vm_as.clone(), request_ts)?;
    
    // 6. 配置系统
    self.init_configure_system(&vm_as)?;
    
    // 7. 注册事件
    self.register_events(event_mgr)?;
    
    // 8. 启动 VCPU 线程
    self.vcpu_manager()?.start_boot_vcpus(seccomp_filter)?;
    
    // 9. 更新状态为 Running
    self.shared_info.write().unwrap().state = InstanceState::Running;
}
```

#### 3.2 初始化 Guest 内存

**文件**: `src/dragonball/src/vm/mod.rs`

```rust
pub(crate) fn init_guest_memory(&mut self) -> Result<(), StartMicroVmError> {
    // 1. 计算内存大小
    let mem_size = (self.vm_config.mem_size_mib as u64) << 20;
    
    // 2. 确定内存类型 (hugetlbfs 或 shmem)
    let mem_type = self.vm_config.mem_type.clone();
    let mem_file_path = if mem_type == "hugetlbfs" {
        // 使用大页内存
        format!("{}/dragonball/{}", self.vm_config.mem_file_path, instance_id)
    } else {
        String::from("")
    };
    
    // 3. 准备 NUMA 区域信息
    let numa_regions = vec![NumaRegionInfo {
        size: self.vm_config.mem_size_mib as u64,
        host_numa_node_id: None,
        guest_numa_node_id: Some(0),
        vcpu_ids: (0..max_vcpu_count).collect(),
    }];
    
    // 4. 创建地址空间管理器
    let mut address_space_param = AddressSpaceMgrBuilder::new(&mem_type, &mem_file_path)?;
    address_space_param.set_kvm_vm_fd(self.vm_fd.clone());
    
    // 5. 创建地址空间（分配和映射内存）
    self.address_space.create_address_space(
        &self.resource_manager,
        &numa_regions,
        address_space_param,
    )?;
}
```

**关键操作**:
- 根据配置选择内存类型（hugetlbfs 或 shmem）
- 创建 NUMA 区域配置
- 通过 `AddressSpaceMgr` 分配和映射 Guest 内存
- 调用 `KVM_SET_USER_MEMORY_REGION` 设置内存槽

#### 3.3 初始化 MicroVM

**文件**: `src/dragonball/src/vm/x86_64.rs` (x86_64) 或 `aarch64.rs` (aarch64)

```rust
// x86_64 版本的 init_microvm
pub fn init_microvm(
    &mut self,
    epoll_mgr: EpollManager,
    vm_as: GuestAddressSpaceImpl,
    request_ts: TimestampUs,
) -> Result<(), StartMicroVmError> {
    // 1. 初始化 TSS (x86_64 特有)
    // TSS (Task State Segment) 是 x86 架构用于任务切换的数据结构
    // ARM 架构没有 TSS 概念
    self.init_tss()?;
    
    // 2. 设置中断控制器（架构相关顺序）
    // x86_64: 先设置 IRQ chip，再创建 VCPU
    // aarch64: 先创建 VCPU，再设置 IRQ chip
    self.setup_interrupt_controller()?;
    
    // 3. 创建 PIT (x86_64 only)
    // PIT (Programmable Interval Timer) 也是 x86 特有的硬件定时器
    self.create_pit()?;
    
    // 4. 初始化设备
    self.init_devices(epoll_mgr)?;
    
    // 5. 设置 Reset EventFD
    let reset_event_fd = self.device_manager.get_reset_eventfd().unwrap();
    self.vcpu_manager()?.set_reset_event_fd(reset_event_fd)?;
    
    // 6. 加载内核镜像
    let vm_memory = vm_as.memory();
    let kernel_loader_result = self.load_kernel(vm_memory.deref())?;
    
    // 7. 创建启动 VCPU
    self.vcpu_manager()?.create_boot_vcpus(
        request_ts,
        kernel_loader_result.kernel_load,
    )?;
}

// aarch64 版本的 init_microvm (对比)
pub fn init_microvm(
    &mut self,
    epoll_mgr: EpollManager,
    vm_as: GuestAddressSpaceImpl,
    request_ts: TimestampUs,
) -> Result<(), StartMicroVmError> {
    // 注意：aarch64 没有 init_tss() 和 create_pit()
    
    // 1. 创建 VCPU（必须在 IRQ chip 之前）
    let kernel_loader_result = self.load_kernel(vm_as.memory().deref())?;
    self.vcpu_manager()?.create_boot_vcpus(request_ts, kernel_loader_result.kernel_load)?;
    
    // 2. 设置中断控制器（GIC）
    self.setup_interrupt_controller()?;
    
    // 3. 设置 PMU 设备
    self.setup_pmu_devices()?;
    
    // 4. 初始化设备
    self.init_devices(epoll_mgr)?;
}
```

**架构差异**:

**x86_64**:
1. **初始化 TSS** (`KVM_SET_TSS_ADDR`)
   - **TSS (Task State Segment)** 是 x86 架构特有的数据结构
   - 用于存储任务状态信息，支持硬件任务切换
   - ARM 架构没有 TSS 概念
   - 地址: `0xfffb_d000` (KVM_TSS_ADDRESS)
2. 设置中断控制器 (`KVM_SET_IRQCHIP`)
3. **创建 PIT** (`KVM_SET_PIT2`)
   - **PIT (Programmable Interval Timer)** 是 x86 特有的硬件定时器
   - ARM 架构使用其他定时器机制（如 ARM Generic Timer）
4. 初始化设备
5. 加载内核
6. 创建 VCPU

**aarch64**:
1. 创建 VCPU（必须在 IRQ chip 之前）
2. 设置 GIC (`KVM_CREATE_DEVICE` for VGIC)
   - **GIC (Generic Interrupt Controller)** 是 ARM 架构的中断控制器
   - x86_64 使用 IOAPIC/LAPIC
3. 设置 PMU 设备（可选）
4. 初始化设备
5. 加载内核（通过 FDT - Flattened Device Tree）
6. 配置 VCPU

#### 3.4 初始化设备

**文件**: `src/dragonball/src/vm/mod.rs`

```rust
pub(crate) fn init_devices(
    &mut self,
    epoll_manager: EpollManager,
) -> Result<(), StartMicroVmError> {
    // 1. 创建中断管理器
    self.device_manager.create_interrupt_manager()?;
    
    // 2. 创建设备（Serial, Console, Block, Net, VSock 等）
    self.device_manager.create_devices(
        vm_as.clone(),
        epoll_manager,
        kernel_config,
        self.dmesg_fifo.take(),
        self.address_space.address_space(),
        &self.vm_config,
    )?;
    
    // 3. 启动设备
    self.device_manager.start_devices(vm_as)?;
}
```

**设备创建顺序**:
1. 中断管理器（IRQ routing）
2. Serial/Console 设备
3. Block 设备（virtio-blk）
4. Network 设备（virtio-net）
5. VSock 设备（virtio-vsock）
6. 其他设备

#### 3.5 创建 VCPU

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs`

```rust
pub fn create_boot_vcpus(
    &mut self,
    request_ts: TimestampUs,
    entry_addr: GuestAddress,
) -> Result<()> {
    let boot_vcpu_count = if cfg!(target_arch = "aarch64") {
        // aarch64: 创建所有 VCPU（支持热插拔）
        self.vcpu_config.max_vcpu_count
    } else {
        // x86_64: 只创建启动所需的 VCPU
        self.vcpu_config.boot_vcpu_count
    };
    
    self.create_vcpus(boot_vcpu_count, Some(request_ts), Some(entry_addr))?;
}

fn create_vcpus(
    &mut self,
    count: u8,
    request_ts: Option<TimestampUs>,
    entry_addr: Option<GuestAddress>,
) -> Result<()> {
    for cpu_index in 0..count {
        // 1. 创建 VCPU fd (KVM_CREATE_VCPU)
        let kvm_vcpu = self.vm_fd.create_vcpu(cpu_index as u64)?;
        
        // 2. 创建 VCPU 对象（架构特定配置）
        let mut vcpu = self.create_vcpu_arch(cpu_index, kvm_vcpu, request_ts)?;
        
        // 3. 配置 VCPU（寄存器、CPUID、MSR 等）
        vcpu.configure(entry_addr)?;
        
        // 4. 保存 VCPU 引用
        self.vcpu_infos[cpu_index as usize].vcpu = Some(vcpu);
    }
}
```

**VCPU 配置** (x86_64):

```rust
// src/dragonball/src/vcpu/x86_64.rs
fn configure(&mut self, entry_addr: GuestAddress) -> Result<()> {
    // 1. 设置 CPUID
    self.set_cpuid(&vcpu_config)?;
    
    // 2. 设置 MSR
    self.set_msrs(&vcpu_config)?;
    
    // 3. 设置通用寄存器
    self.set_regs(entry_addr)?;
    
    // 4. 设置特殊寄存器（段寄存器、控制寄存器等）
    self.set_sregs()?;
    
    // 5. 设置 FPU 状态
    self.set_fpu()?;
}
```

**VCPU 配置** (aarch64):

```rust
// src/dragonball/src/vcpu/aarch64.rs
fn configure(&mut self, entry_addr: GuestAddress) -> Result<()> {
    // 1. 获取首选目标
    let preferred_target = self.fd.get_preferred_target()?;
    
    // 2. 初始化 VCPU (KVM_ARM_VCPU_INIT)
    let mut kvi = kvm_vcpu_init::default();
    kvi.features[0] |= 1 << KVM_ARM_VCPU_PSCI_0_2;
    self.fd.vcpu_init(&kvi)?;
    
    // 3. 设置寄存器
    self.set_regs(entry_addr)?;
}
```

#### 3.6 启动 VCPU 线程

**文件**: `src/dragonball/src/vcpu/vcpu_manager.rs`

```rust
pub fn start_boot_vcpus(&mut self, seccomp_filter: BpfProgram) -> Result<()> {
    let boot_vcpu_count = self.vcpu_config.boot_vcpu_count;
    
    for cpu_index in 0..boot_vcpu_count {
        let vcpu = self.vcpu_infos[cpu_index as usize]
            .vcpu
            .as_ref()
            .ok_or(VcpuManagerError::VcpuNotFound)?;
        
        // 1. 创建 VCPU 线程
        let vcpu_thread = thread::Builder::new()
            .name(format!("vcpu-{}", cpu_index))
            .spawn(move || {
                // 2. 初始化线程本地数据
                vcpu.init_thread_local_data()?;
                
                // 3. 运行 VCPU（进入 KVM_RUN 循环）
                vcpu.run(seccomp_filter)?;
                
                Ok(())
            })?;
        
        // 4. 保存线程句柄
        self.vcpu_infos[cpu_index as usize].thread = Some(vcpu_thread);
    }
    
    // 5. 发送 Resume 事件给所有 VCPU
    self.resume_all_vcpus()?;
}
```

**VCPU 运行循环**:

**文件**: `src/dragonball/src/vcpu/vcpu_impl.rs`

```rust
pub fn run(&mut self, seccomp_filter: BpfProgram) -> Result<()> {
    // 1. 应用 Seccomp 过滤器
    apply_filter(seccomp_filter)?;
    
    // 2. 初始化线程本地数据
    Self::init_thread_local_data()?;
    
    // 3. 启动状态机（从 Paused 状态开始）
    StateMachine::run(self, Self::paused);
}

fn running(&mut self) -> StateMachine<Self> {
    loop {
        // 1. 运行 VCPU (KVM_RUN)
        match self.run_emulation() {
            Ok(VcpuEmulation::Handled) => {
                // 处理退出原因（IO、MMIO、HLT 等）
                continue;
            }
            Ok(VcpuEmulation::Stopped) => {
                // VCPU 已停止
                return StateMachine::next(Self::exited);
            }
            Err(e) => {
                // 错误处理
                return StateMachine::next(Self::exited);
            }
        }
        
        // 2. 检查事件（Pause、Resume、Exit 等）
        match self.check_events() {
            VcpuEvent::Resume => continue,
            VcpuEvent::Pause => return StateMachine::next(Self::paused),
            VcpuEvent::Exit => return StateMachine::next(Self::exited),
            _ => continue,
        }
    }
}

fn run_emulation(&mut self) -> Result<VcpuEmulation> {
    // 调用 KVM_RUN
    match self.fd.run() {
        Ok(run) => {
            match run {
                VcpuExit::IoOut(addr, data) => {
                    // 处理 IO 输出
                    self.handle_io(addr, data)?;
                }
                VcpuExit::Mmio(addr, data) => {
                    // 处理 MMIO 访问
                    self.handle_mmio(addr, data)?;
                }
                VcpuExit::Hlt => {
                    // Guest 执行了 HLT 指令
                    info!("Received KVM_EXIT_HLT signal");
                }
                VcpuExit::Shutdown => {
                    // Guest 关机
                    info!("Received KVM_EXIT_SHUTDOWN signal");
                }
                // ... 其他退出原因
            }
            Ok(VcpuEmulation::Handled)
        }
        Err(e) => {
            // KVM_RUN 失败
            Err(VcpuError::Kvm(e))
        }
    }
}
```

## 完整流程图

```
Runtime (Go)
    │
    ├─> NewVM()
    │   ├─> NewHypervisor()          # 创建 Hypervisor 实例
    │   ├─> hypervisor.CreateVM()    # 创建 VM（未启动）
    │   │   │
    │   │   └─> Dragonball VMM (Rust)
    │   │       ├─> Vmm::new()
    │   │       │   └─> Vm::new()
    │   │       │       ├─> KvmContext::new()      # 打开 /dev/kvm
    │   │       │       ├─> kvm.create_vm()        # KVM_CREATE_VM
    │   │       │       ├─> ResourceManager::new() # 资源管理
    │   │       │       └─> DeviceManager::new()   # 设备管理
    │   │       │
    │   │       └─> 返回 VM 对象（未启动）
    │   │
    │   ├─> agent.configure()         # 配置 Agent
    │   │
    │   └─> hypervisor.StartVM()      # 启动 VM
    │       │
    │       └─> Dragonball VMM
    │           └─> Vm::start_microvm()
    │               ├─> init_guest_memory()        # 初始化内存
    │               │   ├─> 分配内存（hugetlbfs/shmem）
    │               │   └─> KVM_SET_USER_MEMORY_REGION
    │               │
    │               ├─> init_vcpu_manager()        # 初始化 VCPU 管理器
    │               │
    │               ├─> init_microvm()             # 初始化 MicroVM
    │               │   ├─> init_tss()             # x86_64: TSS
    │               │   ├─> setup_interrupt_controller()  # 中断控制器
    │               │   ├─> create_pit()           # x86_64: PIT
    │               │   ├─> init_devices()         # 初始化设备
    │               │   │   ├─> create_interrupt_manager()
    │               │   │   ├─> create_devices()  # Serial, Block, Net 等
    │               │   │   └─> start_devices()
    │               │   ├─> load_kernel()         # 加载内核镜像
    │               │   └─> create_boot_vcpus()   # 创建启动 VCPU
    │               │       ├─> KVM_CREATE_VCPU   # 为每个 VCPU
    │               │       ├─> configure()       # 配置 VCPU
    │               │       │   ├─> KVM_SET_CPUID2    # x86_64
    │               │       │   ├─> KVM_SET_MSRS      # x86_64
    │               │       │   ├─> KVM_SET_REGS
    │               │       │   ├─> KVM_SET_SREGS
    │               │       │   └─> KVM_ARM_VCPU_INIT # aarch64
    │               │       └─> 保存 VCPU 引用
    │               │
    │               ├─> init_configure_system()   # 配置系统
    │               │
    │               ├─> register_events()           # 注册事件
    │               │
    │               └─> start_boot_vcpus()        # 启动 VCPU 线程
    │                   ├─> 为每个 VCPU 创建线程
    │                   └─> 每个线程进入 KVM_RUN 循环
    │                       └─> Vcpu::run()
    │                           └─> 循环调用 KVM_RUN
    │                               └─> 处理退出原因（IO、MMIO、HLT 等）
```

## 关键 KVM 调用序列

### 1. VM 创建阶段

```
1. open("/dev/kvm", O_RDWR)           # 打开 KVM 设备
2. ioctl(kvm_fd, KVM_GET_API_VERSION) # 检查 API 版本
3. ioctl(kvm_fd, KVM_CHECK_EXTENSION) # 检查能力
4. ioctl(kvm_fd, KVM_CREATE_VM)       # 创建虚拟机
```

### 2. 内存设置阶段

```
5. mmap() 或 shm_open()               # 分配内存
6. ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION)  # 设置内存槽
```

### 3. 中断控制器设置阶段

**x86_64**:
```
7. ioctl(vm_fd, KVM_SET_TSS_ADDR)     # 设置 TSS 地址
8. ioctl(vm_fd, KVM_SET_IRQCHIP)      # 设置 IRQ chip
9. ioctl(vm_fd, KVM_SET_PIT2)         # 设置 PIT
10. ioctl(vm_fd, KVM_SET_GSI_ROUTING) # 设置中断路由
```

**aarch64**:
```
7. ioctl(vm_fd, KVM_CREATE_DEVICE)    # 创建 VGIC 设备
```

### 4. VCPU 创建阶段

```
11. ioctl(vm_fd, KVM_CREATE_VCPU, vcpu_id)  # 创建 VCPU
12. mmap(vcpu_fd, KVM_VCPU_MMAP_SIZE)       # 映射 VCPU 运行结构
```

### 5. VCPU 配置阶段

**x86_64**:
```
13. ioctl(vcpu_fd, KVM_SET_CPUID2)    # 设置 CPUID
14. ioctl(vcpu_fd, KVM_SET_MSRS)      # 设置 MSR
15. ioctl(vcpu_fd, KVM_SET_REGS)      # 设置通用寄存器
16. ioctl(vcpu_fd, KVM_SET_SREGS)     # 设置特殊寄存器
17. ioctl(vcpu_fd, KVM_SET_FPU)       # 设置 FPU 状态
```

**aarch64**:
```
13. ioctl(vcpu_fd, KVM_ARM_PREFERRED_TARGET)  # 获取首选目标
14. ioctl(vcpu_fd, KVM_ARM_VCPU_INIT)         # 初始化 VCPU
15. ioctl(vcpu_fd, KVM_SET_ONE_REG)           # 设置寄存器
```

### 6. VCPU 运行阶段

```
18. ioctl(vcpu_fd, KVM_RUN)           # 运行 VCPU（循环调用）
    ├─> KVM_EXIT_IO                  # IO 操作
    ├─> KVM_EXIT_MMIO                # MMIO 访问
    ├─> KVM_EXIT_HLT                  # HLT 指令
    ├─> KVM_EXIT_SHUTDOWN             # 关机
    └─> ... 其他退出原因
```

## 架构差异总结

### x86_64 流程

1. **初始化 TSS**: `KVM_SET_TSS_ADDR`
2. **设置中断控制器**: `KVM_SET_IRQCHIP`（必须在创建 VCPU 之前）
3. **创建 PIT**: `KVM_SET_PIT2`
4. **创建 VCPU**: `KVM_CREATE_VCPU`（可以在 VM 启动后创建）
5. **配置 VCPU**: CPUID, MSR, 寄存器等

### aarch64 流程

1. **创建 VCPU**: `KVM_CREATE_VCPU`（必须在设置 IRQ chip 之前）
2. **初始化 VCPU**: `KVM_ARM_VCPU_INIT`
3. **设置 GIC**: `KVM_CREATE_DEVICE` for VGIC
4. **配置 VCPU**: 寄存器等

**关键差异**:
- **VCPU 创建顺序**: x86_64 先设置 IRQ chip，aarch64 先创建 VCPU
- **VCPU 热插拔**: aarch64 需要在启动时创建所有 VCPU（max_vcpu_count）
- **设备支持**: x86_64 有 PIT，aarch64 有 GIC

## 内存管理

### 内存类型

1. **hugetlbfs**: 使用大页内存
   - 路径: `/dev/hugepages/dragonball/{instance_id}`
   - 优势: 减少 TLB miss，提高性能

2. **shmem**: 使用共享内存
   - 默认类型
   - 更灵活，但性能略低

### 内存映射流程

```
1. 分配内存（mmap 或 shm_open）
2. 创建 AddressSpaceRegion
3. 分配 KVM 内存槽号
4. 调用 KVM_SET_USER_MEMORY_REGION
   - slot: 内存槽号
   - guest_phys_addr: Guest 物理地址
   - memory_size: 内存大小
   - userspace_addr: Host 虚拟地址
```

## 设备初始化

### 设备创建顺序

1. **中断管理器**: 创建 IRQ routing 表
2. **Serial/Console**: 串口和控制台设备
3. **Block 设备**: virtio-blk（如果配置了）
4. **Network 设备**: virtio-net（如果配置了）
5. **VSock 设备**: virtio-vsock（用于 Runtime-Agent 通信）
6. **其他设备**: 根据配置添加

### 设备注册

每个设备需要：
1. 分配资源（IO 端口、MMIO 地址、IRQ）
2. 注册到设备管理器
3. 设置 IRQ routing（如果使用 IRQFD）
4. 启动设备（激活 virtio 队列等）

## VCPU 线程模型

### 线程结构

- **VMM 主线程**: 处理 API 请求和事件循环
- **VCPU 线程**: 每个 VCPU 一个独立线程
  - 线程名: `vcpu-{index}`
  - 职责: 运行 `KVM_RUN` 循环，处理退出原因

### VCPU 状态机

```
Paused → Running → WaitingExit → Exited
   ↑         ↓
   └─────────┘
```

- **Paused**: VCPU 已创建但未运行
- **Running**: VCPU 正在运行（KVM_RUN）
- **WaitingExit**: 等待退出
- **Exited**: VCPU 已退出

## 错误处理

### 常见错误

1. **KVM 不可用**: `/dev/kvm` 不存在或权限不足
2. **API 版本不匹配**: KVM API 版本不是 12
3. **能力缺失**: 缺少必需的能力（Irqchip, Irqfd 等）
4. **内存分配失败**: 无法分配足够的内存
5. **VCPU 创建失败**: 超过最大 VCPU 数量限制
6. **设备初始化失败**: 设备资源冲突或配置错误

### 清理机制

如果任何步骤失败，会执行清理：
1. 停止所有 VCPU 线程
2. 移除所有设备
3. 释放内存
4. 关闭 VM fd
5. 关闭 KVM fd

## 性能优化

### 1. 内存预分配

- 支持大页内存预分配
- 减少运行时内存分配开销

### 2. VCPU 固定

- 支持 CPU 亲和性设置
- 减少 CPU 迁移开销

### 3. 中断优化

- 使用 IRQFD 直接注入中断
- 减少 VMM 参与的中断处理

### 4. 设备优化

- 使用 virtio 设备（高性能）
- 支持 vhost-user 后端（用户空间处理）

## 相关文件

### Go Runtime
- `src/runtime/virtcontainers/vm.go`: VM 对象管理
- `src/runtime/virtcontainers/sandbox.go`: Sandbox 管理
- `src/runtime/virtcontainers/hypervisor.go`: Hypervisor 接口

### Dragonball VMM (Rust)
- `src/dragonball/src/vmm.rs`: VMM 主对象
- `src/dragonball/src/vm/mod.rs`: VM 对象
- `src/dragonball/src/vm/x86_64.rs`: x86_64 特定实现
- `src/dragonball/src/vm/aarch64.rs`: aarch64 特定实现
- `src/dragonball/src/vcpu/vcpu_manager.rs`: VCPU 管理器
- `src/dragonball/src/vcpu/vcpu_impl.rs`: VCPU 实现
- `src/dragonball/src/kvm_context.rs`: KVM 上下文
- `src/dragonball/src/address_space_manager.rs`: 地址空间管理
- `src/dragonball/src/device_manager/mod.rs`: 设备管理器

## 总结

Kata Containers 的虚拟机创建流程分为多个阶段：

1. **Runtime 层**: Go 代码创建 Hypervisor 实例并调用接口
2. **VMM 层**: Dragonball 创建 VMM 和 VM 对象
3. **KVM 层**: 通过 KVM ioctl 创建和配置虚拟机
4. **启动阶段**: 初始化内存、设备、VCPU，然后启动 VCPU 线程

整个过程充分利用了 KVM 的硬件虚拟化能力，同时通过 Rust 的类型安全性和性能优化，实现了轻量级、高性能的虚拟机管理。

