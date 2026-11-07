#!/usr/bin/env python3
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import report


CORE_HEADERS = [
    "index",
    "uuid",
    "name",
    "serial",
    "memory.total",
    "memory.used",
    "memory.free",
    "temperature.gpu",
    "power.draw",
    "power.limit",
    "clocks.current.sm",
    "clocks.current.memory",
    "pstate",
    "pcie.link.gen.current",
    "pcie.link.width.current",
    "utilization.gpu",
    "utilization.memory",
]

ECC_HEADERS = [
    "index",
    "uuid",
    "ecc.mode.current",
    "ecc.mode.pending",
    "ecc.errors.corrected.aggregate.total",
    "ecc.errors.uncorrected.aggregate.total",
    "ecc.errors.corrected.volatile.total",
    "ecc.errors.uncorrected.volatile.total",
    "retired_pages.single_bit_ecc",
    "retired_pages.double_bit_ecc",
    "retired_pages.pending",
]


def write_snapshot(run_dir: Path, label: str, *, dbe: int = 0, temp: int = 65) -> None:
    (run_dir / f"nvidia-query-core-{label}.stdout").write_text(
        ",".join(
            [
                "0",
                "GPU-TEST",
                "Tesla V100-PCIE-16GB",
                "SERIAL",
                "16384",
                "128",
                "16256",
                str(temp),
                "100",
                "250",
                "1380",
                "877",
                "P0",
                "3",
                "16",
                "0",
                "0",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (run_dir / f"nvidia-query-ecc-{label}.stdout").write_text(
        ",".join(
            [
                "0",
                "GPU-TEST",
                "Enabled",
                "Enabled",
                "0",
                str(dbe),
                "0",
                str(dbe),
                "0",
                str(dbe),
                "0",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (run_dir / f"nvidia-q-{label}.xml").write_text("<nvidia_smi_log/>", encoding="utf-8")
    (run_dir / f"nvidia-query-core-{label}.rc").write_text("0\n", encoding="utf-8")
    (run_dir / f"nvidia-query-ecc-{label}.rc").write_text("0\n", encoding="utf-8")
    (run_dir / f"nvlink-status-{label}.rc").write_text("0\n", encoding="utf-8")
    (run_dir / f"nvlink-errors-{label}.rc").write_text("0\n", encoding="utf-8")


class ReportTest(unittest.TestCase):
    def test_pcie_v100_without_nvlink_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            write_snapshot(run_dir, "before")
            write_snapshot(run_dir, "after")
            (run_dir / "nvlink-status-after.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-before.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-after.stdout").write_text("", encoding="utf-8")
            gpu = report.build_gpu_results(run_dir, strict=False)[0]
            self.assertEqual(gpu["form_factor"], "PCIe")
            self.assertEqual(gpu["memory"]["status"], "PASS")
            self.assertEqual(gpu["ecc"]["status"], "PASS")
            self.assertEqual(gpu["nvlink"]["status"], "NOT_APPLICABLE")
            self.assertEqual(gpu["status"], "PASS")

    def test_new_dbe_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            write_snapshot(run_dir, "before", dbe=0)
            write_snapshot(run_dir, "after", dbe=1)
            gpu = report.build_gpu_results(run_dir, strict=False)[0]
            self.assertEqual(gpu["ecc"]["status"], "FAIL")
            self.assertEqual(gpu["status"], "FAIL")

    def test_sxm2_nvlink_down_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            write_snapshot(run_dir, "before")
            write_snapshot(run_dir, "after")
            for label in ("before", "after"):
                path = run_dir / f"nvidia-query-core-{label}.stdout"
                text = path.read_text(encoding="utf-8")
                text = text.replace("Tesla V100-PCIE-16GB", "Tesla V100-SXM2-32GB")
                text = text.replace(", 16384,", ", 32768,").replace(", 16256,", ", 32640,")
                path.write_text(text, encoding="utf-8")
            (run_dir / "nvlink-status-after.stdout").write_text("Link 0: Down\n", encoding="utf-8")
            (run_dir / "nvlink-errors-before.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-after.stdout").write_text("", encoding="utf-8")
            gpu = report.build_gpu_results(run_dir, strict=False)[0]
            self.assertEqual(gpu["form_factor"], "SXM2")
            self.assertEqual(gpu["nvlink"]["status"], "FAIL")

    def test_temperature_limit_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            write_snapshot(run_dir, "before", temp=65)
            write_snapshot(run_dir, "after", temp=65)
            (run_dir / "manifest.json").write_text(
                json.dumps(
                    {
                        "run_id": "test",
                        "started_at": "2026-11-02T00:00:00Z",
                        "platform": "Linux",
                        "warn_temp": 80,
                        "max_temp": 85,
                        "memory_percent": 80,
                    }
                ),
                encoding="utf-8",
            )
            (run_dir / "telemetry.csv").write_text(
                "timestamp,index,uuid,temperature.gpu,power.draw,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,pstate\n"
                "2026-11-02T00:00:01Z,0,GPU-TEST,86,200,1300,800,100,90,P0\n",
                encoding="utf-8",
            )
            (run_dir / "nvlink-status-after.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-before.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-after.stdout").write_text("", encoding="utf-8")
            result = report.build_report(run_dir, "medium", strict=False)
            telemetry = next(item for item in result["tests"] if item["id"] == "telemetry")
            self.assertEqual(telemetry["status"], "FAIL")
            self.assertEqual(result["overall"], "FAIL")

    def test_analysis_log_respects_hard_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            write_snapshot(run_dir, "before")
            write_snapshot(run_dir, "after")
            (run_dir / "nvlink-status-after.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-before.stdout").write_text("", encoding="utf-8")
            (run_dir / "nvlink-errors-after.stdout").write_text("", encoding="utf-8")
            (run_dir / "commands").mkdir()
            (run_dir / "commands" / "test-large.stdout").write_text("x" * 300_000, encoding="utf-8")
            report_data = {
                "schema_version": 1,
                "run_id": "log-limit",
                "profile": "medium",
                "overall": "PASS",
                "tests": [],
                "gpus": [],
            }
            metadata = report.write_analysis_log(run_dir, report_data, 64 * 1024)
            log_size = (run_dir / report.ANALYSIS_LOG_NAME).stat().st_size
            self.assertLessEqual(log_size, 64 * 1024)
            self.assertEqual(metadata["actual_bytes"], log_size)
            self.assertTrue(metadata["truncated"])


if __name__ == "__main__":
    unittest.main()
