#!/usr/bin/env bash
#
# gpuBench - Linux server benchmark
#
# Unified from LemonBench and LeGeekbench.
# The merged script keeps system information, FIO disk tests, and Geekbench
# CPU tests. Network performance and content checks are intentionally omitted.
# Network access is used only for Geekbench download and optional result upload.

set -Eeuo pipefail

SCRIPT_NAME="gpuBench"
SCRIPT_VERSION="1.0.0"

GB5_VERSION="5.5.1"
GB6_VERSION="6.7.1"
GB7_VERSION="7.0.0"
GB_CDN_BASE="https://cdn.geekbench.com"

PRESET="fast"
DISK_RUNTIME=10
DISK_SIZE_4K="50m"
DISK_SIZE_128K="100m"
RUN_DISK=1
RUN_GEEKBENCH=1
UPLOAD_RESULTS=1
AUTO_SWAP=0
GEEKBENCH_SELECTION="6"
WORK_BASE=""
REPORT_FILE=""
RUNTIME_DIR=""
FIO_FILE=""
TEMP_SWAP_FILE=""
TEMP_SWAP_ACTIVE=0
GB_ARCH=""

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

usage() {
    cat <<'USAGE'
gpuBench - Linux 服务器性能基准测试工具

用法:
  gpuBench.sh [选项]

预置:
  -f, --fast                 快速磁盘测试（默认，4 个测试各 10 秒）
  -F, --full                 完整磁盘测试（4 个测试各 60 秒）

CPU 测试:
  -g, --geekbench VERSION    运行 Geekbench 5、6、7、all 或 none（默认 6）
      --no-geekbench         跳过 Geekbench
      --no-upload             不上传 Geekbench 结果

磁盘测试:
      --no-disk              跳过 FIO 磁盘测试

其他:
      --auto-swap            Geekbench 内存不足时创建临时 Swap
      --workdir DIR           指定临时工作目录
      --report FILE           指定本地报告文件
  -h, --help                 显示帮助

示例:
  bash gpuBench.sh --fast
  bash gpuBench.sh --full --geekbench 7
  bash gpuBench.sh --geekbench all --no-upload
  bash gpuBench.sh --no-disk --geekbench none
USAGE
}

info() {
    printf '%b[INFO]%b %s\n' "${CYAN}" "${RESET}" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

error() {
    printf '%b[ERROR]%b %s\n' "${RED}" "${RESET}" "$*" >&2
}

success() {
    printf '%b[OK]%b %s\n' "${GREEN}" "${RESET}" "$*"
}

die() {
    error "$*"
    exit 1
}

section() {
    local title="$1"
    printf '\n===== %s =====\n' "$title" | tee -a "$REPORT_FILE"
}

report_line() {
    printf '%s\n' "$*" | tee -a "$REPORT_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

root_run() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        return 127
    fi
}

package_manager() {
    if command_exists apt-get; then
        printf '%s\n' apt-get
    elif command_exists dnf; then
        printf '%s\n' dnf
    elif command_exists yum; then
        printf '%s\n' yum
    else
        return 1
    fi
}

install_package() {
    local package="$1"
    local manager
    manager="$(package_manager 2>/dev/null || true)"
    [ -n "${manager}" ] || return 1

    case "${manager}" in
        apt-get) root_run apt-get install -y --no-install-recommends "${package}" ;;
        dnf) root_run dnf install -y "${package}" ;;
        yum) root_run yum install -y "${package}" ;;
    esac
}

ensure_command() {
    local command="$1"
    local package="${2:-$1}"

    if command_exists "${command}"; then
        return 0
    fi

    warn "缺少依赖 ${command}，尝试安装 ${package}"
    if ! install_package "${package}"; then
        die "无法安装 ${package}，请先手动安装后重试"
    fi
    command_exists "${command}" || die "安装后仍找不到 ${command}"
}

parse_selection() {
    case "${GEEKBENCH_SELECTION}" in
        none|off|0) RUN_GEEKBENCH=0 ;;
        5|gb5|GB5) GEEKBENCH_VERSIONS=(5) ;;
        6|gb6|GB6) GEEKBENCH_VERSIONS=(6) ;;
        7|gb7|GB7) GEEKBENCH_VERSIONS=(7) ;;
        both|56|65) GEEKBENCH_VERSIONS=(5 6) ;;
        67|76) GEEKBENCH_VERSIONS=(6 7) ;;
        all|567|765) GEEKBENCH_VERSIONS=(5 6 7) ;;
        *) die "不支持的 Geekbench 版本: ${GEEKBENCH_SELECTION}" ;;
    esac
}

parse_args() {
    GEEKBENCH_VERSIONS=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -f|--fast|fast)
                PRESET="fast"; DISK_RUNTIME=10
                shift ;;
            -F|--full|full)
                PRESET="full"; DISK_RUNTIME=60
                shift ;;
            -g|--geekbench)
                [ "$#" -ge 2 ] || die "--geekbench 需要版本参数"
                GEEKBENCH_SELECTION="$2"
                shift 2 ;;
            --no-geekbench)
                RUN_GEEKBENCH=0; GEEKBENCH_SELECTION="none"
                shift ;;
            --no-upload) UPLOAD_RESULTS=0; shift ;;
            --no-disk) RUN_DISK=0; shift ;;
            --auto-swap) AUTO_SWAP=1; shift ;;
            --workdir)
                [ "$#" -ge 2 ] || die "--workdir 需要目录参数"
                WORK_BASE="$2"; shift 2 ;;
            --report)
                [ "$#" -ge 2 ] || die "--report 需要文件参数"
                REPORT_FILE="$2"; shift 2 ;;
            5|6|7|gb5|gb6|gb7|both|56|65|67|76|all|567|765|none)
                GEEKBENCH_SELECTION="$1"; shift ;;
            *) die "未知参数: $1（使用 --help 查看帮助）" ;;
        esac
    done

    if [ "${RUN_GEEKBENCH}" -eq 1 ]; then
        parse_selection
    else
        GEEKBENCH_VERSIONS=()
    fi
}

check_platform() {
    [ "$(uname -s)" = "Linux" ] || die "本脚本只支持 Linux"
    [ "$(getconf LONG_BIT)" = "64" ] || die "本脚本只支持 64 位系统"

    case "$(uname -m)" in
        x86_64|amd64) GB_ARCH="x86_64" ;;
        aarch64|arm64) GB_ARCH="aarch64" ;;
        riscv64) GB_ARCH="riscv64" ;;
        *) die "不支持的处理器架构: $(uname -m)" ;;
    esac
}

prepare_paths() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"

    [ -n "${WORK_BASE}" ] || WORK_BASE="${PWD}/.gpuBench-workdir"
    [ "${WORK_BASE}" != "/" ] || die "工作目录不能是根目录"
    mkdir -p "${WORK_BASE}"

    RUNTIME_DIR="${WORK_BASE}/run-${BASHPID}"
    mkdir -p "${RUNTIME_DIR}"

    [ -n "${REPORT_FILE}" ] || REPORT_FILE="${PWD}/gpuBench-report-${timestamp}.txt"
    mkdir -p "$(dirname "${REPORT_FILE}")"
    : > "${REPORT_FILE}"
    FIO_FILE="${RUNTIME_DIR}/fio-testfile"
}

cleanup() {
    local status="$?"
    set +e
    if [ "${TEMP_SWAP_ACTIVE}" -eq 1 ] && [ -n "${TEMP_SWAP_FILE}" ]; then
        root_run swapoff "${TEMP_SWAP_FILE}" >/dev/null 2>&1 || true
    fi
    if [ -n "${RUNTIME_DIR}" ] && [ -d "${RUNTIME_DIR}" ]; then
        rm -rf "${RUNTIME_DIR}"
    fi
    [ "${status}" -eq 0 ] || warn "测试提前结束，临时文件已清理"
    exit "${status}"
}

lscpu_value() {
    local key="$1"
    lscpu -B 2>/dev/null |
        awk -F: -v key="${key}" '$1 == key {sub(/^[[:space:]]+/, "", $2); print $2; exit}'
}

collect_system_info() {
    local cpu_model cpu_sockets cpu_cores_per_socket cpu_threads_per_core cpu_threads
    local l1d l1i l2 l3 mem_line swap_line disk_line os_name kernel

    cpu_model="$(lscpu_value "Model name")"
    cpu_sockets="$(lscpu_value "Socket(s)")"
    cpu_cores_per_socket="$(lscpu_value "Core(s) per socket")"
    cpu_threads_per_core="$(lscpu_value "Thread(s) per core")"
    cpu_threads="$(lscpu_value "CPU(s)")"
    l1d="$(lscpu_value "L1d cache")"
    l1i="$(lscpu_value "L1i cache")"
    l2="$(lscpu_value "L2 cache")"
    l3="$(lscpu_value "L3 cache")"
    mem_line="$(free -h | awk '/^Mem:/ {print $3 " used / " $2 " total"; exit}')"
    swap_line="$(free -h | awk '/^Swap:/ {print $3 " used / " $2 " total"; exit}')"
    disk_line="$(df -hP / | awk 'NR == 2 {print $3 " used / " $2 " total (" $5 ") on " $1; exit}')"
    os_name="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || printf '%s' unknown)"
    kernel="$(uname -sr)"

    section "系统信息"
    report_line "CPU 型号: ${cpu_model:-unknown}"
    report_line "CPU 拓扑: ${cpu_sockets:-?} socket(s), ${cpu_cores_per_socket:-?} core(s)/socket, ${cpu_threads_per_core:-?} thread(s)/core, ${cpu_threads:-?} logical CPU(s)"
    report_line "CPU 缓存: L1d ${l1d:-unknown}, L1i ${l1i:-unknown}, L2 ${l2:-unknown}, L3 ${l3:-unknown}"
    report_line "内存: ${mem_line:-unknown}"
    report_line "Swap: ${swap_line:-unknown}"
    report_line "根分区: ${disk_line:-unknown}"
    report_line "操作系统: ${os_name}"
    report_line "内核: ${kernel}"
}

format_bandwidth() {
    local kib="$1"
    awk -v value="${kib:-0}" '
        BEGIN {
            if (value == "" || value !~ /^[0-9.]+$/) print "unknown";
            else if (value >= 1024) printf "%.2f MiB/s", value / 1024;
            else printf "%.2f KiB/s", value;
        }'
}

run_fio_case() {
    local label="$1" rw="$2" block_size="$3" size="$4"
    local output terse_line bw iops rate

    printf '%s: running (%ss) ...\n' "${label}" "${DISK_RUNTIME}" | tee -a "${REPORT_FILE}"
    if ! output="$(fio --name="gpuBench-${rw}-${block_size}" \
        --filename="${FIO_FILE}" --ioengine=libaio --rw="${rw}" \
        --bs="${block_size}" --size="${size}" --direct=1 \
        --iodepth=32 --runtime="${DISK_RUNTIME}" --time_based=1 \
        --group_reporting --minimal 2>&1)"; then
        printf '%s: failed\n%s\n' "${label}" "${output}" | tee -a "${REPORT_FILE}"
        return 1
    fi

    terse_line="$(printf '%s\n' "${output}" | awk -F';' 'NF > 20 {line=$0} END {print line}')"
    if [ "${rw}" = "randread" ]; then
        bw="$(printf '%s\n' "${terse_line}" | awk -F';' '{print $7}')"
        iops="$(printf '%s\n' "${terse_line}" | awk -F';' '{print $8}')"
    else
        bw="$(printf '%s\n' "${terse_line}" | awk -F';' '{print $48}')"
        iops="$(printf '%s\n' "${terse_line}" | awk -F';' '{print $49}')"
    fi

    rate="$(format_bandwidth "${bw}")"
    if [ -n "${iops:-}" ] && printf '%s' "${iops}" | grep -Eq '^[0-9.]+$'; then
        printf '%s: %s (%s IOPS)\n' "${label}" "${rate}" "${iops}" | tee -a "${REPORT_FILE}"
    else
        printf '%s: %s\n' "${label}" "${rate}" | tee -a "${REPORT_FILE}"
    fi
}

run_disk_tests() {
    local failed=0
    section "磁盘性能（FIO，direct，iodepth=32）"
    run_fio_case "随机写 4K" randwrite 4k "${DISK_SIZE_4K}" || failed=1
    run_fio_case "随机读 4K" randread 4k "${DISK_SIZE_4K}" || failed=1
    run_fio_case "随机写 128K" randwrite 128k "${DISK_SIZE_128K}" || failed=1
    run_fio_case "随机读 128K" randread 128k "${DISK_SIZE_128K}" || failed=1
    rm -f "${FIO_FILE}"
    [ "${failed}" -eq 0 ] || warn "部分 FIO 测试失败，请查看报告中的原始错误"
}

load_geekbench_config() {
    local version="$1"
    case "${version}" in
        5)
            CURRENT_GB_VERSION="${GB5_VERSION}"; CURRENT_GB_LABEL="Geekbench 5"
            CURRENT_GB_SOFTWARE="geekbench5"; CURRENT_GB_MIN_MEM=1024
            CURRENT_GB_MIN_TOTAL=1280; CURRENT_GB_TARGET_TOTAL=1300 ;;
        6)
            CURRENT_GB_VERSION="${GB6_VERSION}"; CURRENT_GB_LABEL="Geekbench 6"
            CURRENT_GB_SOFTWARE="geekbench6"; CURRENT_GB_MIN_MEM=2048
            CURRENT_GB_MIN_TOTAL=2304; CURRENT_GB_TARGET_TOTAL=2350 ;;
        7)
            CURRENT_GB_VERSION="${GB7_VERSION}"; CURRENT_GB_LABEL="Geekbench 7"
            CURRENT_GB_SOFTWARE="geekbench7"; CURRENT_GB_MIN_MEM=4096
            CURRENT_GB_MIN_TOTAL=4352; CURRENT_GB_TARGET_TOTAL=4400 ;;
        *) die "内部错误：未知 Geekbench 版本 ${version}" ;;
    esac

    case "${GB_ARCH}" in
        x86_64)
            CURRENT_GB_TAR="Geekbench-${CURRENT_GB_VERSION}-Linux.tar.gz"
            CURRENT_GB_FOLDER="Geekbench-${CURRENT_GB_VERSION}-Linux" ;;
        aarch64)
            CURRENT_GB_TAR="Geekbench-${CURRENT_GB_VERSION}-LinuxARMPreview.tar.gz"
            CURRENT_GB_FOLDER="Geekbench-${CURRENT_GB_VERSION}-LinuxARMPreview" ;;
        riscv64)
            CURRENT_GB_TAR="Geekbench-${CURRENT_GB_VERSION}-LinuxRISCVPreview.tar.gz"
            CURRENT_GB_FOLDER="Geekbench-${CURRENT_GB_VERSION}-LinuxRISCVPreview" ;;
    esac
    CURRENT_GB_URL="${GB_CDN_BASE}/${CURRENT_GB_TAR}"
}

ensure_geekbench_memory() {
    local mem_mib swap_mib total_mib need_mib
    mem_mib="$(awk '/MemTotal:/ {printf "%d", $2 / 1024; exit}' /proc/meminfo)"
    swap_mib="$(awk '/SwapTotal:/ {printf "%d", $2 / 1024; exit}' /proc/meminfo)"
    total_mib="$((mem_mib + swap_mib))"

    if [ "${mem_mib}" -ge "${CURRENT_GB_MIN_MEM}" ] ||
       [ "${total_mib}" -ge "${CURRENT_GB_MIN_TOTAL}" ]; then
        return 0
    fi

    if [ "${AUTO_SWAP}" -ne 1 ]; then
        warn "${CURRENT_GB_LABEL} 需要至少 ${CURRENT_GB_MIN_MEM} MiB 内存，当前 ${mem_mib} MiB；已跳过。需要时可加 --auto-swap"
        return 1
    fi

    need_mib="$((CURRENT_GB_TARGET_TOTAL - total_mib))"
    [ "${need_mib}" -gt 0 ] || need_mib=1
    TEMP_SWAP_FILE="${RUNTIME_DIR}/swap"
    info "内存不足，创建 ${need_mib} MiB 临时 Swap"

    root_run dd if=/dev/zero of="${TEMP_SWAP_FILE}" bs=1M count="${need_mib}" status=none || return 1
    root_run chmod 0600 "${TEMP_SWAP_FILE}" || return 1
    root_run mkswap "${TEMP_SWAP_FILE}" >/dev/null 2>&1 || return 1
    root_run swapon "${TEMP_SWAP_FILE}" || return 1
    TEMP_SWAP_ACTIVE=1
}

download_geekbench() {
    local archive="${RUNTIME_DIR}/${CURRENT_GB_TAR}"
    info "下载 ${CURRENT_GB_LABEL}: ${CURRENT_GB_URL}"

    if ! curl --fail --location --retry 2 --progress-bar -o "${archive}" "${CURRENT_GB_URL}"; then
        warn "${CURRENT_GB_LABEL} 下载失败"
        return 1
    fi
    [ -s "${archive}" ] || return 1
    if ! tar -xzf "${archive}" -C "${RUNTIME_DIR}"; then
        warn "${CURRENT_GB_LABEL} 解压失败"
        return 1
    fi
    if [ ! -x "${RUNTIME_DIR}/${CURRENT_GB_FOLDER}/${CURRENT_GB_SOFTWARE}" ]; then
        chmod +x "${RUNTIME_DIR}/${CURRENT_GB_FOLDER}/${CURRENT_GB_SOFTWARE}" || return 1
    fi
}

run_geekbench_version() {
    local version="$1"
    local result_file="${RUNTIME_DIR}/result-gb${version}.txt"
    local binary result_url single_score multi_score status

    load_geekbench_config "${version}"
    section "${CURRENT_GB_LABEL} CPU 性能"
    if ! ensure_geekbench_memory; then
        report_line "状态: 内存条件不满足，已跳过"
        return 0
    fi
    if ! download_geekbench; then
        report_line "状态: 下载或解压失败，已跳过"
        return 0
    fi

    binary="${RUNTIME_DIR}/${CURRENT_GB_FOLDER}/${CURRENT_GB_SOFTWARE}"
    if [ ! -x "${binary}" ]; then
        warn "找不到 ${CURRENT_GB_LABEL} 可执行文件"
        report_line "状态: 找不到可执行文件，已跳过"
        return 0
    fi

    info "运行 ${CURRENT_GB_LABEL}，原始输出保存到 ${result_file}"
    set +e
    if [ "${UPLOAD_RESULTS}" -eq 1 ]; then
        "${binary}" --upload 2>&1 | tee "${result_file}"
    else
        "${binary}" 2>&1 | tee "${result_file}"
    fi
    status="${PIPESTATUS[0]}"
    set -e

    result_url="$(grep -oE 'https://browser\.geekbench\.com/v[0-9]+/cpu/[0-9]+' "${result_file}" | head -n 1 || true)"
    single_score="$(grep -iE 'Single[- ]Core Score' "${result_file}" | grep -oE '[0-9]+' | tail -n 1 || true)"
    multi_score="$(grep -iE 'Multi[- ]Core Score' "${result_file}" | grep -oE '[0-9]+' | tail -n 1 || true)"

    report_line "运行状态: ${status}"
    report_line "单核分数: ${single_score:-未解析}"
    report_line "多核分数: ${multi_score:-未解析}"
    if [ -n "${result_url}" ]; then
        report_line "官方结果: ${result_url}"
    elif [ "${UPLOAD_RESULTS}" -eq 1 ]; then
        report_line "官方结果: 未获取（上传可能失败）"
    else
        report_line "官方结果: 未上传（使用了 --no-upload）"
    fi
    report_line "原始输出: ${result_file}"
    [ "${status}" -eq 0 ] || warn "${CURRENT_GB_LABEL} 退出码为 ${status}"
}

run_geekbench_tests() {
    local version
    section "Geekbench CPU 测试"
    report_line "本次版本: ${GEEKBENCH_VERSIONS[*]}"
    for version in "${GEEKBENCH_VERSIONS[@]}"; do
        run_geekbench_version "${version}"
    done
}

main() {
    parse_args "$@"
    if [ "${RUN_DISK}" -eq 0 ] && [ "${RUN_GEEKBENCH}" -eq 0 ]; then
        die "至少选择一类性能测试，或使用 --help 查看用法"
    fi

    check_platform
    export LC_ALL=C
    prepare_paths
    trap cleanup EXIT

    ensure_command lscpu util-linux
    ensure_command free procps
    [ "${RUN_DISK}" -eq 0 ] || ensure_command fio fio
    if [ "${RUN_GEEKBENCH}" -eq 1 ]; then
        ensure_command curl curl
        ensure_command tar tar
    fi

    section "${SCRIPT_NAME} ${SCRIPT_VERSION}"
    report_line "预置: ${PRESET}"
    report_line "报告: ${REPORT_FILE}"
    report_line "CPU 性能引擎: Geekbench（只运行所选版本）"
    report_line "网络性能与内容检查: 未启用"

    collect_system_info
    [ "${RUN_DISK}" -eq 0 ] || run_disk_tests
    [ "${RUN_GEEKBENCH}" -eq 0 ] || run_geekbench_tests

    section "完成"
    report_line "本地报告: ${REPORT_FILE}"
    success "测试完成，报告已保存到 ${REPORT_FILE}"
}

main "$@"
