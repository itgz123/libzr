# libzr —— 基于 Zephyr 的机器人框架

`libzr` 是一个跑在 [Zephyr RTOS](https://zephyrproject.org/) 上的机器人框架：
器件驱动在 `drv/`，与硬件无关的算法和工具在 `lib/`，构建辅助在 `cmake/`，
板级定义拆成独立子模块 [`libzr_board`](https://github.com/itgz123/libzr_board)。

你的 app 通过 **git 子模块** 引入 `libzr`，配好 Zephyr 环境后即可编译烧录。

```
libzr/
├── scripts/
│   └── install_zephyr/
│       ├── linux/install_zephyr.sh      # Linux：系统依赖 + Python 环境 + west 工作区
│       └── windows/install_zephyr.bat   # Windows：同上
├── libzr_board/                         # 子模块：板级定义
├── drv/                                 # 器件驱动
├── lib/                                 # 硬件无关的算法 / 工具
├── cmake/                               # 构建辅助
├── CMakeLists.txt                       # Zephyr 模块入口
└── LICENSE                              # MIT
```

> 本文件只管 **libzr 怎么用**。Zephyr 本身的操作细节（west 工作流、Kconfig、
> devicetree、烧录调试）不在这里展开，按 Zephyr 官方文档操作即可。

---

## 快速开始

两步：**引入子模块 → 安装 Zephyr 环境**。libzr 通过 app 的 `CMakeLists.txt`
接入，不需要生成或维护任何额外的路径配置文件。

### 一、把 libzr 加进你的 app

```bash
cd <你的 app 仓库>
git submodule add git@github.com:itgz123/libzr.git libzr
git submodule update --init --recursive    # 注意 --recursive：libzr 自己还带 libzr_board
```

如果你拿到的是别人做好的 app 仓库，直接递归拉取即可：

```bash
git clone --recurse-submodules <app 仓库地址>
```

> `libzr_board` 的版本由 `libzr` 这次提交锁死，不需要（也不应该）单独更新它。
> 升级框架 = 在 app 里把 `libzr` 切到新 commit，再 `git submodule update --init --recursive`。

### 二、安装 Zephyr 环境

环境由三部分组成，缺一不可：

| 组成 | 装在哪 | 谁来装 |
| --- | --- | --- |
| **Zephyr SDK** | `$ZR_SDK`（默认 `/opt/zephyr-sdk-1.0.1_linux-x86_64_gnu`） | 手动下载解压 + `setup.sh` |
| **系统依赖** | 发行版包管理器 | `install_zephyr.sh` 自动装 |
| **Python 环境** | conda 环境 `$ZR_CONDA_ENV`（默认 `zephyr`） | `install_zephyr.sh` 自动建 |
| **Zephyr 源码与模块** | west 工作区 `$ZR_WS`（默认 `~/zephyr_workplace/main`） | `install_zephyr.sh` 自动拉 |

#### 1. Linux

**① 手动安装 SDK**（SDK 太大、版本要自己选，脚本不代劳）

1. 到 <https://github.com/zephyrproject-rtos/sdk-ng/releases/latest> 下载
   `zephyr-sdk-x.x.x_linux-x86_64_gnu.tar.xz`
2. 解压到 `$ZR_SDK`（默认 `/opt/zephyr-sdk-1.0.1_linux-x86_64_gnu`）
3. 在 SDK 目录里执行：

   ```bash
   cd "$ZR_SDK"
   ./setup.sh -h -c
   ```

   - `-h` 装 host tools（**注意：`-h` 不是 help，`-?` 才是**）
   - `-c` 注册 CMake 包，之后 `find_package(Zephyr-sdk)` 能直接找到，连
     `ZEPHYR_SDK_INSTALL_DIR` 都不用设
   - **不要加 `-t`**：`gnu/` 下工具链已解压，脚本会自动跳过；加了反而会重新联网下载

**② 运行环境安装脚本**

```bash
# 先看要做什么，不改系统（推荐）
bash libzr/scripts/install_zephyr/linux/install_zephyr.sh --check-only

# 确认无误再执行。用普通用户运行，脚本内部自己调 sudo；
# 不要整个脚本加 sudo，否则 conda 环境和工作区会变成 root 所有。
bash libzr/scripts/install_zephyr/linux/install_zephyr.sh -y
```

脚本依次完成：

1. 用 `apt` / `dnf` / `pacman` / `zypper` 安装系统依赖（见下方「依赖总表」）
2. 创建 conda 环境 `$ZR_CONDA_ENV`，Python 锁定 **3.12**
3. `west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.4.2 "$ZR_WS"`
4. `west update`（可中断后重跑）与 `west packages pip --install`
5. 把机器级路径写进 `~/.config/libzr/env.sh`（见「路径约定」）

**③ udev 规则**（烧录调试用 ST-Link / OpenOCD 时必需，否则每次都要 sudo）

```bash
sudo cp "$ZR_SDK/hosttools/sysroots/x86_64-pokysdk-linux/usr/share/openocd/contrib/60-openocd.rules" \
        /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

> 规则文件**不在 Zephyr 仓库里**（网上常说的 `zephyr/scripts/99-openocd.rules`
> 早已移除），它在 Zephyr SDK 内部。

**④ 验证**

```bash
conda activate "$ZR_CONDA_ENV"
west --version
west topdir                      # 应输出 $ZR_WS
west list -f '{path}' | wc -l    # 应为 68 左右（Zephyr + 67 个模块）
arm-zephyr-eabi-gcc --version
```

#### 2. Windows

1. 下载 `zephyr-sdk-x.x.x_windows-x86_64_gnu.7z`（同一发布页），解压到 `%ZR_SDK%`
2. 运行 `libzr/scripts/install_zephyr/windows/install_zephyr.bat`
3. 用 **Git Bash** 或 **cmd** 打开新终端，执行上面的「④ 验证」

> Windows 下的 `west`、`cmake`、`ninja` 都由脚本装进 conda 环境或 `%PATH%`；
> 不要把 SDK 路径写死到系统环境变量里，换版本时只改 `ZR_SDK` 即可。

### 三、在 app 里接入 libzr

不需要运行配置脚本。在 app 的 `CMakeLists.txt` 里用**相对于 app 自身**的路径，
把 libzr 注册成 Zephyr 模块、把 libzr_board 注册成板级根目录：

```cmake
cmake_minimum_required(VERSION 3.20.0)

set(LIBZR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/libzr"        CACHE PATH "libzr 子模块")
set(LIBZR_BOARD_DIR "${LIBZR_DIR}/libzr_board"           CACHE PATH "libzr_board 子模块")

# 必须在 find_package(Zephyr) 之前
list(APPEND ZEPHYR_EXTRA_MODULES "${LIBZR_DIR}")
list(APPEND BOARD_ROOT          "${LIBZR_BOARD_DIR}")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(<你的 app>)

target_sources(app PRIVATE src/main.c)
```

两条硬性要求：

- 两个路径必须是**绝对路径**。上面用 `${CMAKE_CURRENT_SOURCE_DIR}` 拼出来，
  基准是 app 自己，不含任何机器信息，可以放心提交。
- 两个 `list(APPEND)` 必须在 `find_package(Zephyr)` **之前**，否则 Zephyr
  扫描模块和板级时还看不到它们。

`libzr` 自己还需要 `zephyr/module.yml`（或 `zephyr/CMakeLists.txt` + `zephyr/Kconfig`）
才会被识别为模块。

### 四、构建与烧录

```bash
# 载入机器级路径（ZR_WS / ZEPHYR_BASE / ZEPHYR_SDK_INSTALL_DIR）
source ~/.config/libzr/env.sh
conda activate "$ZR_CONDA_ENV"

# app 在 west 工作区里
cd "$ZR_WS/<你的 app>"
west build -b <板子> -d build .
west flash -d build

# app 在工作区外（独立应用；ZEPHYR_BASE 已由 env 文件提供）
cd <你的 app>
west build -b <板子> -d build .
```

---

## 路径约定：设置一次，所有 app 共用

路径分两层。核心原则：**app 仓库里不提交任何绝对路径**——否则换个人、换台机器
就得改配置，一个 app 根本没法多人合作。

### 第一层：机器级路径（每台机器设一次）

安装脚本会写 `~/.config/libzr/env.sh`，之后每个新 shell 只要：

```bash
source ~/.config/libzr/env.sh
```

内容形如：

```bash
export ZR_WS="$HOME/zephyr_workplace/main"                    # west 工作区
export ZR_SDK="/opt/zephyr-sdk-1.0.1_linux-x86_64_gnu"        # SDK 解压位置
export ZR_CONDA_ENV="zephyr"                                  # conda 环境名
export ZR_MR="v4.4.2"                                         # Zephyr 版本
export ZEPHYR_SDK_INSTALL_DIR="$ZR_SDK"                       # 构建系统找 SDK
export ZEPHYR_BASE="$ZR_WS/zephyr"                            # 独立应用构建必需
```

这些是**和具体 app 无关**的东西。换 app、换机器只改这个文件，不动 app 仓库。

想换位置或不要它：

```bash
bash install_zephyr.sh --env-file ~/my_env.sh   # 写到别处
bash install_zephyr.sh --no-env                 # 不生成
```

也可以直接 `export ZR_WS=...` 覆盖默认值再跑脚本。

### 第二层：app 内路径（相对推导，不用配）

`libzr` 和 `libzr_board` 的位置随 app 目录变化，所以**不进环境变量**：

| 路径 | 怎么得到 |
| --- | --- |
| libzr 根目录 | app 的 `CMakeLists.txt` 用 `${CMAKE_CURRENT_SOURCE_DIR}/libzr` 推导 |
| libzr_board | `${LIBZR_DIR}/libzr_board`，跟着子模块走 |
| app 根目录 | app 的 `CMakeLists.txt` 所在目录（即 `west build .` 的 `.`） |

这些路径写在 app 的 `CMakeLists.txt` 里，但是以 app 自身为基准的**相对推导**，
所以同一个 app 仓库，甲 clone 到 `/home/a/work/robot`、乙 clone 到 `/opt/robot`，
两边都只需：

```bash
source ~/.config/libzr/env.sh
cd <app> && west build -b <板子> -d build .
```

**不需要改任何提交进仓库的文件。**

### 变量速查

| 变量 | 写入 env 文件 | 说明 |
| --- | --- | --- |
| `ZR_WS` | ✓ | west 工作区根目录。已有工作区就指过去 |
| `ZR_SDK` | ✓ | SDK 解压位置。**目录名是纯装饰的**，版本号读自 `sdk_version` |
| `ZR_CONDA_ENV` | ✓ | conda 环境名 |
| `ZR_MR` | ✓ | Zephyr 版本 / 分支 / tag |
| `ZEPHYR_SDK_INSTALL_DIR` | ✓ | Zephyr 构建找 SDK 用 |
| `ZEPHYR_BASE` | ✓ | 独立应用构建必需 |
| `ZR_ENV_FILE` | — | env 文件位置，默认 `~/.config/libzr/env.sh` |
| `ZR_LIBZR` / `ZR_BOARD` | ✗ | 随 app 目录变化，由 app 侧相对推导 |

**脚本选项**

| 选项 | 作用 |
| --- | --- |
| `-n, --check-only` | 只检测，不装任何东西 |
| `-y, --yes` | 不询问，直接装 |
| `--no-conda` | 跳过 conda 环境创建 |
| `--install-conda` | 没检测到 conda 时自动装 Miniconda |
| `--reuse-workspace` | 复用 `ZR_WS`，不重新 `west init` |
| `--workspace DIR` | 等价于 `ZR_WS` |
| `--sdk DIR` | 等价于 `ZR_SDK` |
| `--mr REV` | 等价于 `ZR_MR` |
| `--env-file FILE` | 环境变量输出文件 |
| `--no-env` | 不写环境变量文件 |
| `-h, --help` | 显示帮助（**注意和 SDK 的 `setup.sh -h` 含义不同**） |

**边界约定**

- **不管 SDK**。SDK 只检测不安装，缺失时打印提示和下载地址。
- **不覆盖已有工作区**。`$ZR_WS` 里已有 `.west/` 时，不加 `--reuse-workspace` 就不动它。
- **不往 app 里写绝对路径**。env 文件只放机器级变量，其余靠相对推导。
- **幂等**。已装的依赖一律跳过，可反复执行。

---

## 依赖总表

来源四分类：**SDK** = Zephyr SDK 自带、**系统** = 发行版包管理器、
**conda** = conda 环境（含其内部 pip 段）、**脚本** = 本仓库提供的脚本。

### 一、交叉工具链与主机工具（来源：Zephyr SDK）

装一次，所有架构共用。SDK 1.0.1 的 host tools 是 Yocto SDK 封装的。

| 依赖 | 功能 | 来源 |
| --- | --- | --- |
| `arm-zephyr-eabi-gcc` 14.3.0 | ARM Cortex-M 交叉编译器 | SDK |
| `arm-zephyr-eabi-g++` | ARM C++ 交叉编译器 | SDK |
| `arm-zephyr-eabi-gdb` 16.2 | 交叉调试器 | SDK |
| `arm-zephyr-eabi-gdb-py` | 带 Python 支持的 GDB（`west debug` 优先用它） | SDK |
| `arm-zephyr-eabi-{ld,as,objcopy,objdump,ar,size}` | Binutils 2.43.1 | SDK |
| `picolibc` 1.8.10 | 嵌入式 C 运行库 | SDK |
| `openocd` 0.12.0 | 烧录 + GDB Server，接 ST-Link | SDK |
| `dtc` 1.7.0+ | 设备树编译器（优先于系统那份） | SDK |
| `qemu-system-*` 10.0.2 | 无硬件时模拟运行 | SDK |
| 其余 33 个架构工具链 | aarch64 / riscv64 / xtensa … | SDK |

### 二、系统依赖（来源：发行版包管理器）

| 依赖 | 功能 | 来源 |
| --- | --- | --- |
| `git` | 版本控制，拉子模块与 Zephyr 源码 | 系统 |
| `cmake` | 构建系统，`west build` 底层调用 | 系统 |
| `ninja-build` | 构建后端 | 系统 |
| `gperf` | 构建期生成关键字/哈希表 | 系统 |
| `make` | 主机端构建（dtc、gen_isr_tables 等） | 系统 |
| `gcc` / `gcc-c++` | 主机端编译器 | 系统 |
| `dtc` | 设备树编译器（SDK 那份的后备） | 系统 |
| `dfu-util` | DFU 模式烧录 | 系统 |
| `wget` / `xz` / `file` / `gawk` | SDK 安装脚本的硬依赖 | 系统 |
| `ccache` | 编译缓存（可选） | 系统 |
| `pkgconf-pkg-config` | 依赖探测（可选） | 系统 |
| `libusb1-devel` | OpenOCD 访问 ST-Link（可选） | 系统 |
| `SDL2-devel` | `native_sim` 图形示例（可选） | 系统 |
| `glibc-devel.i686` / `libstdc++-devel.i686` | 裸 `native_sim`（32 位）需要；换 `-b native_sim/native/64` 可免（可选） | 系统 |

### 三、Python 环境（来源：conda-forge）

| 依赖 | 功能 | 来源 |
| --- | --- | --- |
| `python 3.12` | 解释器。**必须 3.12**，见下方说明 | conda |
| `pip` / `setuptools` / `wheel` | 打包工具链 | conda |
| `pyyaml` | 解析 YAML（Kconfig / devicetree 绑定） | conda |
| `packaging` | 版本号解析 | conda |
| `pyelftools` | 解析 ELF，生成 `.bin` / `.hex` | conda |
| `jsonschema` / `pykwalify` | 校验 schema | conda |
| `psutil` / `cbor2` / `colorama` / `gitpython` / `anytree` | 构建脚本依赖 | conda |
| `pyserial` | 串口，`west flash` 与串口监控 | conda |
| `pytest` / `pytest-subtests` | 测试框架 | conda |
| `requests` / `pygithub` / `pylint` / `numpy` / `tqdm` / `rich` / `sh` | 杂项 | conda |

### 四、Python 包（来源：pip，装在 conda 环境内）

| 依赖 | 功能 | 来源 |
| --- | --- | --- |
| `west` 1.5 | Zephyr 元构建工具 | conda |
| `esptool` | ESP32 系列烧录 | conda |
| `pyocd` | CMSIS-DAP / DAPLink 烧录与 GDB Server | conda |
| `canopen` | CANopen 协议栈 | conda |
| `protobuf` / `grpcio-tools` | 协议缓冲区代码生成 | conda |

### 五、由本仓库提供

| 文件 | 作用 | 来源 |
| --- | --- | --- |
| `scripts/install_zephyr/linux/install_zephyr.sh` | Linux 一键装环境 | 脚本 |
| `scripts/install_zephyr/windows/install_zephyr.bat` | Windows 一键装环境 | 脚本 |
| `libzr_board/` | 板级定义（子模块） | 脚本（git） |

---

## 为什么 python 必须锁 3.12

不是口味问题，是 ABI 硬约束。Zephyr SDK 1.0.1 的 `arm-zephyr-eabi-gdb-py`
**编译期就链接死了系统 Python 3.12**：

```console
$ ldd "$ZR_SDK/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gdb-py" | grep python
    libpython3.12.so.1.0 => /lib64/libpython3.12.so.1.0

$ arm-zephyr-eabi-gdb-py --batch -ex "python import sys; print(sys.version)"
3.12.14 (main, ...) [GCC ... (Red Hat ...)]
```

`west debug` 会把 conda 环境的 `site-packages` 通过 `PYTHONPATH` 交给它，
两边 ABI 必须一致。conda 环境建成 3.13 会导致 GDB 加载 Zephyr 的 Python 脚本失败。

---

## pyenv 与 conda 共存

如果你用 pyenv 管着 3.12，和 conda 环境会形成两套 Python。要点：

### 1. 构建路径：必须 conda 赢

`west`、`pyelftools`、`pyyaml` 都装在 conda 环境里，所以**必须先 `conda activate`**：

```console
$ conda activate "$ZR_CONDA_ENV"
$ which python
/home/<你>/miniconda3/envs/zephyr/bin/python     # 不是 ~/.pyenv/shims/python 就对
$ python --version
Python 3.12.x
```

如果仍然显示 pyenv 的路径，说明 shell 配置里 pyenv 的初始化排在 conda 之后，
把 conda 的 `source .../conda.sh` 挪到最后即可。

### 2. GDB 路径：内嵌的 Python 换不掉，但能桥接到 conda 的包

`gdb-py` 内嵌的是**系统** 3.12，既不是 pyenv 的也不是 conda 的，改不了。
但可以用 `PYTHONPATH` 让它读到 conda 环境里的包：

```console
$ PYTHONPATH="$CONDA_PREFIX/lib/python3.12/site-packages" \
    "$ZR_SDK/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gdb-py" \
    --batch -ex "python import elftools; print(elftools.__file__)"
/home/<你>/miniconda3/envs/zephyr/lib/python3.12/site-packages/elftools/__init__.py
```

日常 `west build` / `west flash` 不需要这一步。

---

## SDK 安装位置与可重定位

SDK 解压到 `$ZR_SDK`，然后在该目录里跑一次 `./setup.sh -h -c`。

**目录名是纯装饰的**，叫什么都能用。版本号来自 `sdk_version` 文件，
`ZEPHYR_SDK_INSTALL_DIR` 由 CMake Config 从自身路径反推：

```cmake
# cmake/Zephyr-sdkConfigVersion.cmake
file(READ ${CMAKE_CURRENT_LIST_DIR}/../sdk_version SDK_VERSION)

# cmake/Zephyr-sdkConfig.cmake
get_filename_component(ZEPHYR_SDK_INSTALL_DIR ${CMAKE_CURRENT_LIST_DIR}/.. ABSOLUTE)
```

这也是为什么 `ZEPHYR_SDK_INSTALL_DIR` 可以不设——只要 CMake 能通过注册表找到
Config 文件，它自己就把变量填好了。

SDK 二进制**没有 RPATH**，整体可重定位；但两处是绝对路径，换位置后必须重建：

- `hosttools/environment-setup-x86_64-pokysdk-linux`
- `~/.cmake/packages/Zephyr-sdk/` 里的注册项

换位置后重跑 `setup.sh -h -c` 即可（重跑前先 `rm -rf ~/.cmake/packages/Zephyr-sdk`）。

---

## 已知坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `setup.sh -h` 没装 help | `-h` 是装 host tools，`-?` 才是帮助 | 见上 |
| gdb 报 `libtinfo.so.6: no version information available` | Fedora 上 ncurses 的常见现象 | 无害，忽略 |
| conda 报 `pyocd requires cmsis-pack-manager` 冲突 | conda-forge 的 pyocd 停在 0.34.0，只支持 Python ≤3.10 | 走 pip 段，装 0.45.1 |
| `sudo` 报"需要密码"但没提示符 | 脚本在无 TTY 环境运行 | 在真终端里跑，别用管道/CI 环境 |
| `west flash` 找不到调试器 | 没接 ST-Link/OpenOCD，或没装 udev 规则 | 检查接线；按「二、③」装规则 |
| `west build` 报 `ZEPHYR_BASE` 未定义 | app 在 west 工作区外 | `export ZEPHYR_BASE="$ZR_WS/zephyr"` |
| 子模块目录是空的 | 克隆时没加 `--recurse-submodules` | `git submodule update --init --recursive` |
| 板子找不到 | `libzr_board` 没初始化，或 `BOARD_ROOT` 没设置 / 写成了相对路径 | `git submodule update --init --recursive`；确认 `CMakeLists.txt` 里 `BOARD_ROOT` 指向 `<libzr>/libzr_board` 绝对路径 |
| libzr 的驱动 / 配置不生效 | `ZEPHYR_EXTRA_MODULES` 没设置、用了相对路径，或写在了 `find_package(Zephyr)` 之后 | 按「三、在 app 里接入 libzr」设置；路径必须是绝对路径 |
| 32 位 `native_sim` 报 `gnu/stubs-32.h` 缺失 | 缺 32 位主机开发库 | 装 `glibc-devel.i686`，或改用 `-b native_sim/native/64` |

---

## 当前实现状态

| 文件 | 状态 |
| --- | --- |
| `scripts/install_zephyr/linux/install_zephyr.sh` | ✅ 已完成（`sh -n` + `--check-only` 验证通过） |
| `CMakeLists.txt` | 空，待写（Zephyr 模块入口） |
| `drv/`、`lib/`、`cmake/` | 目录已建，待加内容 |
| `scripts/install_zephyr/windows/install_zephyr.bat` | 空，待写 |
| `libzr_board/` | 子模块已就位，内容待加 |
