#!/bin/sh
# =============================================================================
# install_zephyr.sh —— libzr 的 Linux 开发环境安装脚本
#
# 依次完成：
#   1. 用发行版包管理器安装 Zephyr 所需的「非 Python」系统依赖
#   2. 用 conda 创建 / 更新 Python 环境（锁定 3.12）
#   3. 初始化或更新 west 工作区（Zephyr + 全部模块）
#   4. 检测 Zephyr SDK（只检测，不安装）
#   5. 检查 udev 规则（只提示，不代替你执行 sudo）
#
# 行为约定
#   * Python 相关（python/pip/venv）一律不装，全部交给 conda 环境。
#   * 每个依赖先检测、只装缺的（幂等，可反复执行）。
#   * Zephyr SDK 只检测不安装：太大、版本需要你自己选。
#   * 不覆盖已有工作区：$ZR_WS 里已有 .west/ 时，不加 --reuse-workspace 就不动它。
#   * 用普通用户身份运行，内部按需调用 sudo。**不要**整个脚本加 sudo，
#     否则 conda 环境和 west 工作区会变成 root 所有。
#
# 用法
#   ./install_zephyr.sh [选项]
#
# 选项
#   -n, --check-only       只检测，不做任何改动
#   -y, --yes              不询问，直接执行
#   -h, --help             显示本帮助
#       --no-conda         跳过 conda 环境的创建/更新
#       --install-conda    未检测到 conda 时自动安装 Miniconda
#       --reuse-workspace  工作区已存在时执行 west update（默认不动已有工作区）
#       --workspace DIR    等价于 ZR_WS
#       --sdk DIR          等价于 ZR_SDK
#       --mr REV           Zephyr 版本 / 分支 / tag，默认 v4.4.2
#       --env-file FILE    环境变量输出文件，默认 ~/.config/libzr/env.sh
#       --no-env           不写环境变量文件
#
# 环境变量
#   ZR_WS               west 工作区，默认 $HOME/zephyr_workplace/main
#   ZR_SDK              Zephyr SDK 解压目录，默认 /opt/zephyr-sdk-1.0.1_linux-x86_64_gnu
#   ZR_CONDA_ENV        conda 环境名，默认 zephyr
#   ZR_MR               Zephyr 版本，默认 v4.4.2
#   ZR_ZEPHYR_REMOTE    Zephyr 仓库地址，默认官方 GitHub
#   ZR_ENV_FILE         环境变量输出文件，默认 ~/.config/libzr/env.sh
#   ENV_FILE            conda 依赖文件；不设则由本脚本生成临时文件
#   MINICONDA_DIR       Miniconda 安装目录，默认 $HOME/miniconda3
#
# 支持的发行版族
#   debian  Debian / Ubuntu / Mint / Pop!_OS / Raspberry Pi OS
#   fedora  Fedora / RHEL / CentOS / Rocky / AlmaLinux
#   arch    Arch / Manjaro / EndeavourOS
#   suse    openSUSE / SLES
#   alpine  Alpine
# =============================================================================

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# libzr 根目录：从脚本自身位置推导，不写死、也不依赖环境变量。
# scripts/install_zephyr/linux → 上三级就是 libzr/
LIBZR_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)

ZR_WS="${ZR_WS:-$HOME/zephyr_workplace/main}"
ZR_SDK="${ZR_SDK:-/opt/zephyr-sdk-1.0.1_linux-x86_64_gnu}"
ZR_CONDA_ENV="${ZR_CONDA_ENV:-zephyr}"
ZR_MR="${ZR_MR:-v4.4.2}"
ZR_ZEPHYR_REMOTE="${ZR_ZEPHYR_REMOTE:-https://github.com/zephyrproject-rtos/zephyr}"
MINICONDA_DIR="${MINICONDA_DIR:-$HOME/miniconda3}"
ENV_FILE="${ENV_FILE:-}"

# 机器级路径写进这个文件，供所有 app 共享。
# 不放 ZR_LIBZR / ZR_BOARD：它们随 app 目录变化，必须相对推导，
# 否则同一个 app 仓库在不同人的机器上就没法合作开发了。
ZR_ENV_FILE="${ZR_ENV_FILE:-$HOME/.config/libzr/env.sh}"

ASSUME_YES=0
CHECK_ONLY=0
DO_CONDA=1
ALLOW_INSTALL_CONDA=0
REUSE_WORKSPACE=0
WRITE_ENV=1

# -----------------------------------------------------------------------------
# 日志
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
	C_RED=$(printf '\033[31m') ; C_GRN=$(printf '\033[32m')
	C_YEL=$(printf '\033[33m') ; C_CYA=$(printf '\033[36m')
	C_BLD=$(printf '\033[1m')  ; C_RST=$(printf '\033[0m')
else
	C_RED='' ; C_GRN='' ; C_YEL='' ; C_CYA='' ; C_BLD='' ; C_RST=''
fi

info()  { printf '%s[INFO]%s %s\n' "$C_CYA" "$C_RST" "$*" ; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*" ; }
skip()  { printf '%s[SKIP]%s %s\n' "$C_GRN" "$C_RST" "$*" ; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2 ; }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2 ; }
die()   { err "$*" ; exit 1 ; }
title() { printf '\n%s%s==> %s%s\n' "$C_BLD" "$C_CYA" "$*" "$C_RST" ; }

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
	exit 0
}

# -----------------------------------------------------------------------------
# 参数解析
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		-n|--check-only)     CHECK_ONLY=1 ;;
		-y|--yes)            ASSUME_YES=1 ;;
		-h|--help)           usage ;;
		--no-conda)          DO_CONDA=0 ;;
		--install-conda)     ALLOW_INSTALL_CONDA=1 ;;
		--reuse-workspace)   REUSE_WORKSPACE=1 ;;
		--workspace)         shift ; [ $# -gt 0 ] || die "--workspace 需要一个目录" ; ZR_WS=$1 ;;
		--sdk)               shift ; [ $# -gt 0 ] || die "--sdk 需要一个目录" ; ZR_SDK=$1 ;;
		--mr)                shift ; [ $# -gt 0 ] || die "--mr 需要一个版本号" ; ZR_MR=$1 ;;
		--env-file)          shift ; [ $# -gt 0 ] || die "--env-file 需要一个路径" ; ZR_ENV_FILE=$1 ;;
		--no-env)            WRITE_ENV=0 ;;
		*)                   die "未知参数: $1（用 --help 查看用法）" ;;
	esac
	shift
done

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	[ -t 0 ] || return 0
	printf '%s%s [y/N]%s ' "$C_BLD" "$1" "$C_RST"
	read -r _ans || return 1
	case "$_ans" in
		[yY]|[yY][eE][sS]) return 0 ;;
		*) return 1 ;;
	esac
}

# -----------------------------------------------------------------------------
# 发行版 / 包管理器探测
# -----------------------------------------------------------------------------
FAMILY=unknown
PM=''
SUDO=''
SUDO_OK=0
ARCH=$(uname -m)

detect_family() {
	_d_id='' ; _d_like=''
	if [ -r /etc/os-release ]; then
		_d_id=$(   . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" )
		_d_like=$( . /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}" )
	fi
	_keys=" $_d_id $_d_like "

	case "$_keys" in
		*" debian "*|*" ubuntu "*|*" linuxmint "*|*" raspbian "*|*" pop "*) FAMILY=debian ;;
		*" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*)   FAMILY=fedora ;;
		*" arch "*|*" manjaro "*|*" endeavouros "*)                         FAMILY=arch ;;
		*" opensuse "*|*" suse "*|*" sles "*)                               FAMILY=suse ;;
		*" alpine "*)                                                       FAMILY=alpine ;;
		*)
			if   command -v apt-get >/dev/null 2>&1 ; then FAMILY=debian
			elif command -v dnf     >/dev/null 2>&1 ; then FAMILY=fedora
			elif command -v pacman  >/dev/null 2>&1 ; then FAMILY=arch
			elif command -v zypper  >/dev/null 2>&1 ; then FAMILY=suse
			elif command -v apk     >/dev/null 2>&1 ; then FAMILY=alpine
			fi
			;;
	esac
}

detect_pm() {
	case "$FAMILY" in
		debian) PM=apt-get ;;
		fedora) PM=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum) ;;
		arch)   PM=pacman ;;
		suse)   PM=zypper ;;
		alpine) PM=apk ;;
		*)      PM='' ;;
	esac
}

detect_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		SUDO='' ; SUDO_OK=1
	elif command -v sudo >/dev/null 2>&1; then
		SUDO='sudo' ; SUDO_OK=1
	elif command -v doas >/dev/null 2>&1; then
		SUDO='doas' ; SUDO_OK=1
	else
		SUDO='' ; SUDO_OK=0
	fi
}

pm_refresh() {
	[ "$CHECK_ONLY" -eq 1 ] && return 0
	info "刷新 $PM 软件源索引"
	case "$FAMILY" in
		debian) $SUDO apt-get update ;;
		fedora) : ;;
		arch)   $SUDO pacman -Sy --noconfirm ;;
		suse)   $SUDO zypper --non-interactive --gpg-auto-import-keys refresh ;;
		alpine) $SUDO apk update ;;
	esac
}

pm_install() {
	[ $# -gt 0 ] || return 0
	case "$FAMILY" in
		debian) $SUDO apt-get install -y --no-install-recommends "$@" ;;
		fedora) $SUDO "$PM" install -y "$@" ;;
		arch)   $SUDO pacman -S --needed --noconfirm "$@" ;;
		suse)   $SUDO zypper --non-interactive install --no-recommends "$@" ;;
		alpine) $SUDO apk add --no-cache "$@" ;;
		*)      return 1 ;;
	esac
}

is_pkg_installed() {
	case "$FAMILY" in
		debian) dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
		fedora) rpm -q "$1" >/dev/null 2>&1 ;;
		arch)   pacman -Q "$1" >/dev/null 2>&1 ;;
		suse)   rpm -q "$1" >/dev/null 2>&1 ;;
		alpine) apk info -e "$1" >/dev/null 2>&1 ;;
		*)      return 1 ;;
	esac
}

dep_present() {
	if [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	is_pkg_installed "$2"
}

dedupe() {
	[ $# -gt 0 ] || return 0
	printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# -----------------------------------------------------------------------------
# 依赖清单
#   每行：检查命令|包名|说明|级别（req 必需 / opt 可选）
# -----------------------------------------------------------------------------
deps_for() {
	case "$1" in
	debian)
		cat <<'EOD'
git|git|Git 版本控制|req
cmake|cmake|CMake 构建系统|req
ninja|ninja-build|Ninja 构建工具|req
gperf|gperf|gperf 关键字表生成|req
make|make|GNU make|req
gcc|gcc|主机端 C 编译器|req
g++|g++|主机端 C++ 编译器|req
dtc|device-tree-compiler|设备树编译器 DTC|req
dfu-util|dfu-util|DFU 烧录工具|req
wget|wget|下载工具（装 SDK 用）|req
xz|xz-utils|xz 解压（装 SDK 用）|req
file|file|文件类型检测（装 SDK 用）|req
gawk|gawk|awk（SDK 安装脚本依赖）|req
ccache|ccache|编译缓存，加速重复构建|opt
pkg-config|pkg-config|pkg-config|opt
libusb||libusb-1.0-0-dev|libusb（OpenOCD/ST-Link 调试）|opt
sdl2||libsdl2-dev|SDL2 开发库（native_sim 显示）|opt
magic||libmagic1|libmagic（west 文件识别）|opt
EOD
		case "$2" in
		x86_64|i?86)
			cat <<'EOD'
multilib||gcc-multilib|32 位多库支持|opt
multilib-cxx||g++-multilib|32 位 C++ 多库支持|opt
libc6-i386||libc6-dev-i386|i386 libc 开发文件|opt
EOD
			;;
		esac
		;;
	fedora)
		cat <<'EOD'
git|git|Git 版本控制|req
cmake|cmake|CMake 构建系统|req
ninja|ninja-build|Ninja 构建工具|req
gperf|gperf|gperf 关键字表生成|req
make|make|GNU make|req
gcc|gcc|主机端 C 编译器|req
g++|gcc-c++|主机端 C++ 编译器|req
dtc|dtc|设备树编译器 DTC|req
dfu-util|dfu-util|DFU 烧录工具|req
wget|wget|下载工具（装 SDK 用）|req
xz|xz|xz 解压（装 SDK 用）|req
file|file|文件类型检测（装 SDK 用）|req
gawk|gawk|awk（SDK 安装脚本依赖）|req
ccache|ccache|编译缓存，加速重复构建|opt
pkg-config|pkgconf-pkg-config|pkg-config|opt
libusb||libusb1-devel|libusb（OpenOCD/ST-Link 调试）|opt
sdl2||SDL2-devel|SDL2 开发库（native_sim 显示）|opt
magic||file-libs|libmagic（west 文件识别）|opt
EOD
		case "$2" in
		x86_64|i?86)
			cat <<'EOD'
multilib||glibc-devel.i686|32 位 glibc（裸 native_sim 需要）|opt
multilib-cxx||libstdc++-devel.i686|32 位 libstdc++|opt
EOD
			;;
		esac
		;;
	arch)
		cat <<'EOD'
git|git|Git 版本控制|req
cmake|cmake|CMake 构建系统|req
ninja|ninja|Ninja 构建工具|req
gperf|gperf|gperf 关键字表生成|req
make|make|GNU make|req
gcc|gcc|主机端 C/C++ 编译器（gcc 包含 g++）|req
g++|gcc|主机端 C++ 编译器|req
dtc|dtc|设备树编译器 DTC|req
dfu-util|dfu-util|DFU 烧录工具|req
wget|wget|下载工具（装 SDK 用）|req
xz|xz|xz 解压（装 SDK 用）|req
file|file|文件类型检测 + libmagic|req
gawk|gawk|awk（SDK 安装脚本依赖）|req
ccache|ccache|编译缓存，加速重复构建|opt
pkg-config|pkgconf|pkg-config|opt
libusb||libusb|libusb（OpenOCD/ST-Link 调试）|opt
sdl2||sdl2|SDL2 开发库（native_sim 显示）|opt
EOD
		case "$2" in
		x86_64|i?86)
			cat <<'EOD'
multilib||lib32-glibc|32 位 glibc（需启用 multilib 源）|opt
multilib-cxx||lib32-gcc-libs|32 位 C++ 运行库|opt
EOD
			;;
		esac
		;;
	suse)
		cat <<'EOD'
git|git|Git 版本控制|req
cmake|cmake|CMake 构建系统|req
ninja|ninja|Ninja 构建工具|req
gperf|gperf|gperf 关键字表生成|req
make|make|GNU make|req
gcc|gcc|主机端 C 编译器|req
g++|gcc-c++|主机端 C++ 编译器|req
dtc|dtc|设备树编译器 DTC|req
dfu-util|dfu-util|DFU 烧录工具|req
wget|wget|下载工具（装 SDK 用）|req
xz|xz|xz 解压（装 SDK 用）|req
file|file|文件类型检测（装 SDK 用）|req
gawk|gawk|awk（SDK 安装脚本依赖）|req
ccache|ccache|编译缓存，加速重复构建|opt
pkg-config|pkgconf-pkg-config|pkg-config|opt
libusb||libusb-1_0-devel|libusb（OpenOCD/ST-Link 调试）|opt
sdl2||libSDL2-devel|SDL2 开发库（native_sim 显示）|opt
magic||file-magic|libmagic（west 文件识别）|opt
EOD
		;;
	alpine)
		cat <<'EOD'
git|git|Git 版本控制|req
cmake|cmake|CMake 构建系统|req
ninja|ninja|Ninja 构建工具|req
gperf|gperf|gperf 关键字表生成|req
make|build-base|make（build-base 元包）|req
gcc|build-base|主机端 C 编译器|req
g++|build-base|主机端 C++ 编译器|req
dtc|dtc|设备树编译器 DTC|req
dfu-util|dfu-util|DFU 烧录工具|req
wget|wget|下载工具（装 SDK 用）|req
xz|xz|xz 解压（装 SDK 用）|req
file|file|文件类型检测 + libmagic|req
gawk|gawk|awk（SDK 安装脚本依赖）|req
ccache|ccache|编译缓存，加速重复构建|opt
pkg-config|pkgconf|pkg-config|opt
libusb||libusb-dev|libusb（OpenOCD/ST-Link 调试）|opt
sdl2||sdl2-dev|SDL2 开发库（native_sim 显示）|opt
EOD
		;;
	esac
}

# -----------------------------------------------------------------------------
# Zephyr SDK 检测（只检测，不安装）
# -----------------------------------------------------------------------------
find_sdk() {
	if [ -n "${ZR_SDK:-}" ] && [ -d "$ZR_SDK" ]; then
		printf '%s' "$ZR_SDK" ; return 0
	fi
	if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && [ -d "${ZEPHYR_SDK_INSTALL_DIR}" ]; then
		printf '%s' "${ZEPHYR_SDK_INSTALL_DIR}" ; return 0
	fi
	for _d in "$HOME"/zephyr-sdk-* /opt/zephyr-sdk /opt/zephyr-sdk-* \
	          /usr/local/zephyr-sdk* "$HOME"/.local/zephyr-sdk-*; do
		if [ -d "$_d" ]; then
			printf '%s' "$_d" ; return 0
		fi
	done
	return 1
}

check_sdk() {
	title "检查 Zephyr SDK（只检测，不安装）"

	if _sdk=$(find_sdk); then
		_ver=''
		[ -f "$_sdk/sdk_version" ] && _ver=$(cat "$_sdk/sdk_version" 2>/dev/null || true)
		if [ -n "$_ver" ]; then
			ok "已找到 Zephyr SDK: $_sdk (版本 $_ver)"
		else
			ok "已找到 Zephyr SDK: $_sdk"
		fi
		SDK_PATH="$_sdk"
		if [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
			warn "ZEPHYR_SDK_INSTALL_DIR 未设置，构建时建议加上："
			warn "    export ZEPHYR_SDK_INSTALL_DIR=\"$_sdk\""
		fi
		return 0
	fi

	warn "未检测到 Zephyr SDK —— 交叉编译器（arm-zephyr-eabi-gcc）的来源，"
	warn "缺它无法编译目标板。本脚本按约定不自动安装，请手动执行其一："
	warn "  1) 手动下载：https://github.com/zephyrproject-rtos/sdk-ng/releases/latest"
	warn "     解压到 $ZR_SDK 后执行：cd \"$ZR_SDK\" && ./setup.sh -h -c"
	warn "     （注意：-h 是装 host tools，不是 help；-c 注册 CMake 包）"
	warn "  2) 或运行 west sdk install（需要 west 环境已就绪）"
	warn "然后设置：export ZR_SDK=\"<SDK 目录>\""
	SDK_MISSING=1
	return 1
}

# -----------------------------------------------------------------------------
# conda 环境
# -----------------------------------------------------------------------------
find_conda() {
	if [ -n "${CONDA_EXE:-}" ] && [ -x "${CONDA_EXE}" ]; then
		printf '%s' "${CONDA_EXE}" ; return 0
	fi
	if command -v conda >/dev/null 2>&1; then
		command -v conda ; return 0
	fi
	if command -v micromamba >/dev/null 2>&1; then
		command -v micromamba ; return 0
	fi
	for _c in \
		"$HOME/miniconda3/bin/conda" \
		"$HOME/anaconda3/bin/conda" \
		"$HOME/miniforge3/bin/conda" \
		"$HOME/mambaforge/bin/conda" \
		"$HOME/.local/share/mamba/bin/micromamba" \
		/opt/conda/bin/conda \
		/opt/miniconda3/bin/conda
	do
		if [ -x "$_c" ]; then printf '%s' "$_c" ; return 0 ; fi
	done
	return 1
}

install_miniconda() {
	info "下载并安装 Miniconda 到 $MINICONDA_DIR"
	case "$ARCH" in
		x86_64)        _arch=x86_64 ;;
		aarch64|arm64) _arch=aarch64 ;;
		*) die "Miniconda 官方未提供 $ARCH 的安装包，请手动装 conda/mamba。" ;;
	esac
	_url="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${_arch}.sh"
	_tmp=$(mktemp) || die "无法创建临时文件"
	trap 'rm -f "$_tmp"' EXIT INT TERM
	wget -q -O "$_tmp" "$_url" || die "下载 Miniconda 失败: $_url"
	sh "$_tmp" -b -p "$MINICONDA_DIR" || die "Miniconda 安装失败"
	rm -f "$_tmp"
	trap - EXIT INT TERM
	ok "Miniconda 已安装到 $MINICONDA_DIR"
}

# ENV_FILE 未指定时，生成内置的 conda 依赖文件
write_env_yaml() {
	cat <<EOF
# 由 install_zephyr.sh 自动生成；可用 ENV_FILE 提供自己的版本覆盖
name: $ZR_CONDA_ENV
channels:
  - conda-forge

dependencies:
  # 必须锁 3.12：Zephyr SDK 的 gdb-py 链接系统 Python 3.12，
  # west debug 会通过 PYTHONPATH 把本环境的 site-packages 交给它，
  # 两边 ABI 必须一致。
  - python=3.12
  - pip>=23.0
  - setuptools
  - wheel

  # Zephyr requirements-base
  - cbor2
  - colorama
  - gitpython>=3.1.37
  - jsonschema>=4.0.0
  - packaging
  - psutil
  - pyelftools
  - pykwalify
  - pyyaml>=5.4.0

  # 构建 / 测试
  - anytree
  - pytest>=7.0.0
  - pytest-subtests

  # 运行 / 调试
  - pyserial

  # 常用增强
  - requests
  - pygithub
  - pylint
  - numpy
  - tqdm
  - rich
  - sh

  - pip:
      - west>=1.2.0
      - esptool>=5.0.2
      - junitparser
      - junit2html
      - canopen
      # pyocd 不能放 conda 段：conda-forge 版本依赖 cmsis-pack-manager，
      # 只支持 Python <= 3.10，与 python=3.12 冲突。
      - pyocd
      - protobuf
      - grpcio-tools
EOF
}

conda_env_prefix() {
	_base=$("$CONDA_BIN" info --base 2>/dev/null || true)
	if [ -n "$_base" ] && [ -d "$_base/envs/$ZR_CONDA_ENV" ]; then
		printf '%s' "$_base/envs/$ZR_CONDA_ENV" ; return 0
	fi
	"$CONDA_BIN" env list 2>/dev/null | awk -v n="$ZR_CONDA_ENV" '
		{ name=$1; sub(/\*$/, "", name); if (name==n) { print $NF; exit } }'
}

setup_conda_env() {
	title "创建 / 更新 conda Python 环境（$ZR_CONDA_ENV）"

	if [ -z "$ENV_FILE" ]; then
		ENV_FILE=$(mktemp) || die "无法创建临时文件"
		trap 'rm -f "$ENV_FILE"' EXIT INT TERM
		write_env_yaml > "$ENV_FILE"
		info "已生成内置 conda 依赖文件（临时）"
	fi

	if [ ! -f "$ENV_FILE" ]; then
		err "找不到 conda 依赖文件: $ENV_FILE"
		return 1
	fi

	if ! CONDA_BIN=$(find_conda); then
		if [ "$ALLOW_INSTALL_CONDA" -eq 1 ]; then
			install_miniconda
			CONDA_BIN="$MINICONDA_DIR/bin/conda"
		else
			warn "未检测到 conda / micromamba，跳过 Python 环境创建。"
			warn "可重跑并加 --install-conda，或自行安装 Miniconda/Miniforge。"
			CONDA_MISSING=1
			return 1
		fi
	fi

	info "使用 conda: $CONDA_BIN"

	if "$CONDA_BIN" env list 2>/dev/null | awk '{print $1}' | grep -qx "$ZR_CONDA_ENV"; then
		info "环境 $ZR_CONDA_ENV 已存在，执行更新（--prune 清理多余包）"
		if ! "$CONDA_BIN" env update -n "$ZR_CONDA_ENV" -f "$ENV_FILE" --prune; then
			err "conda 环境更新失败，请看上方求解器报错"
			CONDA_FAILED=1
			return 1
		fi
	else
		info "创建环境 $ZR_CONDA_ENV"
		if ! "$CONDA_BIN" env create -n "$ZR_CONDA_ENV" -f "$ENV_FILE"; then
			err "conda 环境创建失败，请看上方求解器报错"
			CONDA_FAILED=1
			return 1
		fi
	fi

	ENV_PREFIX=$(conda_env_prefix)
	[ -n "$ENV_PREFIX" ] || { err "无法定位 conda 环境目录"; CONDA_FAILED=1; return 1; }

	ok "conda 环境就绪：$ENV_PREFIX"
	CONDA_CREATED=1
}

# -----------------------------------------------------------------------------
# west 工作区
# -----------------------------------------------------------------------------
find_west() {
	if [ -n "${ENV_PREFIX:-}" ] && [ -x "$ENV_PREFIX/bin/west" ]; then
		printf '%s' "$ENV_PREFIX/bin/west" ; return 0
	fi
	if command -v west >/dev/null 2>&1; then
		command -v west ; return 0
	fi
	return 1
}

setup_west_workspace() {
	title "初始化 west 工作区（$ZR_WS，Zephyr $ZR_MR）"

	if ! WEST_BIN=$(find_west); then
		err "找不到 west。请先建好 conda 环境，或把 west 加入 PATH。"
		WEST_FAILED=1
		return 1
	fi
	info "使用 west: $WEST_BIN"

	_old_path="$PATH"
	if [ -n "${ENV_PREFIX:-}" ]; then
		PATH="$ENV_PREFIX/bin:$PATH"
	fi

	if [ -d "$ZR_WS/.west" ]; then
		if [ "$REUSE_WORKSPACE" -eq 0 ]; then
			warn "工作区已存在且未被改动：$ZR_WS"
			warn "  如需更新，重跑并加 --reuse-workspace"
			WEST_SKIPPED=1
			PATH="$_old_path"
			return 0
		fi
		info "复用已有工作区，执行 west update"
		if ! ( cd "$ZR_WS" && "$WEST_BIN" update ); then
			err "west update 失败（可中断后重跑，它是幂等的）"
			WEST_FAILED=1
			PATH="$_old_path"
			return 1
		fi
	else
		if [ -d "$ZR_WS" ] && [ -n "$(ls -A "$ZR_WS" 2>/dev/null || true)" ]; then
			err "$ZR_WS 已存在、非空，但不是 west 工作区"
			err "请换一个 ZR_WS，或手动清空该目录后重试"
			WEST_FAILED=1
			PATH="$_old_path"
			return 1
		fi

		mkdir -p "$(dirname "$ZR_WS")"
		info "west init -m $ZR_ZEPHYR_REMOTE --mr $ZR_MR $ZR_WS"
		if ! "$WEST_BIN" init -m "$ZR_ZEPHYR_REMOTE" --mr "$ZR_MR" "$ZR_WS"; then
			err "west init 失败"
			WEST_FAILED=1
			PATH="$_old_path"
			return 1
		fi

		info "west update（约 8 GB，可中断后重跑）"
		if ! ( cd "$ZR_WS" && "$WEST_BIN" update ); then
			err "west update 失败（可中断后重跑，它是幂等的）"
			WEST_FAILED=1
			PATH="$_old_path"
			return 1
		fi
	fi

	info "补齐 Zephyr 自带的 Python 依赖（west packages pip --install）"
	if ! ( cd "$ZR_WS" && "$WEST_BIN" packages pip --install ); then
		warn "west packages pip --install 失败；后续可手动重跑"
	fi

	PATH="$_old_path"
	ok "west 工作区就绪：$ZR_WS"
	WEST_READY=1
}

check_west_workspace_only() {
	title "检查 west 工作区"
	if [ -n "$ZR_WS" ] && [ -d "$ZR_WS/.west" ]; then
		ok "工作区已存在：$ZR_WS"
		if [ -d "$ZR_WS/zephyr" ]; then ok "找到 zephyr 目录"; else warn "缺少 $ZR_WS/zephyr"; fi
	else
		warn "工作区尚未初始化：$ZR_WS"
	fi
	if WEST_BIN=$(find_west 2>/dev/null); then
		ok "找到 west：$WEST_BIN"
	else
		warn "未找到 west（conda 环境尚未创建或未装 west）"
	fi
}

# -----------------------------------------------------------------------------
# udev 规则（只检查 + 提示，不代替用户执行 sudo）
# -----------------------------------------------------------------------------
check_udev() {
	title "检查 udev 规则（ST-Link / OpenOCD）"
	if [ -f /etc/udev/rules.d/60-openocd.rules ] || \
	   [ -f /etc/udev/rules.d/99-openocd.rules ] || \
	   [ -f /etc/udev/rules.d/99-stlink.rules ]; then
		ok "已安装 udev 规则"
		return 0
	fi
	warn "未安装 udev 规则：烧录/调试会要求 sudo。"
	if [ -n "${SDK_PATH:-}" ]; then
		_rules="$SDK_PATH/hosttools/sysroots/x86_64-pokysdk-linux/usr/share/openocd/contrib/60-openocd.rules"
		if [ -f "$_rules" ]; then
			warn "规则文件在 SDK 内：$_rules"
			warn "手动执行（需要 sudo）："
			warn "    sudo cp \"$_rules\" /etc/udev/rules.d/"
			warn "    sudo udevadm control --reload-rules && sudo udevadm trigger"
		else
			warn "SDK 内未找到 60-openocd.rules，请确认装过 host tools（setup.sh -h）"
		fi
	else
		warn "安装 SDK 后再处理：规则在 <SDK>/hosttools/.../openocd/contrib/60-openocd.rules"
	fi
}

# -----------------------------------------------------------------------------
# 环境变量文件
#
# 只写「机器级」路径：工作区 / SDK / conda 环境。
# 不写 ZR_LIBZR / ZR_BOARD —— 它们随 app 目录变化，必须由 app 侧相对推导。
# 这样同一个 app 仓库换到别人的机器上，不需要改任何配置文件。
# -----------------------------------------------------------------------------
write_env_file() {
	if [ "$WRITE_ENV" -eq 0 ]; then
		info "按 --no-env 跳过环境变量文件"
		return 0
	fi

	title "写入环境变量文件（$ZR_ENV_FILE）"

	_dir=$(dirname "$ZR_ENV_FILE")
	if ! mkdir -p "$_dir"; then
		warn "无法创建目录: $_dir"
		return 1
	fi

	_sdk_out="${SDK_PATH:-$ZR_SDK}"

	cat > "$ZR_ENV_FILE" <<EOF
# 由 libzr/scripts/install_zephyr/linux/install_zephyr.sh 生成
# 用法：source "$ZR_ENV_FILE"
#
# 这里只放「机器级」路径。libzr / libzr_board 的路径随 app 目录变化，
# 由 app 的 CMakeLists 相对推导，因此不写在这里。
# 这样同一个 app 仓库换到别人的机器上，不需要改任何配置。
export ZR_WS="$ZR_WS"
export ZR_SDK="$_sdk_out"
export ZR_CONDA_ENV="$ZR_CONDA_ENV"
export ZR_MR="$ZR_MR"
export ZEPHYR_SDK_INSTALL_DIR="$_sdk_out"
export ZEPHYR_BASE="$ZR_WS/zephyr"
EOF

	ok "已写入 $ZR_ENV_FILE"
	info "在当前 shell 生效： source \"$ZR_ENV_FILE\""
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
detect_family
detect_pm
detect_sudo

title "环境概览"
info "发行版族   : $FAMILY"
info "包管理器   : ${PM:-未知}"
info "CPU 架构   : $ARCH"
info "west 工作区: $ZR_WS"
info "Zephyr 版本: $ZR_MR"
info "SDK 目录   : $ZR_SDK"
info "conda 环境 : $ZR_CONDA_ENV"
[ "$CHECK_ONLY" -eq 1 ] && warn "当前为 --check-only 模式，不会做任何改动"

if [ -z "$PM" ]; then
	warn "无法识别包管理器，系统依赖需要你手动安装。"
	warn "参考 https://docs.zephyrproject.org/latest/develop/getting_started/index.html"
fi

# ---- 系统依赖 --------------------------------------------------------------
title "检测系统依赖（Python 相关一律跳过，交给 conda）"

MISSING_REQ=''
MISSING_OPT=''
HAVE_CNT=0
HARD_FAIL=0

while IFS='|' read -r _check _pkg _desc _level; do
	[ -n "${_pkg:-}" ] || continue
	if dep_present "$_check" "$_pkg"; then
		HAVE_CNT=$((HAVE_CNT + 1))
		skip "$_desc  [$_pkg]"
	else
		if [ "$_level" = opt ]; then
			warn "可选缺失: $_desc  [$_pkg]"
			MISSING_OPT="$MISSING_OPT $_pkg"
		else
			warn "必需缺失: $_desc  [$_pkg]"
			MISSING_REQ="$MISSING_REQ $_pkg"
		fi
	fi
done <<EOD
$(deps_for "$FAMILY" "$ARCH")
EOD

MISSING_REQ=$(dedupe $MISSING_REQ)
MISSING_OPT=$(dedupe $MISSING_OPT)

info "已满足 $HAVE_CNT 项；缺少必需 ${MISSING_REQ:-无}；缺少可选 ${MISSING_OPT:-无}"

if [ "$CHECK_ONLY" -eq 0 ] && [ -n "$MISSING_REQ$MISSING_OPT" ] && [ -n "$PM" ]; then
	title "安装缺失依赖"

	if [ "$SUDO_OK" -eq 0 ]; then
		die "需要 root 权限安装系统包，但 sudo/doas 都不可用。请以 root 运行，或手动安装。"
	fi

	if confirm "即将用 $PM 安装上述缺失依赖，继续？"; then
		pm_refresh

		if [ -n "$MISSING_REQ" ]; then
			info "安装必需依赖:$MISSING_REQ"
			if ! pm_install $MISSING_REQ; then
				warn "批量安装失败，改为逐个安装以定位具体是哪个包"
				_failed=''
				for _p in $MISSING_REQ; do
					pm_install "$_p" || _failed="$_failed $_p"
				done
				[ -z "$_failed" ] || err "以下必需依赖安装失败:$_failed"
			fi
		fi

		if [ -n "$MISSING_OPT" ]; then
			info "安装可选依赖:$MISSING_OPT"
			for _p in $MISSING_OPT; do
				pm_install "$_p" || warn "可选依赖 $_p 安装失败，跳过（不影响基本构建）"
			done
		fi

		_still=''
		while IFS='|' read -r _c _p _d _l; do
			[ "$_l" = req ] || continue
			dep_present "$_c" "$_p" || _still="$_still $_p"
		done <<EOD
$(deps_for "$FAMILY" "$ARCH")
EOD
		if [ -n "$_still" ]; then
			err "以下必需依赖仍不可用:$_still"
			err "请确认这些包名在你发行版上的叫法，或检查软件源。"
			HARD_FAIL=1
		else
			ok "所有必需依赖均已就绪"
		fi
	fi
elif [ "$CHECK_ONLY" -eq 1 ]; then
	info "（--check-only）跳过安装"
fi

# ---- SDK -------------------------------------------------------------------
SDK_MISSING=0
SDK_PATH=''
check_sdk || true

# ---- conda -----------------------------------------------------------------
CONDA_MISSING=0
CONDA_CREATED=0
CONDA_FAILED=0
ENV_PREFIX=''

if [ "$DO_CONDA" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
	setup_conda_env || true
elif [ "$CHECK_ONLY" -eq 1 ]; then
	title "检查 conda"
	if CONDA_BIN=$(find_conda); then
		ok "已找到 conda: $CONDA_BIN"
		# 顺便定位环境目录，下面 find_west 才能去环境里找
		ENV_PREFIX=$(conda_env_prefix)
		if [ -n "$ENV_PREFIX" ]; then
			ok "conda 环境 $ZR_CONDA_ENV: $ENV_PREFIX"
		else
			warn "conda 环境 $ZR_CONDA_ENV 尚未创建"
		fi
	else
		warn "未检测到 conda / micromamba"
	fi
fi

# ---- west 工作区 -----------------------------------------------------------
WEST_FAILED=0
WEST_SKIPPED=0
WEST_READY=0

if [ "$CHECK_ONLY" -eq 1 ]; then
	check_west_workspace_only
elif [ "$DO_CONDA" -eq 1 ] && [ "$CONDA_FAILED" -eq 1 ]; then
	warn "conda 环境未就绪，跳过 west 工作区"
elif [ "$DO_CONDA" -eq 1 ] && [ "$CONDA_MISSING" -eq 1 ]; then
	warn "未找到 conda，跳过 west 工作区；请先装好 Python 环境"
else
	setup_west_workspace || true
fi

# ---- udev ------------------------------------------------------------------
check_udev

# ---- 环境变量 --------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 0 ]; then
	write_env_file || warn "环境变量文件写入失败，可手动 export 上述变量"
fi

# ---- 收尾 ------------------------------------------------------------------
title "完成情况"

if [ "$SDK_MISSING" -eq 1 ]; then
	warn "Zephyr SDK        : 未安装（需要你手动处理，见上方提示）"
elif [ -n "$SDK_PATH" ]; then
	ok "Zephyr SDK        : $SDK_PATH"
else
	ok "Zephyr SDK        : 已就绪"
fi

if [ "$DO_CONDA" -eq 0 ]; then
	info "conda 环境        : 按 --no-conda 要求跳过"
elif [ "$CONDA_CREATED" -eq 1 ]; then
	ok "conda 环境        : $ENV_PREFIX"
elif [ "$CONDA_FAILED" -eq 1 ]; then
	err "conda 环境        : 创建失败（见上方求解器输出）"
	HARD_FAIL=1
elif [ "$CONDA_MISSING" -eq 1 ]; then
	warn "conda 环境        : 未创建（未找到 conda）"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
	info "west 工作区       : 仅检查（--check-only）"
elif [ "$WEST_SKIPPED" -eq 1 ]; then
	warn "west 工作区       : 已存在，未改动（加 --reuse-workspace 才会 update）"
elif [ "$WEST_READY" -eq 1 ]; then
	ok "west 工作区       : $ZR_WS"
elif [ "$WEST_FAILED" -eq 1 ]; then
	err "west 工作区       : 初始化/更新失败"
	HARD_FAIL=1
fi

cat <<EOF

${C_BLD}后续步骤${C_RST}
  1. 载入机器级路径（工作区 / SDK / conda）：
       source "$ZR_ENV_FILE"
       conda activate $ZR_CONDA_ENV
  2. 在 app 的 CMakeLists.txt 里接入 libzr（必须写在 find_package(Zephyr) 之前）：
       set(LIBZR_DIR "\${CMAKE_CURRENT_SOURCE_DIR}/libzr")
       list(APPEND ZEPHYR_EXTRA_MODULES "\${LIBZR_DIR}")
       list(APPEND BOARD_ROOT          "\${LIBZR_DIR}/libzr_board")
     两处路径都相对 app 自身推导，不含机器信息，可以直接提交。
  3. 构建：
       cd "$ZR_WS" && west build -b <板子> -d build <你的 app 路径>

  合作开发提醒：app 仓库里不要提交任何绝对路径。别人 clone 后只要
  跑一次本脚本、source "$ZR_ENV_FILE"，就能直接构建同一个 app。

  提示：本脚本不会用 sudo 跑 conda / west。如果你之前用 sudo 跑过本脚本，
        请检查 \$HOME/.conda 和 \$ZR_WS 是否变成了 root 所有，必要时修正属主。
EOF

[ "$HARD_FAIL" -eq 0 ] || exit 1
exit 0
