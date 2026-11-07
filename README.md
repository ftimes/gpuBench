# gpuBench

gpuBench.sh 是把 LemonBench 和 LeGeekbench 合并后的 Linux 服务器基准测试脚本。

保留的测试内容：

- CPU、缓存、内存、Swap、根分区、操作系统和内核信息
- FIO 磁盘随机读写：4K、128K，队列深度 32
- Geekbench 5、6、7 CPU 跑分，可选择一个版本或显式运行多个版本
- 本地文本报告

合并时只保留 Geekbench 作为 CPU 性能测试引擎，避免同时运行两套 CPU 跑分。脚本不会执行网络性能或内容检查。下载 Geekbench 和可选上传官方结果仍需要网络；使用 --no-upload 可以关闭结果上传，使用 --geekbench none 可以只运行系统信息和磁盘测试。

## 使用

~~~bash
chmod +x gpuBench.sh

# 快速模式，默认运行 Geekbench 6
./gpuBench.sh --fast

# 完整磁盘测试并运行 Geekbench 7
./gpuBench.sh --full --geekbench 7

# 依次运行 Geekbench 5、6、7，不上传结果
./gpuBench.sh --geekbench all --no-upload

# 只做系统信息和磁盘测试
./gpuBench.sh --geekbench none

# 只跑 Geekbench，不跑磁盘测试
./gpuBench.sh --no-disk --geekbench 6
~~~

## 要求

- 64 位 Linux，支持 x86_64、aarch64 和 riscv64
- 磁盘测试需要 fio
- Geekbench 测试需要 curl 和 tar
- 缺少依赖时，脚本会尝试通过 apt-get、dnf 或 yum 安装
- Geekbench 版本有最低内存要求；低内存机器可显式加 --auto-swap 创建临时 Swap，退出时自动清理

脚本默认把临时文件放到当前目录的 .gpuBench-workdir，把报告保存为当前目录的 gpuBench-report-*.txt。

## V100 服务器验机

二手 NVIDIA V100 的验机、显存、ECC、NVLink 和压力测试流程位于
[`v100check/`](v100check/)，与通用 CPU/磁盘基准
分开维护。

```bash
cd v100check
./v100check.sh --profile probe
./v100check.sh --profile medium --duration 30m
./v100check.sh --profile long --duration 8h
```

该工具默认只读，长时间烤机必须显式启用；缺少 DCGM、`nvbandwidth` 或其他可选工具
时会在 JSON 和 Markdown 报告中记录 `SKIPPED`/`UNKNOWN`，不会伪造通过。每次运行还会在
默认报告目录中保存 `test-brief.md` 和不超过 100 MB 的 `test-log.log`，方便离线带回分析。
`long --duration 24h` 表示 24 小时 `gpu-burn` 主烤机，结束后默认再做 5 分钟
显存和数据路径复核；默认温度警戒/停止阈值为 75°C/82°C，可用参数覆盖。

## 项目来源

通用基准脚本整合了 [LemonBench](https://github.com/LemonBench/LemonBench) 和
[LeGeekbench](https://github.com/itbulu/LeGeekbench) 的测试流程。上游说明及许可证见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
