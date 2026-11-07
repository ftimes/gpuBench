#!/usr/bin/env bash
#
# v100check - read-only-first health check, stress test, and interconnect
# report generator for second-hand NVIDIA V100 servers.
#
# The script intentionally keeps raw command output in the run directory.  A
# Python helper parses those artifacts and generates result.json and summary.md.

set -Eeuo pipefail

SCRIPT_NAME="v100check"
SCRIPT_VERSION="0.1.0"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PY="${SCRIPT_DIR}/lib/report.py"

PROFILE="probe"
GPU_SELECTION="all"
DURATION="30m"
POSTCHECK_DURATION="5m"
SAMPLE_INTERVAL=2
WARN_TEMP=75
MAX_TEMP=82
MEMORY_PERCENT=80
LOG_LIMIT_MB=100
OUT_BASE="${PWD}/v100check-reports"
DCGM_PATH=""
GPU_BURN_PATH=""
CUDA_MEMTEST_PATH=""
NVBANDWIDTH_PATH=""
GPUSTRESSTEST_PATH=""
ALLOW_ACTIVE=0
INSTALL_DEPS=0
STRICT=0
SELF_TEST=0

RUN_DIR=""
STARTED_AT=""
NVIDIA_SMI_PATH=""
SAMPLER_PID=""
STRESS_PID=""
DCGM_HEALTH_ACTIVE=0
DCGM_HEALTH_FINALIZED=0
INTERRUPTED=0

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

usage() {
    cat <<'USAGE'
v100check - V100 服务器验机、烤机、显存/ECC/NVLink 检测

用法:
  v100check.sh [选项]

档位:
  --profile probe       只采集硬件和软件基线（默认）
  --profile fast        快速显存/PCIe 检查，约 2–5 分钟
  --profile medium      中等压力，约 20–30 分钟
  --profile long        长时间烤机，必须显式启用
  --profile all         probe + fast + medium，不包含 long

设备和阈值:
  --gpu all|0,1         指定 GPU，保留给外部工具和记录使用
  --duration 30m|8h     long 或 fallback 烤机时长
  --postcheck-duration 5m
                         long 烤机后的显存/数据路径复核时长
  --sample-interval N   遥测采样间隔，默认 2 秒
  --warn-temp N         温度警戒阈值，默认 75°C
  --max-temp N          温度停止阈值，默认 82°C
  --memory-percent N    gpu-burn 显存比例，默认 80%
  --log-limit-mb N      离线分析日志上限，默认 100，最大 100

工具路径:
  --out DIR             报告根目录
  --dcgm PATH           指定 dcgmi
  --gpu-burn PATH       指定 gpu_burn
  --cuda-memtest PATH   指定 cuda_memtest
  --nvbandwidth PATH    指定 nvbandwidth
  --gpu-stress-test PATH 指定 NVIDIA GPUStressTest 可执行文件

行为:
  --allow-active        GPU 已有计算进程时仍允许压力测试
  --install-deps        显式安装 python3/pciutils；不会安装驱动或 CUDA
  --strict              缺少关键诊断工具时将 UNKNOWN 提升为 INCOMPLETE
  --self-test           运行本地解析/判定自测
  -h, --help            显示帮助

示例:
  sudo ./v100check.sh --profile probe
  sudo ./v100check.sh --profile medium --duration 30m
  sudo ./v100check.sh --profile long --duration 8h
  ./v100check.sh --self-test
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

quote_command() {
    local arg
    local result=""
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        result+="${arg} "
    done
    printf '%s' "${result% }"
}

seconds_from_duration() {
    local value="$1"
    if [[ "${value}" =~ ^([0-9]+)(s|m|h|d)$ ]]; then
        local amount="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            s) printf '%s\n' "$amount" ;;
            m) printf '%s\n' "$((amount * 60))" ;;
            h) printf '%s\n' "$((amount * 3600))" ;;
            d) printf '%s\n' "$((amount * 86400))" ;;
        esac
    else
        die "时长格式错误: ${value}（示例：30m、8h）"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --profile)
                [ "$#" -ge 2 ] || die "--profile 需要参数"
                PROFILE="$2"
                shift 2
                ;;
            --gpu)
                [ "$#" -ge 2 ] || die "--gpu 需要参数"
                GPU_SELECTION="$2"
                shift 2
                ;;
            --duration)
                [ "$#" -ge 2 ] || die "--duration 需要参数"
                DURATION="$2"
                shift 2
                ;;
            --postcheck-duration)
                [ "$#" -ge 2 ] || die "--postcheck-duration 需要参数"
                POSTCHECK_DURATION="$2"
                shift 2
                ;;
            --sample-interval)
                [ "$#" -ge 2 ] || die "--sample-interval 需要参数"
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            --warn-temp)
                [ "$#" -ge 2 ] || die "--warn-temp 需要参数"
                WARN_TEMP="$2"
                shift 2
                ;;
            --max-temp)
                [ "$#" -ge 2 ] || die "--max-temp 需要参数"
                MAX_TEMP="$2"
                shift 2
                ;;
            --memory-percent)
                [ "$#" -ge 2 ] || die "--memory-percent 需要参数"
                MEMORY_PERCENT="$2"
                shift 2
                ;;
            --log-limit-mb)
                [ "$#" -ge 2 ] || die "--log-limit-mb 需要参数"
                LOG_LIMIT_MB="$2"
                shift 2
                ;;
            --out)
                [ "$#" -ge 2 ] || die "--out 需要参数"
                OUT_BASE="$2"
                shift 2
                ;;
            --dcgm)
                [ "$#" -ge 2 ] || die "--dcgm 需要参数"
                DCGM_PATH="$2"
                shift 2
                ;;
            --gpu-burn)
                [ "$#" -ge 2 ] || die "--gpu-burn 需要参数"
                GPU_BURN_PATH="$2"
                shift 2
                ;;
            --cuda-memtest)
                [ "$#" -ge 2 ] || die "--cuda-memtest 需要参数"
                CUDA_MEMTEST_PATH="$2"
                shift 2
                ;;
            --nvbandwidth)
                [ "$#" -ge 2 ] || die "--nvbandwidth 需要参数"
                NVBANDWIDTH_PATH="$2"
                shift 2
                ;;
            --gpu-stress-test)
                [ "$#" -ge 2 ] || die "--gpu-stress-test 需要参数"
                GPUSTRESSTEST_PATH="$2"
                shift 2
                ;;
            --allow-active)
                ALLOW_ACTIVE=1
                shift
                ;;
            --install-deps)
                INSTALL_DEPS=1
                shift
                ;;
            --strict)
                STRICT=1
                shift
                ;;
            --self-test)
                SELF_TEST=1
                shift
                ;;
            *)
                die "未知参数: $1（使用 --help 查看帮助）"
                ;;
        esac
    done

    case "${PROFILE}" in
        probe|fast|medium|long|all) ;;
        *) die "不支持的 profile: ${PROFILE}" ;;
    esac

    [[ "${SAMPLE_INTERVAL}" =~ ^[0-9]+$ ]] || die "--sample-interval 必须是整数"
    [ "${SAMPLE_INTERVAL}" -ge 1 ] || die "--sample-interval 必须大于 0"
    [[ "${WARN_TEMP}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--warn-temp 必须是数字"
    [[ "${MAX_TEMP}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--max-temp 必须是数字"
    [[ "${MEMORY_PERCENT}" =~ ^[1-9][0-9]?$|^100$ ]] || die "--memory-percent 必须在 1–100 之间"
    [[ "${LOG_LIMIT_MB}" =~ ^[1-9][0-9]*$ ]] || die "--log-limit-mb 必须是正整数"
    [ "${LOG_LIMIT_MB}" -le 100 ] || die "--log-limit-mb 最大为 100"
    [ "${MAX_TEMP%.*}" -gt "${WARN_TEMP%.*}" ] || die "--max-temp 必须大于 --warn-temp"
    if [ "${GPU_SELECTION}" != "all" ]; then
        [[ "${GPU_SELECTION}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--gpu 必须是 all 或逗号分隔的 GPU 编号"
    fi
    seconds_from_duration "${DURATION}" >/dev/null
    seconds_from_duration "${POSTCHECK_DURATION}" >/dev/null
}

install_deps() {
    [ "${INSTALL_DEPS}" -eq 1 ] || return 0
    command_exists apt-get || die "--install-deps 当前只实现 apt-get"
    local runner=()
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        command_exists sudo || die "--install-deps 需要 root 或 sudo"
        runner=(sudo)
    fi
    info "安装只读辅助依赖 python3 和 pciutils"
    "${runner[@]}" apt-get update
    "${runner[@]}" apt-get install -y --no-install-recommends python3 pciutils
}

resolve_tools() {
    local explicit_name
    local explicit_path
    for explicit_name in DCGM_PATH GPU_BURN_PATH CUDA_MEMTEST_PATH NVBANDWIDTH_PATH GPUSTRESSTEST_PATH; do
        explicit_path="${!explicit_name}"
        if [ -n "${explicit_path}" ] && [ ! -x "${explicit_path}" ]; then
            die "指定的工具不可执行: ${explicit_name}=${explicit_path}"
        fi
    done
    if [ -z "${DCGM_PATH}" ] && command_exists dcgmi; then
        DCGM_PATH="$(command -v dcgmi)"
    fi
    if [ -z "${GPU_BURN_PATH}" ] && command_exists gpu_burn; then
        GPU_BURN_PATH="$(command -v gpu_burn)"
    fi
    if [ -z "${CUDA_MEMTEST_PATH}" ] && command_exists cuda_memtest; then
        CUDA_MEMTEST_PATH="$(command -v cuda_memtest)"
    fi
    if [ -z "${NVBANDWIDTH_PATH}" ] && command_exists nvbandwidth; then
        NVBANDWIDTH_PATH="$(command -v nvbandwidth)"
    fi
    if [ -z "${GPUSTRESSTEST_PATH}" ] && command_exists GPUStressTest; then
        GPUSTRESSTEST_PATH="$(command -v GPUStressTest)"
    fi
    if command_exists nvidia-smi; then
        NVIDIA_SMI_PATH="$(command -v nvidia-smi)"
    fi
}

prepare_run_dir() {
    STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local stamp
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    mkdir -p "${OUT_BASE}"
    RUN_DIR="${OUT_BASE}/${stamp}-$$"
    mkdir -p "${RUN_DIR}/commands" "${RUN_DIR}/tests" "${RUN_DIR}/logs"
    : > "${RUN_DIR}/telemetry.csv"
    cat > "${RUN_DIR}/telemetry.csv" <<'HEADER'
timestamp,index,uuid,temperature.gpu,power.draw,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,pstate
HEADER
}

run_capture() {
    local name="$1"
    shift
    local stdout="${RUN_DIR}/${name}.stdout"
    local stderr="${RUN_DIR}/${name}.stderr"
    local rc_file="${RUN_DIR}/${name}.rc"
    local rc=0
    mkdir -p "$(dirname "${stdout}")"
    set +e
    "$@" >"${stdout}" 2>"${stderr}"
    rc=$?
    set -e
    printf '%s\n' "${rc}" > "${rc_file}"
    return 0
}

capture_rc() {
    local name="$1"
    if [ -f "${RUN_DIR}/${name}.rc" ]; then
        cat "${RUN_DIR}/${name}.rc"
    else
        printf '%s\n' 127
    fi
}

record_test() {
    local id="$1"
    local status="$2"
    local command="$3"
    local rc="$4"
    local note="$5"
    python3 "${REPORT_PY}" record-test \
        --run-dir "${RUN_DIR}" \
        --id "${id}" \
        --status "${status}" \
        --command "${command}" \
        --rc "${rc}" \
        --note "${note}" >/dev/null
}

version_line() {
    local path="$1"
    if [ -z "${path}" ] || [ ! -x "${path}" ]; then
        return 0
    fi
    "$path" --version 2>&1 | head -n 1 || true
}

write_manifest() {
    local platform
    local hostname
    local kernel
    platform="$(uname -s 2>/dev/null || true)"
    hostname="$(hostname 2>/dev/null || true)"
    kernel="$(uname -r 2>/dev/null || true)"
    python3 - "${RUN_DIR}/manifest.json" "${SCRIPT_VERSION}" "${PROFILE}" "${STARTED_AT}" "${platform}" "${hostname}" "${kernel}" \
        "${WARN_TEMP}" "${MAX_TEMP}" "${MEMORY_PERCENT}" "${LOG_LIMIT_MB}" "${GPU_SELECTION}" "${DURATION}" "${POSTCHECK_DURATION}" \
        "${NVIDIA_SMI_PATH}" "${DCGM_PATH}" "${GPU_BURN_PATH}" "${CUDA_MEMTEST_PATH}" "${NVBANDWIDTH_PATH}" "${GPUSTRESSTEST_PATH}" \
        "$(version_line "${NVIDIA_SMI_PATH}")" "$(version_line "${DCGM_PATH}")" \
        "$(version_line "$(command -v nvcc 2>/dev/null || true)")" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    script_version,
    profile,
    started_at,
    platform,
    hostname,
    kernel,
    warn_temp,
    max_temp,
    memory_percent,
    log_limit_mb,
    gpu_selection,
    duration,
    postcheck_duration,
    nvidia_smi,
    dcgm,
    gpu_burn,
    cuda_memtest,
    nvbandwidth,
    gpu_stress_test,
    nvidia_smi_version,
    dcgm_version,
    nvcc_version,
) = sys.argv[1:]

manifest = {
    "schema_version": 1,
    "script_version": script_version,
    "run_id": Path(output).parent.name,
    "started_at": started_at,
    "platform": platform,
    "hostname": hostname,
    "kernel": kernel,
    "warn_temp": float(warn_temp),
    "max_temp": float(max_temp),
    "memory_percent": int(memory_percent),
    "log_limit_mb": int(log_limit_mb),
    "log_limit_bytes": int(log_limit_mb) * 1000 * 1000,
    "gpu_selection": gpu_selection,
    "duration": duration,
    "postcheck_duration": postcheck_duration,
    "software": {
        "nvidia_smi": {"path": nvidia_smi, "version": nvidia_smi_version},
        "dcgm": {"path": dcgm, "version": dcgm_version},
        "nvcc": {"version": nvcc_version},
        "gpu_burn": {"path": gpu_burn},
        "cuda_memtest": {"path": cuda_memtest},
        "nvbandwidth": {"path": nvbandwidth},
        "gpu_stress_test": {"path": gpu_stress_test},
    },
}
Path(output).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

collect_system() {
    info "采集系统和软件信息"
    run_capture system-uname uname -a
    if command_exists lsb_release; then
        run_capture system-lsb-release lsb_release -a
    else
        run_capture system-os-release cat /etc/os-release
    fi
    if command_exists lscpu; then
        run_capture system-lscpu lscpu
    fi
    if command_exists free; then
        run_capture system-memory free -h
    fi
    if command_exists lsblk; then
        run_capture system-lsblk lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    fi
    if command_exists lspci; then
        run_capture system-lspci lspci -nn
    fi
    if command_exists numactl; then
        run_capture system-numactl numactl -H
    fi
    if [ -n "${NVIDIA_SMI_PATH}" ]; then
        run_capture nvidia-version "${NVIDIA_SMI_PATH}" --version
        run_capture nvidia-list "${NVIDIA_SMI_PATH}" -L
        run_capture nvidia-processes "${NVIDIA_SMI_PATH}" \
            --query-compute-apps=pid,process_name,used_memory \
            --format=csv,noheader,nounits
    fi
    if [ -n "${DCGM_PATH}" ]; then
        run_capture dcgm-version "${DCGM_PATH}" --version
    fi
    if command_exists nvcc; then
        run_capture nvcc-version nvcc --version
    fi
    if command_exists dmesg; then
        run_capture kernel-before dmesg --color=never
    elif command_exists journalctl; then
        run_capture kernel-before journalctl -k -b --no-pager
    else
        : > "${RUN_DIR}/kernel-before.stdout"
    fi
}

collect_snapshot() {
    local label="$1"
    info "采集 GPU 快照: ${label}"
    if [ -z "${NVIDIA_SMI_PATH}" ]; then
        for name in \
            "nvidia-query-core-${label}" \
            "nvidia-query-ecc-${label}" \
            "nvidia-q-${label}" \
            "topo-m-${label}" \
            "topo-p2p-${label}" \
            "nvlink-status-${label}" \
            "nvlink-errors-${label}" \
            "nvlink-counters-${label}" \
            "nvlink-capabilities-${label}" \
            "gpu-verbose-${label}"; do
            : > "${RUN_DIR}/${name}.stdout"
            printf '%s\n' 127 > "${RUN_DIR}/${name}.rc"
        done
        return 0
    fi

    run_capture "nvidia-query-core-${label}" "${NVIDIA_SMI_PATH}" \
        --query-gpu=index,uuid,name,serial,memory.total,memory.used,memory.free,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.memory,pstate,pcie.link.gen.current,pcie.link.width.current,utilization.gpu,utilization.memory \
        --format=csv,noheader,nounits
    run_capture "nvidia-query-ecc-${label}" "${NVIDIA_SMI_PATH}" \
        --query-gpu=index,uuid,ecc.mode.current,ecc.mode.pending,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,retired_pages.single_bit_ecc,retired_pages.double_bit_ecc,retired_pages.pending \
        --format=csv,noheader,nounits
    run_capture "nvidia-q-${label}" "${NVIDIA_SMI_PATH}" -q -x
    run_capture "topo-m-${label}" "${NVIDIA_SMI_PATH}" topo -m
    run_capture "topo-p2p-${label}" "${NVIDIA_SMI_PATH}" topo -p2p r
    run_capture "nvlink-status-${label}" "${NVIDIA_SMI_PATH}" nvlink -s
    run_capture "nvlink-errors-${label}" "${NVIDIA_SMI_PATH}" nvlink -e
    run_capture "nvlink-counters-${label}" "${NVIDIA_SMI_PATH}" nvlink -c
    run_capture "nvlink-capabilities-${label}" "${NVIDIA_SMI_PATH}" nvlink -b
    run_capture "gpu-verbose-${label}" "${NVIDIA_SMI_PATH}" -q
}

active_gpu_processes() {
    [ -n "${NVIDIA_SMI_PATH}" ] || return 1
    local output
    output="$(cat "${RUN_DIR}/nvidia-processes.stdout" 2>/dev/null || true)"
    [ -n "${output}" ] || return 1
    if printf '%s\n' "${output}" | grep -Eqi 'no running processes|no processes'; then
        return 1
    fi
    printf '%s\n' "${output}" | grep -Eq '[0-9]'
}

start_sampler() {
    local watched_pid="$1"
    [ -n "${NVIDIA_SMI_PATH}" ] || return 0
    (
        while kill -0 "${watched_pid}" 2>/dev/null; do
            local stamp
            stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            local output=""
            output="$("${NVIDIA_SMI_PATH}" \
                --query-gpu=index,uuid,temperature.gpu,power.draw,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,pstate \
                --format=csv,noheader,nounits 2>/dev/null || true)"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                printf '%s,%s\n' "${stamp}" "${line}" >> "${RUN_DIR}/telemetry.csv"
                local temp
                temp="$(printf '%s\n' "${line}" | awk -F',' '{gsub(/[[:space:]]/, "", $3); print $3}')"
                if [ -n "${temp}" ] && awk -v value="${temp}" -v limit="${MAX_TEMP}" 'BEGIN { exit !(value + 0 >= limit) }'; then
                    printf '%s\n' "temperature limit ${temp} >= ${MAX_TEMP}" > "${RUN_DIR}/abort-reason.txt"
                    kill -TERM "${watched_pid}" 2>/dev/null || true
                fi
            done <<< "${output}"
            sleep "${SAMPLE_INTERVAL}"
        done
    ) &
    SAMPLER_PID=$!
}

stop_sampler() {
    if [ -n "${SAMPLER_PID}" ]; then
        kill "${SAMPLER_PID}" 2>/dev/null || true
        wait "${SAMPLER_PID}" 2>/dev/null || true
        SAMPLER_PID=""
    fi
}

run_test_command_monitored() {
    local id="$1"
    shift
    local -a command_args=("$@")
    if [ "${GPU_SELECTION}" != "all" ]; then
        command_args=(env "CUDA_VISIBLE_DEVICES=${GPU_SELECTION}" "${command_args[@]}")
    fi
    local command_text
    command_text="$(quote_command "${command_args[@]}")"
    info "执行监控测试 ${id}: ${command_text}"
    local stdout="${RUN_DIR}/commands/test-${id}.stdout"
    local stderr="${RUN_DIR}/commands/test-${id}.stderr"
    local rc_file="${RUN_DIR}/commands/test-${id}.rc"
    mkdir -p "$(dirname "${stdout}")"
    set +e
    "${command_args[@]}" >"${stdout}" 2>"${stderr}" &
    STRESS_PID=$!
    set -e
    start_sampler "${STRESS_PID}"
    local rc=0
    set +e
    wait "${STRESS_PID}"
    rc=$?
    set -e
    STRESS_PID=""
    stop_sampler
    printf '%s\n' "${rc}" > "${rc_file}"
    if [ "${rc}" -eq 0 ]; then
        record_test "${id}" "PASS" "${command_text}" "${rc}" "命令返回 0"
    else
        record_test "${id}" "FAIL" "${command_text}" "${rc}" "命令返回 ${rc}"
    fi
}

record_skipped() {
    local id="$1"
    local note="$2"
    record_test "${id}" "SKIPPED" "" 127 "${note}"
}

run_dcgm_profile() {
    local level="$1"
    if [ -z "${DCGM_PATH}" ]; then
        record_skipped "dcgm-level-${level}" "未找到 dcgmi；请安装 NVIDIA DCGM 后重试"
        return 0
    fi
    run_test_command_monitored "dcgm-level-${level}" "${DCGM_PATH}" diag -r "${level}"
}

run_fast_fallback() {
    if [ -n "${CUDA_MEMTEST_PATH}" ] && command_exists timeout; then
        run_test_command_monitored "fast-cuda-memtest" timeout --signal=TERM 60 "${CUDA_MEMTEST_PATH}"
    elif [ -n "${CUDA_MEMTEST_PATH}" ]; then
        run_test_command_monitored "fast-cuda-memtest" "${CUDA_MEMTEST_PATH}"
    elif [ -n "${GPU_BURN_PATH}" ]; then
        run_test_command_monitored "fast-gpu-burn" "${GPU_BURN_PATH}" -m 50% 60
    else
        record_skipped "fast-diagnostics" "DCGM、cuda_memtest 和 gpu_burn 均不可用"
    fi
}

run_medium_fallback() {
    if [ -n "${GPU_BURN_PATH}" ]; then
        local seconds
        seconds="$(seconds_from_duration "${DURATION}")"
        run_test_command_monitored "medium-gpu-burn" "${GPU_BURN_PATH}" -m "${MEMORY_PERCENT}%" "${seconds}"
    else
        record_skipped "medium-diagnostics" "DCGM 和 gpu_burn 均不可用"
    fi
}

run_nvbandwidth() {
    if [ -z "${NVBANDWIDTH_PATH}" ]; then
        record_skipped "nvbandwidth" "未找到 nvbandwidth，NVLink 带宽测试跳过"
        return 0
    fi
    run_test_command_monitored "nvbandwidth" "${NVBANDWIDTH_PATH}" -p device_to_device --format json
}

run_cuda_memtest() {
    if [ -z "${CUDA_MEMTEST_PATH}" ]; then
        record_skipped "cuda-memtest" "未找到 cuda_memtest，显存模式测试跳过"
        return 0
    fi
    local duration="${1:-${DURATION}}"
    local seconds
    seconds="$(seconds_from_duration "${duration}")"
    if ! command_exists timeout; then
        record_skipped "cuda-memtest" "系统没有 timeout，无法安全限制显存测试时长"
        return 0
    fi
    run_test_command_monitored "cuda-memtest" timeout --signal=TERM "${seconds}" "${CUDA_MEMTEST_PATH}"
}

run_gpu_burn() {
    if [ -z "${GPU_BURN_PATH}" ]; then
        record_skipped "gpu-burn" "未找到 gpu_burn，长时间算力压力跳过"
        return 0
    fi
    local seconds
    seconds="$(seconds_from_duration "${DURATION}")"
    local args=("${GPU_BURN_PATH}" -m "${MEMORY_PERCENT}%")
    if [ "${PROFILE}" = "long" ]; then
        args+=(-tc)
    fi
    args+=("${seconds}")
    local command_text
    command_text="$(quote_command "${args[@]}")"
    info "执行长时间 GPU 压力: ${command_text}"
    run_test_command_monitored "gpu-burn" "${args[@]}"
}

run_gpu_stress_test() {
    if [ -z "${GPUSTRESSTEST_PATH}" ]; then
        record_skipped "gpu-stress-test" "未找到 NVIDIA GPUStressTest，数据路径测试跳过"
        return 0
    fi
    local duration="${1:-${POSTCHECK_DURATION}}"
    local seconds
    seconds="$(seconds_from_duration "${duration}")"
    if ! command_exists timeout; then
        record_skipped "gpu-stress-test" "系统没有 timeout，避免无限等待 GPUStressTest"
        return 0
    fi
    run_test_command_monitored "gpu-stress-test" timeout --signal=TERM "${seconds}" "${GPUSTRESSTEST_PATH}"
}

health_retention_seconds() {
    local primary post
    primary="$(seconds_from_duration "${DURATION}")"
    post="$(seconds_from_duration "${POSTCHECK_DURATION}")"
    printf '%s\n' "$((primary + post + 600))"
}

start_dcgm_health_watch() {
    if [ -z "${DCGM_PATH}" ]; then
        record_skipped "dcgm-health-watch" "未找到 dcgmi，持续健康监控跳过"
        return 0
    fi
    local retention
    retention="$(health_retention_seconds)"
    run_capture commands/dcgmi-health-set "${DCGM_PATH}" health --set a --group g \
        --update-interval 30 --max-keep-age "${retention}"
    local rc
    rc="$(capture_rc commands/dcgmi-health-set)"
    if [ "${rc}" -eq 0 ]; then
        DCGM_HEALTH_ACTIVE=1
        record_test "dcgm-health-watch" "PASS" \
            "$(quote_command "${DCGM_PATH}" health --set a --group g --update-interval 30 --max-keep-age "${retention}")" \
            "${rc}" "已启用 DCGM Health Watch，保留窗口 ${retention} 秒"
    else
        record_test "dcgm-health-watch" "UNKNOWN" \
            "$(quote_command "${DCGM_PATH}" health --set a --group g --update-interval 30 --max-keep-age "${retention}")" \
            "${rc}" "DCGM Health Watch 启用失败，详见 commands/dcgmi-health-set.stdout/stderr"
    fi
}

check_dcgm_health_watch() {
    [ "${DCGM_HEALTH_ACTIVE}" -eq 1 ] || return 0
    run_capture commands/dcgmi-health-check "${DCGM_PATH}" health --check --group g --json
    local rc
    rc="$(capture_rc commands/dcgmi-health-check)"
    local output
    output="$(cat "${RUN_DIR}/commands/dcgmi-health-check.stdout" \
        "${RUN_DIR}/commands/dcgmi-health-check.stderr" 2>/dev/null || true)"
    local status="PASS"
    local note="DCGM Health Watch 检查未发现失败项"
    if [ "${rc}" -ne 0 ]; then
        status="UNKNOWN"
        note="DCGM Health Watch 检查命令返回 ${rc}"
    elif printf '%s\n' "${output}" | grep -Eiq \
        '("status"|"result"|"test_status")[[:space:]]*:[[:space:]]*"?(fail|failure)|(^|[^[:alpha:]])(FAIL|FAILURE)([^[:alpha:]]|$)'; then
        status="FAIL"
        note="DCGM Health Watch 报告 Failure"
    elif printf '%s\n' "${output}" | grep -Eiq \
        '("status"|"result"|"test_status")[[:space:]]*:[[:space:]]*"?(warn|warning)|(^|[^[:alpha:]])(WARN|WARNING)([^[:alpha:]]|$)'; then
        status="WARN"
        note="DCGM Health Watch 报告 Warning"
    fi
    record_test "dcgm-health-check" "${status}" \
        "$(quote_command "${DCGM_PATH}" health --check --group g --json)" \
        "${rc}" "${note}"
}

clear_dcgm_health_watch() {
    [ "${DCGM_HEALTH_ACTIVE}" -eq 1 ] || return 0
    run_capture commands/dcgmi-health-clear "${DCGM_PATH}" health --clear --group g
    local rc
    rc="$(capture_rc commands/dcgmi-health-clear)"
    if [ "${rc}" -eq 0 ]; then
        record_test "dcgm-health-clear" "PASS" \
            "$(quote_command "${DCGM_PATH}" health --clear --group g)" \
            "${rc}" "已清除临时 DCGM Health Watch 配置"
    else
        record_test "dcgm-health-clear" "UNKNOWN" \
            "$(quote_command "${DCGM_PATH}" health --clear --group g)" \
            "${rc}" "清除 DCGM Health Watch 失败，需人工确认服务器状态"
    fi
    DCGM_HEALTH_ACTIVE=0
}

finalize_dcgm_health() {
    [ "${DCGM_HEALTH_ACTIVE}" -eq 1 ] || return 0
    [ "${DCGM_HEALTH_FINALIZED}" -eq 0 ] || return 0
    DCGM_HEALTH_FINALIZED=1
    check_dcgm_health_watch
    clear_dcgm_health_watch
}

run_profile() {
    local profile="$1"
    case "${profile}" in
        probe)
            return 0
            ;;
        fast)
            if [ -n "${DCGM_PATH}" ]; then
                run_dcgm_profile 2
            else
                run_fast_fallback
            fi
            ;;
        medium)
            if [ -n "${DCGM_PATH}" ]; then
                run_dcgm_profile 3
            else
                run_medium_fallback
            fi
            run_nvbandwidth
            ;;
        long)
            run_gpu_burn
            # --duration 是主烤机时长。显存和数据路径测试使用短时后置复核，
            # 避免 --duration 24h 被重复应用而意外运行两天以上。
            run_cuda_memtest "${POSTCHECK_DURATION}"
            run_gpu_stress_test "${POSTCHECK_DURATION}"
            ;;
        all)
            if [ -n "${DCGM_PATH}" ]; then
                run_dcgm_profile 2
                run_dcgm_profile 3
            else
                run_fast_fallback
                run_medium_fallback
            fi
            run_nvbandwidth
            ;;
    esac
}

finalize_report() {
    local result
    if [ "${STRICT}" -eq 1 ]; then
        if ! result="$(python3 "${REPORT_PY}" finalize \
            --run-dir "${RUN_DIR}" \
            --profile "${PROFILE}" \
            --log-limit-mb "${LOG_LIMIT_MB}" \
            --strict)"; then
            error "报告生成失败: ${RUN_DIR}"
            return 1
        fi
    else
        if ! result="$(python3 "${REPORT_PY}" finalize \
            --run-dir "${RUN_DIR}" \
            --profile "${PROFILE}" \
            --log-limit-mb "${LOG_LIMIT_MB}")"; then
            error "报告生成失败: ${RUN_DIR}"
            return 1
        fi
    fi
    if [ -n "${result}" ]; then
        printf '%s\n' "${result}"
    fi
}

cleanup() {
    stop_sampler
    if [ -n "${STRESS_PID}" ]; then
        kill "${STRESS_PID}" 2>/dev/null || true
        wait "${STRESS_PID}" 2>/dev/null || true
        STRESS_PID=""
    fi
    finalize_dcgm_health
}

on_interrupt() {
    INTERRUPTED=1
    warn "收到中断信号，正在停止后台测试并保存当前报告"
    cleanup
    if [ -n "${RUN_DIR}" ]; then
        record_test "run-interrupted" "INCOMPLETE" "" 130 "用户中断或终端关闭"
        finalize_report || true
    fi
    exit 130
}

main() {
    parse_args "$@"
    if [ "${SELF_TEST}" -eq 1 ]; then
        exec python3 "${REPORT_PY}" self-test
    fi
    command_exists python3 || die "需要 python3 才能生成 JSON/Markdown 报告"
    install_deps
    resolve_tools
    prepare_run_dir
    trap on_interrupt INT TERM
    trap cleanup EXIT
    write_manifest
    collect_system
    resolve_tools

    if [ -z "${NVIDIA_SMI_PATH}" ]; then
        warn "当前环境没有 nvidia-smi，压力测试将全部跳过"
        record_test "nvidia-smi" "UNKNOWN" "" 127 "未找到 nvidia-smi，无法执行 GPU 检测"
    fi

    collect_snapshot before

    if [ "${PROFILE}" = "probe" ]; then
        run_profile "${PROFILE}"
    elif [ -z "${NVIDIA_SMI_PATH}" ]; then
        warn "没有 nvidia-smi，跳过所有压力测试"
        record_test "gpu-runtime-guard" "INCOMPLETE" "" 127 "缺少 nvidia-smi，无法安全启动 GPU 压力测试"
    elif [ "${ALLOW_ACTIVE}" -eq 0 ] && active_gpu_processes; then
        warn "检测到 GPU 正在运行计算进程，默认不启动压力测试"
        record_test "active-process-guard" "INCOMPLETE" "nvidia-smi --query-compute-apps" 2 "检测到活动 GPU 进程；使用 --allow-active 显式允许"
    else
        start_dcgm_health_watch
        run_profile "${PROFILE}"
        finalize_dcgm_health
    fi

    collect_snapshot after
    if command_exists dmesg; then
        run_capture kernel-after dmesg --color=never
    elif command_exists journalctl; then
        run_capture kernel-after journalctl -k -b --no-pager
    else
        : > "${RUN_DIR}/kernel-after.stdout"
    fi
    finalize_report
    success "报告目录: ${RUN_DIR}"
}

main "$@"
