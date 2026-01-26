# Kata Agent 启动流程

## 概述

Kata Agent 是运行在 Guest VM 内部的组件，负责管理容器的生命周期。它通过 ttRPC (基于 VSock) 与 Kata Runtime 通信，接收来自 Host 的容器管理请求。

## 整体架构

```
Kata Runtime (Host)
    ↓ (VSock)
Kata Agent (Guest VM)
    ↓
容器管理 (创建、启动、停止容器等)
```

## 启动流程

### 阶段 1: 程序入口 (main)

**文件**: `src/agent/src/main.rs`

```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. 解析命令行参数
    let args = AgentOpts::parse();
    
    // 2. 处理版本信息
    if args.version {
        println!("kata-agent version ...");
        exit(0);
    }
    
    // 3. 处理 Init 子命令（用于容器初始化）
    if let Some(SubCommand::Init {}) = args.subcmd {
        reset_sigpipe();
        rustjail::container::init_child();
        exit(0);
    }
    
    // 4. 创建 Tokio 运行时
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    
    // 5. 检测是否为 init 模式（PID == 1）
    let init_mode = unistd::getpid() == Pid::from_raw(1);
    
    // 6. 运行主逻辑
    let result = rt.block_on(real_main(init_mode));
    
    // 7. 如果是 init 模式，关机
    if init_mode {
        sync();
        let _ = reboot(RebootMode::RB_POWER_OFF);
    }
    
    result
}
```

**关键点**:
- **Init 模式**: 当 Agent 作为 PID 1 运行时（作为 init 进程），需要执行额外的初始化工作
- **Init 子命令**: 用于容器内部进程的初始化（通过 `rustjail::container::init_child()`）

### 阶段 2: 主逻辑初始化 (real_main)

**文件**: `src/agent/src/main.rs`

```rust
async fn real_main(init_mode: bool) -> Result<(), Box<dyn std::error::Error>> {
    // 1. 设置环境变量
    env::set_var("RUST_BACKTRACE", "full");
    
    // 2. 初始化任务列表（用于清理）
    let mut tasks: Vec<JoinHandle<Result<()>>> = vec![];
    
    // 3. 初始化控制台
    console::initialize();
    
    // 4. 创建日志管道（支持 VSock 日志）
    let (rfd, wfd) = unistd::pipe2(OFlag::O_CLOEXEC)?;
    
    // 5. 创建关闭信号通道
    let (shutdown_tx, shutdown_rx) = channel(true);
    
    // 6. Init 模式特殊处理
    if init_mode {
        // 6.1 创建临时 logger（在挂载 proc 之前）
        let newwfd = dup(wfd)?;
        let writer = unsafe { File::from_raw_fd(newwfd) };
        let (logger, logger_async_guard) =
            logging::create_logger(NAME, "agent", slog::Level::Debug, writer);
        
        // 6.2 挂载基础文件系统（必须在此之前挂载 proc）
        general_mount(&logger)?;
        
        // 6.3 初始化配置（从 /proc/cmdline 读取）
        lazy_static::initialize(&AGENT_CONFIG);
        let cgroup_v2 = AGENT_CONFIG.unified_cgroup_hierarchy 
            || AGENT_CONFIG.cgroup_no_v1 == "all";
        
        // 6.4 初始化 Agent 作为 init 进程
        init_agent_as_init(&logger, cgroup_v2)?;
        drop(logger_async_guard);
    } else {
        // 非 init 模式：直接初始化配置
        lazy_static::initialize(&AGENT_CONFIG);
    }
    
    // 7. 启动日志任务（通过 VSock 或 stdout）
    let config = &AGENT_CONFIG;
    let log_vport = config.log_vport as u32;
    let log_handle = tokio::spawn(create_logger_task(rfd, log_vport, shutdown_rx.clone()));
    tasks.push(log_handle);
    
    // 8. 创建正式 logger（从 /proc/cmdline 读取日志级别）
    let writer = unsafe { File::from_raw_fd(wfd) };
    let (logger, logger_async_guard) =
        logging::create_logger(NAME, "agent", config.log_level, writer);
    
    // 9. 打印启动信息
    announce(&logger, config);
    
    // 10. 设置全局 logger（用于 RPC）
    let global_logger = slog_scope::set_global_logger(logger.new(o!("subsystem" => "rpc")));
    global_logger.cancel_reset();
    
    // 11. 设置 ttrpc 日志重定向（如果启用 Trace 级别）
    if config.log_level == slog::Level::Trace {
        ttrpc_log_guard = Ok(slog_stdlog::init()?);
    }
    
    // 12. 设置追踪（如果启用）
    if config.tracing {
        tracer::setup_tracing(NAME, &logger)?;
    }
    
    // 13. 启动根追踪 span
    let root_span = span!(tracing::Level::TRACE, "root-span");
    let span_guard = root_span.enter();
    
    // 14. 启动文件描述符透传 IO 监听器（如果配置）
    let passfd_listener_port = config.passfd_listener_port as u32;
    if passfd_listener_port != 0 {
        passfd_io::start_listen(passfd_listener_port).await?;
    }
    
    // 15. 启动 Sandbox（核心逻辑）
    start_sandbox(&logger, config, init_mode, &mut tasks, shutdown_rx.clone()).await?;
    
    // 16. 清理和关闭
    // ... 清理代码 ...
}
```

**关键步骤**:

#### 2.1 Init 模式初始化 (`init_agent_as_init`)

**文件**: `src/agent/src/main.rs`

```rust
fn init_agent_as_init(logger: &Logger, unified_cgroup_hierarchy: bool) -> Result<()> {
    // 1. 挂载 cgroups
    cgroups_mount(logger, unified_cgroup_hierarchy)?;
    
    // 2. 设置 /dev/ptmx 符号链接
    fs::remove_file(Path::new("/dev/ptmx"))?;
    unixfs::symlink(Path::new("/dev/pts/ptmx"), Path::new("/dev/ptmx"))?;
    
    // 3. 创建新的会话
    unistd::setsid()?;
    
    // 4. 设置控制终端
    unsafe {
        libc::ioctl(std::io::stdin().as_raw_fd(), libc::TIOCSCTTY, 1);
    }
    
    // 5. 设置 PATH 环境变量
    env::set_var("PATH", "/bin:/sbin/:/usr/bin/:/usr/sbin/");
    
    // 6. 设置主机名
    let contents = std::fs::read_to_string("/etc/hostname")
        .unwrap_or_else(|_| String::from("localhost"));
    let hostname = contents.split(' ').next().unwrap().trim();
    if unistd::sethostname(OsStr::new(hostname)).is_err() {
        warn!(logger, "failed to set hostname");
    }
    
    Ok(())
}
```

#### 2.2 基础文件系统挂载 (`general_mount`)

**文件**: `src/agent/src/mount.rs`

```rust
pub fn general_mount(logger: &Logger) -> Result<()> {
    // 挂载基础文件系统
    for mount in INIT_ROOTFS_MOUNTS.iter() {
        baremount(
            Path::new(mount.src),
            Path::new(mount.dest),
            mount.fstype,
            parse_mount_options(&mount.options)?,
            "",
            logger,
        )?;
    }
}
```

**挂载的文件系统**:
- `/proc` - procfs
- `/sys` - sysfs
- `/dev` - devtmpfs
- `/dev/shm` - tmpfs
- `/dev/pts` - devpts
- `/run` - tmpfs

### 阶段 3: Sandbox 启动 (start_sandbox)

**文件**: `src/agent/src/main.rs`

```rust
async fn start_sandbox(
    logger: &Logger,
    config: &AgentConfig,
    init_mode: bool,
    tasks: &mut Vec<JoinHandle<Result<()>>>,
    shutdown: Receiver<bool>,
) -> Result<()> {
    // 1. 启动调试控制台（如果启用）
    if config.debug_console {
        let debug_console_task = tokio::task::spawn(console::debug_console_handler(
            logger.clone(),
            config.debug_console_vport as u32,
            shutdown.clone(),
        ));
        tasks.push(debug_console_task);
    }
    
    // 2. 创建 Sandbox 对象
    let s = Sandbox::new(logger).context("Failed to create sandbox")?;
    
    // 3. Init 模式：处理 localhost 网络接口
    if init_mode {
        s.rtnl.handle_localhost().await?;
    }
    
    // 4. 初始化安全策略（如果启用）
    #[cfg(feature = "agent-policy")]
    if let Err(e) = initialize_policy().await {
        error!(logger, "Failed to initialize agent policy: {:?}", e);
        std::process::abort();
    }
    
    // 5. 将 Sandbox 包装为 Arc<Mutex<Sandbox>>
    let sandbox = Arc::new(Mutex::new(s));
    
    // 6. 启动信号处理任务
    let signal_handler_task = tokio::spawn(setup_signal_handler(
        logger.clone(),
        sandbox.clone(),
        shutdown.clone(),
    ));
    tasks.push(signal_handler_task);
    
    // 7. 启动 uevents 监听任务
    let uevents_handler_task = tokio::spawn(watch_uevents(
        sandbox.clone(),
        shutdown.clone(),
    ));
    tasks.push(uevents_handler_task);
    
    // 8. 创建关闭通道
    let (tx, rx) = tokio::sync::oneshot::channel();
    sandbox.lock().await.sender = Some(tx);
    
    // 9. 初始化 initdata（如果存在）
    let initdata_return_value = initdata::initialize_initdata(logger).await?;
    
    // 10. 启动认证组件（如果配置）
    let gc_procs = config.guest_components_procs;
    if !attestation_binaries_available(logger, &gc_procs) {
        warn!(logger, "attestation binaries requested for launch not available");
    } else {
        init_attestation_components(logger, config, &initdata_return_value).await?;
    }
    
    // 11. 从 initdata 加载策略（如果提供）
    #[cfg(feature = "agent-policy")]
    if let Some(initdata_return_value) = initdata_return_value {
        if let Some(policy) = &initdata_return_value._policy {
            info!(logger, "using policy from initdata");
            AGENT_POLICY.lock().await.set_policy(policy).await?;
        }
    }
    
    // 12. 初始化内存代理（如果配置）
    let mut oma = None;
    if let Some(c) = &config.mem_agent {
        let (ma, _rt) = mem_agent::agent::MemAgent::new(
            c.memcg_config.clone(),
            c.compact_config.clone(),
        )?;
        oma = Some(ma);
    }
    
    // 13. 启动 RPC 服务器
    let mut server = rpc::start(
        sandbox.clone(),
        config.server_addr.as_str(),
        init_mode,
        oma,
    ).await?;
    
    // 14. 启动服务器
    server.start().await?;
    
    // 15. 等待关闭信号
    rx.await?;
    
    // 16. 关闭服务器
    server.shutdown().await?;
    
    Ok(())
}
```

#### 3.1 Sandbox 对象创建

**文件**: `src/agent/src/sandbox.rs`

```rust
pub fn new(logger: &Logger) -> Result<Self> {
    // 1. 检测根文件系统类型
    let fs_type = get_mount_fs_type("/")?;
    
    // 2. 创建事件通道
    let (tx, rx) = channel::<String>(100);
    let event_rx = Arc::new(Mutex::new(rx));
    
    // 3. 创建 Sandbox 对象
    Ok(Sandbox {
        logger: logger.new(o!("subsystem" => "sandbox")),
        id: String::new(),
        hostname: String::new(),
        network: Network::new(),
        containers: HashMap::new(),
        mounts: Vec::new(),
        container_mounts: HashMap::new(),
        uevent_map: HashMap::new(),
        uevent_watchers: Vec::new(),
        shared_utsns: Namespace::new(&logger),
        shared_ipcns: Namespace::new(&logger),
        sandbox_pidns: None,
        storages: HashMap::new(),
        running: false,
        no_pivot_root: fs_type.eq(TYPE_ROOTFS),
        sender: None,
        rtnl: Handle::new()?,  // 网络链路句柄
        hooks: None,
        event_rx,
        event_tx: Some(tx),
        bind_watcher: BindWatcher::new(),
        pcimap: HashMap::new(),
        devcg_info: Arc::new(RwLock::new(DevicesCgroupInfo::default())),
    })
}
```

**关键字段**:
- `containers`: 容器映射表
- `network`: 网络管理
- `shared_utsns`, `shared_ipcns`: 共享命名空间
- `rtnl`: 网络链路句柄（用于网络配置）
- `storages`: 存储设备映射

#### 3.2 Initdata 初始化

**文件**: `src/agent/src/initdata.rs`

```rust
pub async fn initialize_initdata(logger: &Logger) -> Result<Option<InitdataReturnValue>> {
    // 1. 检测 initdata 设备
    let Some(initdata_device) = detect_initdata_device(&logger).await? else {
        debug!(logger, "Initdata device not found, skip initdata initialization");
        return Ok(None);
    };
    
    // 2. 创建 initdata 目录
    tokio::fs::create_dir_all(INITDATA_PATH).await?;
    
    // 3. 读取 initdata 内容
    let initdata_content = read_initdata(&initdata_device).await?;
    
    // 4. 解析 TOML 格式的 initdata
    let initdata: InitData = toml::from_slice(&initdata_content)?;
    info!(logger, "Initdata version: {}", initdata.version());
    initdata.validate()?;
    
    // 5. 保存 initdata 到文件
    tokio::fs::write(INITDATA_TOML_PATH, &initdata_content).await?;
    
    // 6. 返回解析结果
    Ok(Some(InitdataReturnValue {
        _policy: initdata.policy().cloned(),
        // ... 其他字段
    }))
}
```

**Initdata 用途**:
- 传递配置信息到 Guest
- 传递安全策略
- 传递认证相关配置

#### 3.3 认证组件启动

**文件**: `src/agent/src/main.rs`

```rust
async fn init_attestation_components(
    logger: &Logger,
    config: &AgentConfig,
    initdata_return_value: &Option<InitdataReturnValue>,
) -> Result<()> {
    // 1. 启动认证相关进程
    launch_guest_component_procs(logger, config, initdata_return_value).await?;
    
    // 2. 初始化 CDH 客户端（如果 CDH socket 存在）
    match tokio::fs::metadata(CDH_SOCKET).await {
        Ok(md) => {
            if md.file_type().is_socket() {
                confidential_data_hub::init_cdh_client(CDH_SOCKET_URI).await?;
            }
        }
        Err(err) => warn!(logger, "Failed to probe CDH socket: {:?}", err),
    }
    
    Ok(())
}
```

**认证组件**:
- **Attestation Agent (AA)**: 认证代理
- **Confidential Data Hub (CDH)**: 机密数据中心
- **API Server REST**: REST API 服务器

### 阶段 4: RPC 服务器启动

**文件**: `src/agent/src/rpc.rs`

```rust
pub async fn start(
    s: Arc<Mutex<Sandbox>>,
    server_address: &str,
    init_mode: bool,
    oma: Option<mem_agent::agent::MemAgent>,
) -> Result<TtrpcServer> {
    // 1. 创建 Agent 服务
    let agent_service = Box::new(AgentService {
        sandbox: s,
        init_mode,
        oma,
    });
    let aservice = agent_ttrpc::create_agent_service(Arc::new(*agent_service));
    
    // 2. 创建 Health 服务
    let health_service = Box::new(HealthService {});
    let hservice = health_ttrpc::create_health(Arc::new(*health_service));
    
    // 3. 创建并配置 ttRPC 服务器
    let server = TtrpcServer::new()
        .bind(server_address)?  // 绑定地址（通常是 VSock）
        .register_service(aservice)  // 注册 Agent 服务
        .register_service(hservice);  // 注册 Health 服务
    
    info!(sl(), "ttRPC server started"; "address" => server_address);
    
    Ok(server)
}
```

**RPC 服务**:
- **AgentService**: 提供容器管理 RPC 接口
  - `CreateSandbox`: 创建沙箱
  - `CreateContainer`: 创建容器
  - `StartContainer`: 启动容器
  - `StopContainer`: 停止容器
  - `RemoveContainer`: 删除容器
  - 等等...
- **HealthService**: 提供健康检查接口
  - `Check`: 健康检查
  - `Version`: 版本信息

**服务器地址格式**:
- VSock: `vsock:///dev/vsock:1024`
- Unix Socket: `unix:///path/to/socket`

## 完整启动流程图

```
main()
    │
    ├─> 解析命令行参数
    │
    ├─> 创建 Tokio 运行时
    │
    ├─> 检测 init_mode (PID == 1?)
    │
    └─> real_main(init_mode)
        │
        ├─> 初始化控制台
        │
        ├─> 创建日志管道
        │
        ├─> [init_mode] 临时 logger
        │   ├─> general_mount()  # 挂载基础文件系统
        │   │   ├─> /proc
        │   │   ├─> /sys
        │   │   ├─> /dev
        │   │   ├─> /dev/shm
        │   │   ├─> /dev/pts
        │   │   └─> /run
        │   │
        │   ├─> 初始化配置（从 /proc/cmdline）
        │   │
        │   └─> init_agent_as_init()
        │       ├─> cgroups_mount()
        │       ├─> 设置 /dev/ptmx
        │       ├─> setsid()
        │       ├─> 设置控制终端
        │       ├─> 设置 PATH
        │       └─> 设置主机名
        │
        ├─> 启动日志任务（VSock 或 stdout）
        │
        ├─> 创建正式 logger
        │
        ├─> 设置全局 logger
        │
        ├─> 设置追踪（如果启用）
        │
        ├─> 启动 passfd IO 监听器（如果配置）
        │
        └─> start_sandbox()
            │
            ├─> 启动调试控制台（如果启用）
            │
            ├─> Sandbox::new()
            │   ├─> 检测文件系统类型
            │   ├─> 创建事件通道
            │   ├─> 初始化网络句柄
            │   └─> 初始化命名空间
            │
            ├─> [init_mode] handle_localhost()  # 启用 lo 接口
            │
            ├─> 初始化安全策略（如果启用）
            │
            ├─> 启动信号处理任务
            │
            ├─> 启动 uevents 监听任务
            │
            ├─> 初始化 initdata
            │   ├─> 检测 initdata 设备
            │   ├─> 读取 initdata
            │   ├─> 解析 TOML
            │   └─> 保存到文件
            │
            ├─> 启动认证组件（如果配置）
            │   ├─> 启动 Attestation Agent
            │   ├─> 启动 Confidential Data Hub
            │   └─> 启动 API Server REST
            │
            ├─> 初始化内存代理（如果配置）
            │
            └─> rpc::start()
                ├─> 创建 AgentService
                ├─> 创建 HealthService
                ├─> 创建 TtrpcServer
                ├─> 绑定地址（VSock）
                ├─> 注册服务
                └─> server.start()  # 开始监听
                    │
                    └─> 等待 RPC 请求...
```

## 关键配置

### 从 `/proc/cmdline` 读取的配置

Agent 从内核命令行参数读取配置，例如：

```
agent.log_vport=1024
agent.debug_console_vport=1025
agent.server_addr=vsock:///dev/vsock:1024
agent.log_level=info
```

### 配置项说明

- `log_vport`: 日志 VSock 端口
- `debug_console_vport`: 调试控制台 VSock 端口
- `server_addr`: RPC 服务器地址
- `log_level`: 日志级别
- `passfd_listener_port`: 文件描述符透传端口
- `guest_components_procs`: 认证组件配置
- `mem_agent`: 内存代理配置

## 运行模式

### 1. Init 模式 (PID == 1)

当 Agent 作为 PID 1 运行时：
- 执行基础文件系统挂载
- 初始化 cgroups
- 设置系统环境（PATH、主机名等）
- 处理 localhost 网络接口
- 退出时执行关机

### 2. 普通模式

当 Agent 不作为 PID 1 运行时：
- 跳过基础文件系统挂载（假设已挂载）
- 跳过系统环境设置
- 直接启动 RPC 服务器

## RPC 接口

Agent 提供的主要 RPC 接口：

### Sandbox 管理
- `CreateSandbox`: 创建沙箱
- `DestroySandbox`: 销毁沙箱
- `UpdateInterface`: 更新网络接口
- `UpdateRoutes`: 更新路由
- `ListInterfaces`: 列出网络接口
- `ListRoutes`: 列出路由

### 容器管理
- `CreateContainer`: 创建容器
- `StartContainer`: 启动容器
- `StopContainer`: 停止容器
- `RemoveContainer`: 删除容器
- `WaitProcess`: 等待进程
- `SignalProcess`: 发送信号给进程
- `TtyWinResize`: 调整 TTY 窗口大小

### 存储管理
- `AddSwap`: 添加交换分区
- `GetVolumeStats`: 获取卷统计信息
- `ResizeVolume`: 调整卷大小

### 其他
- `CopyFile`: 复制文件
- `GetIPTables`: 获取 iptables 规则
- `SetIPTables`: 设置 iptables 规则
- `GetMetrics`: 获取指标
- `GetGuestDetails`: 获取 Guest 详情

## 相关文件

### 核心文件
- `src/agent/src/main.rs`: 主入口
- `src/agent/src/sandbox.rs`: Sandbox 管理
- `src/agent/src/rpc.rs`: RPC 服务器实现
- `src/agent/src/config.rs`: 配置管理
- `src/agent/src/mount.rs`: 文件系统挂载
- `src/agent/src/initdata.rs`: Initdata 处理
- `src/agent/src/network.rs`: 网络管理
- `src/agent/src/signal.rs`: 信号处理
- `src/agent/src/uevent.rs`: Uevent 监听

### 设备管理
- `src/agent/src/device/`: 设备处理
  - `block_device_handler.rs`: 块设备
  - `network_device_handler.rs`: 网络设备
  - `vfio_device_handler.rs`: VFIO 设备

### 存储管理
- `src/agent/src/storage.rs`: 存储设备管理

## 总结

Kata Agent 的启动流程分为几个关键阶段：

1. **程序入口**: 解析参数，检测运行模式
2. **初始化**: 设置日志、挂载文件系统（init 模式）、初始化配置
3. **Sandbox 创建**: 创建 Sandbox 对象，启动后台任务
4. **RPC 服务器**: 启动 ttRPC 服务器，开始监听请求

Agent 通过 VSock 与 Host 的 Runtime 通信，接收容器管理请求并执行相应的操作。整个系统设计为异步、事件驱动的架构，使用 Tokio 运行时处理并发请求。

