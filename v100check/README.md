# v100check

`v100check.sh` 是面向二手 NVIDIA V100 服务器的只读优先验机工具。它把
`nvidia-smi`、NVIDIA DCGM Diagnostics、`nvbandwidth`、`gpu-burn`、
`cuda_memtest` 和可选的 NVIDIA GPUStressTest 串成一套流程，并为每次运行保留
原始命令输出、前后计数、遥测采样和最终判定。

当前版本支持以下档位：

- `probe`：采集操作系统、驱动、CUDA、GPU、ECC、页退休、PCIe 和 NVLink 基线。
- `fast`：运行 DCGM Level 2 或可用的等效诊断，适合首次接入服务器时快检。
- `medium`：运行 DCGM Level 3 和可用的 GPU 间带宽测试。
- `long`：显式启用 `gpu-burn` 主烤机，并在结束后用 `cuda_memtest` 和可选
  GPUStressTest 做短时复核。
- `all`：运行 `probe + fast + medium`，不会隐式执行长时间烤机。

## 使用

```bash
chmod +x v100check.sh

# 只读基线
sudo ./v100check.sh --profile probe

# 快检
sudo ./v100check.sh --profile fast

# 20–30 分钟中等压力
sudo ./v100check.sh --profile medium --duration 30m

# 8 小时长烤机；长烤机必须显式指定
sudo ./v100check.sh --profile long --duration 8h

# 24 小时主烤机，结束后默认再做 5 分钟显存/数据路径复核
sudo ./v100check.sh --profile long --duration 24h --postcheck-duration 5m

# 只测试指定 GPU。该选项通过 CUDA_VISIBLE_DEVICES 传递给外部测试工具。
sudo ./v100check.sh --profile medium --gpu 0,1
```

报告默认保存到当前目录的 `v100check-reports/`，每次运行一个独立目录：

```text
v100check-reports/20261102-153000-12345/
├── result.json
├── summary.md
├── test-brief.md
├── test-log.log
├── test-log.meta.json
├── manifest.json
├── telemetry.csv
├── commands/
├── tests/
└── logs/
```

其中：

- `test-brief.md` 是适合快速阅读和带回来的测试简报。
- `test-log.log` 是面向离线分析的汇总日志，先写入结构化结果，再按优先级附加原始命令输出。
- `test-log.meta.json` 记录日志实际大小、上限、是否截断以及被纳入/跳过的原始文件。
- 日志默认上限为 100 MB（100,000,000 bytes），硬上限不会超过 100 MB；达到上限后保留摘要并截断低优先级原始输出。
- `test-log.log` 是离线分析汇总文件的硬上限；`commands/`、`logs/` 和其他原始目录
  为完整留档，合计大小可能超过 100 MB。

可以通过参数降低日志上限，但不能提高到 100 MB 以上：

```bash
./v100check.sh --profile medium --log-limit-mb 50
```

`result.json` 使用 `schema_version: 1`，状态值包括：

```text
PASS WARN FAIL SKIPPED UNKNOWN NOT_APPLICABLE INCOMPLETE
```

## 依赖和降级行为

必须依赖：

- Linux 64 位服务器
- Bash
- Python 3 标准库
- NVIDIA 驱动提供的 `nvidia-smi`

可选依赖：

- `dcgmi`
- `nvbandwidth`
- `gpu_burn`
- `cuda_memtest`
- NVIDIA GPUStressTest
- `lspci`、`numactl`、`journalctl`

脚本不会默认安装或升级驱动、CUDA、DCGM，也不会自动开启 ECC、持久化模式、
功耗限制或时钟锁定。`--install-deps` 只会显式安装 `python3` 和 `pciutils`；
NVIDIA 驱动和 CUDA 需要按服务器环境单独准备。

缺少某个可选工具时，相关测试会写入 `SKIPPED` 或 `UNKNOWN`，不会伪造
`PASS`。V100 的 CUDA 测试程序建议使用 CUDA 12.x 或更早版本构建，以保留
Volta `sm_70` 支持。

## 判定口径

- PCIe V100 没有 NVLink 时，NVLink 章节为 `NOT_APPLICABLE`。
- 测试前已有 SBE 或 SBE 页退休为 `WARN`。
- 测试前已有 DBE、DBE 页退休或待退休页为 `FAIL`。
- 测试期间新增 DBE、页退休、Xid 或 NVLink 错误为 `FAIL`。
- ECC 关闭单独报告为 `WARN`，不会被解释成“没有 ECC 错误”。
- 长时间运行默认温度警戒为 75°C、停止为 82°C，可通过参数覆盖。V100 PCIe
  在开放机箱或高风量环境下可以按实际散热条件调整，但不建议盲目放宽阈值。
- `--duration` 只控制 `gpu-burn` 主烤机时长；`--postcheck-duration` 控制结束后的
  显存和数据路径复核。比如 `--duration 24h` 默认总耗时约为 24 小时加上最多
  10 分钟复核和收尾时间，不会把 24 小时重复施加给每个后置工具。
- 有 `dcgmi` 时，压力阶段会启用 DCGM Health Watch，并在结束、异常或中断时执行
  `health --check` 和 `health --clear`；清理失败会写入报告，便于人工确认。

## 本地自测

当前开发环境没有 NVIDIA GPU，仍可以验证解析器和判定逻辑：

```bash
./v100check.sh --self-test
python3 lib/report.py self-test
```

真实 DCGM、CUDA、ECC、NVLink 和长时间烤机验收需要在目标 Linux V100
服务器上运行。
