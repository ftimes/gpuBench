#!/usr/bin/env python3
"""Parse V100 health-check artifacts and render stable JSON/Markdown reports.

The shell entrypoint deliberately keeps raw command output.  This module is
responsible for the parts that are awkward to do safely in Bash: parsing CSV
with optional fields, comparing counters, and producing a machine-readable
verdict.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Iterable


# Use decimal megabytes so the hard cap is never above the user's requested
# 100 MB, even on filesystems/tools that report decimal sizes.
DEFAULT_LOG_LIMIT_BYTES = 100_000_000
ANALYSIS_LOG_NAME = "test-log.log"
BRIEF_NAME = "test-brief.md"
LOG_META_NAME = "test-log.meta.json"
GENERATED_NAMES = {
    "result.json",
    "summary.md",
    BRIEF_NAME,
    ANALYSIS_LOG_NAME,
    LOG_META_NAME,
}

STATUS_ORDER = {
    "FAIL": 5,
    "INCOMPLETE": 4,
    "UNKNOWN": 3,
    "WARN": 2,
    "SKIPPED": 1,
    "NOT_APPLICABLE": 0,
    "PASS": 0,
}

NUMBER_RE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def artifact_paths(run_dir: Path) -> list[str]:
    """Return files that can be handed to an offline reviewer."""

    paths: list[str] = []
    for path in run_dir.rglob("*"):
        if not path.is_file():
            continue
        if path.name == "result.json":
            # result.json contains this list and cannot list itself.
            continue
        paths.append(str(path.relative_to(run_dir)))
    return sorted(paths)


class BoundedWriter:
    """Write UTF-8/raw bytes while enforcing a hard byte limit."""

    truncation_marker = (
        b"\n\n[TRUNCATED] test-log.log reached its configured byte limit; "
        b"see result.json and test-log.meta.json for omitted artifacts.\n"
    )

    def __init__(self, path: Path, limit_bytes: int):
        self.path = path
        self.limit_bytes = max(1, int(limit_bytes))
        self.written_bytes = 0
        self.truncated = False
        path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = path.open("wb")

    def add(self, value: str | bytes) -> bool:
        if self.truncated:
            return False
        data = value.encode("utf-8", errors="replace") if isinstance(value, str) else value
        remaining = self.limit_bytes - self.written_bytes
        if len(data) <= remaining:
            self.handle.write(data)
            self.written_bytes += len(data)
            return True
        if remaining > 0:
            marker = self.truncation_marker[:remaining]
            self.handle.write(marker)
            self.written_bytes += len(marker)
        self.truncated = True
        return False

    def close(self) -> None:
        self.handle.flush()
        self.handle.close()


def file_excerpt(path: Path, max_bytes: int) -> bytes:
    """Read a bounded head/tail excerpt without loading a huge file."""

    size = path.stat().st_size
    if size <= max_bytes:
        return path.read_bytes()
    half = max(1, (max_bytes - 96) // 2)
    with path.open("rb") as handle:
        head = handle.read(half)
        handle.seek(max(0, size - half))
        tail = handle.read(half)
    marker = (
        f"\n\n[FILE TRUNCATED] {path.name}: original_size={size} bytes; "
        f"kept_head={len(head)} kept_tail={len(tail)}\n\n"
    ).encode("utf-8")
    return head + marker + tail


def log_candidate_paths(run_dir: Path) -> list[Path]:
    excluded = {".pyc", ".swp", ".tmp", ".rc"}
    candidates: list[Path] = []
    for path in run_dir.rglob("*"):
        if not path.is_file() or path.name in GENERATED_NAMES:
            continue
        if path.suffix.lower() in excluded:
            continue
        try:
            if path.stat().st_size == 0:
                continue
        except OSError:
            continue
        try:
            with path.open("rb") as handle:
                sample = handle.read(4096)
        except OSError:
            continue
        if b"\x00" in sample:
            continue
        candidates.append(path)

    def priority(path: Path) -> tuple[int, str]:
        relative = str(path.relative_to(run_dir))
        if relative.startswith("commands/test-"):
            rank = 0
        elif relative in {"kernel-before.stdout", "kernel-after.stdout"}:
            rank = 1
        elif relative.startswith(("nvlink-", "nvidia-query-", "nvidia-q-", "gpu-verbose-")):
            rank = 2
        elif relative == "telemetry.csv":
            rank = 3
        else:
            rank = 4
        return rank, relative

    return sorted(candidates, key=priority)


def write_analysis_log(run_dir: Path, report: dict[str, Any], limit_bytes: int) -> dict[str, Any]:
    """Create a bounded log optimized for offline analysis.

    The log begins with a structured summary and then appends prioritized raw
    command artifacts.  Large individual files are represented by head/tail
    excerpts, and the aggregate output never exceeds ``limit_bytes``.
    """

    limit_bytes = min(DEFAULT_LOG_LIMIT_BYTES, max(1, int(limit_bytes)))
    log_path = run_dir / ANALYSIS_LOG_NAME
    meta_path = run_dir / LOG_META_NAME
    writer = BoundedWriter(log_path, limit_bytes)
    included_files: list[dict[str, Any]] = []
    skipped_files: list[dict[str, Any]] = []

    writer.add("V100CHECK OFFLINE ANALYSIS LOG v1\n")
    writer.add(f"generated_at={now_iso()}\n")
    writer.add(f"run_id={report.get('run_id', run_dir.name)}\n")
    writer.add(f"profile={report.get('profile', '')}\n")
    writer.add(f"overall={report.get('overall', 'UNKNOWN')}\n")
    writer.add(f"configured_limit_bytes={limit_bytes}\n\n")
    writer.add("[RESULT_JSON]\n")
    writer.add(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    writer.add("\n\n[TEST_RESULTS]\n")
    for test in report.get("tests", []):
        writer.add(
            json.dumps(
                {
                    "id": test.get("id"),
                    "status": test.get("status"),
                    "rc": test.get("rc"),
                    "command": test.get("command"),
                    "note": test.get("note"),
                },
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n"
        )
    writer.add("\n[RAW_ARTIFACTS]\n")

    candidates = log_candidate_paths(run_dir)
    per_file_limit = max(64 * 1024, min(8 * 1024 * 1024, max(64 * 1024, limit_bytes // 16)))
    for path in candidates:
        relative = str(path.relative_to(run_dir))
        try:
            size = path.stat().st_size
            payload = file_excerpt(path, per_file_limit)
        except OSError as exc:
            skipped_files.append({"path": relative, "reason": str(exc)})
            continue
        header = f"\n===== BEGIN {relative} ({size} bytes) =====\n"
        if not writer.add(header):
            skipped_files.append({"path": relative, "reason": "aggregate log limit reached"})
            break
        if not writer.add(payload):
            included_files.append(
                {"path": relative, "original_bytes": size, "excerpt_bytes": len(payload), "aggregate_truncated": True}
            )
            break
        writer.add(f"\n===== END {relative} =====\n")
        included_files.append(
            {"path": relative, "original_bytes": size, "excerpt_bytes": len(payload), "aggregate_truncated": False}
        )

    writer.close()
    metadata = {
        "path": ANALYSIS_LOG_NAME,
        "limit_bytes": limit_bytes,
        "actual_bytes": log_path.stat().st_size if log_path.exists() else 0,
        "truncated": writer.truncated,
        "included_files": included_files,
        "skipped_files": skipped_files,
    }
    write_json(meta_path, metadata)
    return metadata


def normalize_key(value: str) -> str:
    value = value.strip().lower()
    value = value.replace("[", "_").replace("]", "")
    value = value.replace("(", "_").replace(")", "")
    value = value.replace("/", "_")
    value = re.sub(r"[^a-z0-9_.-]+", "_", value)
    value = re.sub(r"_+", "_", value).strip("_")
    return value


def parse_number(value: Any) -> float | int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if not text or text in {"N/A", "Not Supported", "Unknown", "None", "[Not Supported]"}:
        return None
    match = NUMBER_RE.search(text.replace(",", ""))
    if not match:
        return None
    number = float(match.group(0))
    return int(number) if number.is_integer() else number


def parse_bool(value: Any) -> bool | None:
    if value is None:
        return None
    text = str(value).strip().lower()
    if text in {"enabled", "yes", "true", "on", "active", "up"}:
        return True
    if text in {"disabled", "no", "false", "off", "inactive", "down"}:
        return False
    return None


def parse_csv_table(text: str) -> list[dict[str, Any]]:
    """Parse nvidia-smi CSV output, tolerating empty rows and N/A values."""

    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return []
    # nvidia-smi --format=csv,noheader has no header.  The caller can attach
    # an explicit header by passing a first line beginning with "index".
    first = next((line for line in lines if not line.lstrip().startswith("#")), "")
    has_header = "index" in first.lower() and "," in first
    rows: list[dict[str, Any]] = []
    reader = csv.reader(lines)
    parsed = list(reader)
    if not parsed:
        return []
    if has_header:
        headers = [normalize_key(value) for value in parsed[0]]
        data_rows = parsed[1:]
    else:
        headers = []
        data_rows = parsed
    for row in data_rows:
        if not any(cell.strip() for cell in row):
            continue
        if not headers:
            headers = [f"field_{index}" for index in range(len(row))]
        if len(row) < len(headers):
            row = row + [""] * (len(headers) - len(row))
        item: dict[str, Any] = {}
        for index, header in enumerate(headers):
            value = row[index].strip() if index < len(row) else ""
            item[header] = value
        rows.append(item)
    return rows


def parse_named_csv(text: str, headers: Iterable[str]) -> list[dict[str, Any]]:
    header_line = ",".join(headers)
    return parse_csv_table(header_line + "\n" + text)


def first_value(item: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        normalized = normalize_key(key)
        if normalized in item and item[normalized] not in {"", "N/A"}:
            return item[normalized]
    return None


def parse_key_value_lines(text: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = normalize_key(key)
        result[key] = value.strip()
    return result


def recursive_tag_values(element: ET.Element, tag: str) -> list[str]:
    return [
        node.text.strip()
        for node in element.iter()
        if node.tag.rsplit("}", 1)[-1] == tag and node.text and node.text.strip()
    ]


def parse_nvidia_xml(path: Path) -> list[dict[str, Any]]:
    text = read_text(path)
    if not text.strip():
        return []
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return []
    gpu_nodes = [
        node
        for node in root.iter()
        if node.tag.rsplit("}", 1)[-1] == "gpu"
    ]
    gpus: list[dict[str, Any]] = []
    for index, node in enumerate(gpu_nodes):
        def tag(*names: str) -> str | None:
            for name in names:
                values = recursive_tag_values(node, name)
                if values:
                    return values[0]
            return None

        item: dict[str, Any] = {
            "index": index,
            "name": tag("product_name"),
            "uuid": tag("uuid"),
            "serial": tag("serial"),
            "pci_bus_id": tag("pci_bus_id"),
            "vbios_version": tag("vbios_version"),
            "memory_total_mib": parse_number(tag("total")),
            "temperature_c": parse_number(tag("gpu_temp")),
            "power_draw_w": parse_number(tag("power_draw")),
            "power_limit_w": parse_number(tag("power_limit")),
            "ecc_mode_current": tag("current_ecc"),
            "ecc_mode_pending": tag("pending_ecc"),
        }
        gpus.append(item)
    return gpus


def parse_query_snapshot(run_dir: Path, label: str) -> list[dict[str, Any]]:
    core_headers = [
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
    ecc_headers = [
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
    core = parse_named_csv(
        read_text(run_dir / f"nvidia-query-core-{label}.stdout"), core_headers
    )
    ecc = parse_named_csv(
        read_text(run_dir / f"nvidia-query-ecc-{label}.stdout"), ecc_headers
    )
    xml = parse_nvidia_xml(run_dir / f"nvidia-q-{label}.xml")
    by_index: dict[str, dict[str, Any]] = {}
    for item in core:
        index = str(first_value(item, "index") or len(by_index))
        by_index[index] = {
            "index": int(parse_number(index) or len(by_index)),
            "uuid": first_value(item, "uuid"),
            "name": first_value(item, "name"),
            "serial": first_value(item, "serial"),
            "memory_total_mib": parse_number(first_value(item, "memory.total")),
            "memory_used_mib": parse_number(first_value(item, "memory.used")),
            "memory_free_mib": parse_number(first_value(item, "memory.free")),
            "temperature_c": parse_number(first_value(item, "temperature.gpu")),
            "power_draw_w": parse_number(first_value(item, "power.draw")),
            "power_limit_w": parse_number(first_value(item, "power.limit")),
            "sm_clock_mhz": parse_number(first_value(item, "clocks.current.sm")),
            "memory_clock_mhz": parse_number(first_value(item, "clocks.current.memory")),
            "pstate": first_value(item, "pstate"),
            "pcie_link_gen": parse_number(first_value(item, "pcie.link.gen.current")),
            "pcie_link_width": parse_number(first_value(item, "pcie.link.width.current")),
            "utilization_gpu_percent": parse_number(first_value(item, "utilization.gpu")),
            "utilization_memory_percent": parse_number(first_value(item, "utilization.memory")),
        }
    for item in ecc:
        index = str(first_value(item, "index") or len(by_index))
        gpu = by_index.setdefault(
            index,
            {"index": int(parse_number(index) or len(by_index))},
        )
        gpu.update(
            {
                "uuid": gpu.get("uuid") or first_value(item, "uuid"),
                "ecc_mode_current": first_value(item, "ecc.mode.current"),
                "ecc_mode_pending": first_value(item, "ecc.mode.pending"),
                "ecc_corrected_aggregate": parse_number(
                    first_value(item, "ecc.errors.corrected.aggregate.total")
                ),
                "ecc_uncorrected_aggregate": parse_number(
                    first_value(item, "ecc.errors.uncorrected.aggregate.total")
                ),
                "ecc_corrected_volatile": parse_number(
                    first_value(item, "ecc.errors.corrected.volatile.total")
                ),
                "ecc_uncorrected_volatile": parse_number(
                    first_value(item, "ecc.errors.uncorrected.volatile.total")
                ),
                "retired_pages_sbe": parse_number(
                    first_value(item, "retired.pages.single_bit_ecc", "retired_pages.single_bit_ecc")
                ),
                "retired_pages_dbe": parse_number(
                    first_value(item, "retired.pages.double_bit_ecc", "retired_pages.double_bit_ecc")
                ),
                "retired_pages_pending": parse_number(
                    first_value(item, "retired.pages.pending", "retired_pages.pending")
                ),
            }
        )
    for item in xml:
        index = str(item.get("index", len(by_index)))
        gpu = by_index.setdefault(index, {"index": int(parse_number(index) or len(by_index))})
        for key, value in item.items():
            if value is not None and gpu.get(key) in (None, ""):
                gpu[key] = value
    return [by_index[key] for key in sorted(by_index, key=lambda value: int(parse_number(value) or 0))]


def detect_form_factor(name: str | None) -> str:
    text = (name or "").lower()
    if "sxm" in text:
        return "SXM2"
    if "pcie" in text or "pci-e" in text:
        return "PCIe"
    return "unknown"


def nominal_capacity_gib(name: str | None, total_mib: Any) -> float | None:
    text = (name or "").lower().replace(" ", "")
    for size in (16, 32):
        if f"{size}gb" in text:
            return float(size)
    total = parse_number(total_mib)
    if total is None:
        return None
    if 14000 <= float(total) <= 18000:
        return 16.0
    if 28000 <= float(total) <= 35000:
        return 32.0
    return None


def memory_verdict(gpu: dict[str, Any]) -> tuple[str, str]:
    nominal = nominal_capacity_gib(gpu.get("name"), gpu.get("memory_total_mib"))
    actual = parse_number(gpu.get("memory_total_mib"))
    if nominal is None or actual is None:
        return "UNKNOWN", "无法识别 V100 标称容量或 nvidia-smi 未返回显存总量"
    ratio = float(actual) / (nominal * 1024.0)
    gpu["nominal_memory_gib"] = nominal
    gpu["memory_ratio"] = round(ratio, 4)
    if ratio >= 0.90:
        return "PASS", f"实际显存约为标称容量的 {ratio:.1%}"
    if ratio >= 0.80:
        return "WARN", f"实际显存约为标称容量的 {ratio:.1%}，需要人工核对 ECC/驱动预留"
    return "FAIL", f"实际显存约为标称容量的 {ratio:.1%}，低于 80%"


def number_delta(before: Any, after: Any) -> int | float | None:
    before_number = parse_number(before)
    after_number = parse_number(after)
    if before_number is None or after_number is None:
        return None
    delta = float(after_number) - float(before_number)
    return int(delta) if delta.is_integer() else delta


def ecc_verdict(before: dict[str, Any], after: dict[str, Any]) -> tuple[str, str, dict[str, Any]]:
    fields = [
        "ecc_corrected_aggregate",
        "ecc_uncorrected_aggregate",
        "ecc_corrected_volatile",
        "ecc_uncorrected_volatile",
        "retired_pages_sbe",
        "retired_pages_dbe",
        "retired_pages_pending",
    ]
    delta = {field: number_delta(before.get(field), after.get(field)) for field in fields}
    historical_dbe = any(
        (parse_number(before.get(field)) or 0) > 0
        for field in ("ecc_uncorrected_aggregate", "retired_pages_dbe")
    )
    historical_sbe = any(
        (parse_number(before.get(field)) or 0) > 0
        for field in ("ecc_corrected_aggregate", "retired_pages_sbe")
    )
    new_dbe = any(
        (delta.get(field) or 0) > 0
        for field in ("ecc_uncorrected_aggregate", "ecc_uncorrected_volatile", "retired_pages_dbe")
    )
    new_sbe = any(
        (delta.get(field) or 0) > 0
        for field in ("ecc_corrected_aggregate", "ecc_corrected_volatile", "retired_pages_sbe")
    )
    new_pending = (delta.get("retired_pages_pending") or 0) > 0
    mode = str(after.get("ecc_mode_current") or before.get("ecc_mode_current") or "").lower()
    if new_dbe or new_pending or historical_dbe:
        status, reason = "FAIL", "发现 DBE 或页退休/待退休记录"
    elif new_sbe or historical_sbe:
        status, reason = "WARN", "发现 SBE 或 SBE 页退休记录"
    elif mode and mode not in {"enabled", "on", "yes"}:
        status, reason = "WARN", "ECC 当前未启用，显存错误覆盖能力受限"
    elif not mode:
        status, reason = "UNKNOWN", "无法读取 ECC 模式或计数"
    else:
        status, reason = "PASS", "ECC 已启用且测试前后未发现新增错误"
    return status, reason, delta


def parse_nvlink_status(path: Path) -> dict[str, Any]:
    text = read_text(path)
    links: list[dict[str, Any]] = []
    for match in re.finditer(r"(?im)^\s*(?:link\s*)?(\d+)\s*[:=]\s*(up|down|active|inactive)", text):
        links.append({"link": int(match.group(1)), "state": match.group(2).upper()})
    up = sum(1 for item in links if item["state"] in {"UP", "ACTIVE"})
    down = sum(1 for item in links if item["state"] in {"DOWN", "INACTIVE"})
    return {"links": links, "up": up, "down": down, "raw_present": bool(text.strip())}


def parse_error_counters(path: Path) -> dict[str, int]:
    text = read_text(path)
    counters: dict[str, int] = {}
    patterns = {
        "crc": r"(?i)\bcrc(?:\s+error)?\b[^0-9]*([0-9]+)",
        "replay": r"(?i)\breplay(?:\s+error)?\b[^0-9]*([0-9]+)",
        "recovery": r"(?i)\brecovery(?:\s+error)?\b[^0-9]*([0-9]+)",
        "error": r"(?i)\berrors?\b[^0-9]*([0-9]+)",
    }
    for name, pattern in patterns.items():
        values = [int(value) for value in re.findall(pattern, text)]
        if values:
            counters[name] = sum(values)
    return counters


def parse_kernel_lines(path: Path) -> set[str]:
    text = read_text(path)
    lines = set()
    for line in text.splitlines():
        if re.search(r"(?i)\b(?:xid|nvrm|aer|nvlink)\b", line):
            lines.add(line.strip())
    return lines


def parse_telemetry(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"samples": 0, "gpus": {}}
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if not row:
                continue
            rows.append(row)
    by_gpu: dict[str, dict[str, Any]] = {}
    for row in rows:
        index = str(row.get("index", "unknown")).strip()
        item = by_gpu.setdefault(index, {"samples": 0, "max_temperature_c": None, "max_power_w": None, "min_sm_clock_mhz": None})
        item["samples"] += 1
        temperature = parse_number(row.get("temperature.gpu"))
        power = parse_number(row.get("power.draw"))
        sm_clock = parse_number(row.get("clocks.current.sm"))
        if temperature is not None:
            item["max_temperature_c"] = max(item["max_temperature_c"] or temperature, temperature)
        if power is not None:
            item["max_power_w"] = max(item["max_power_w"] or power, power)
        if sm_clock is not None:
            item["min_sm_clock_mhz"] = min(item["min_sm_clock_mhz"] or sm_clock, sm_clock)
    return {"samples": len(rows), "gpus": by_gpu}


def load_test_records(run_dir: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in sorted((run_dir / "tests").glob("*.json")):
        try:
            records.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return records


def load_manifest(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "manifest.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def command_ok(run_dir: Path, name: str) -> bool:
    try:
        rc = int(read_text(run_dir / f"{name}.rc").strip())
    except ValueError:
        return False
    return rc == 0


def combine_statuses(statuses: Iterable[str], strict: bool = False) -> str:
    statuses = list(statuses)
    if "FAIL" in statuses:
        return "FAIL"
    if "INCOMPLETE" in statuses:
        return "INCOMPLETE"
    if strict and "UNKNOWN" in statuses:
        return "INCOMPLETE"
    if "UNKNOWN" in statuses:
        return "UNKNOWN"
    if "WARN" in statuses:
        return "WARN"
    return "PASS"


def build_gpu_results(run_dir: Path, strict: bool) -> list[dict[str, Any]]:
    before = parse_query_snapshot(run_dir, "before")
    after = parse_query_snapshot(run_dir, "after")
    before_core_ok = command_ok(run_dir, "nvidia-query-core-before")
    after_core_ok = command_ok(run_dir, "nvidia-query-core-after")
    before_ecc_ok = command_ok(run_dir, "nvidia-query-ecc-before")
    after_ecc_ok = command_ok(run_dir, "nvidia-query-ecc-after")
    before_by_key = {str(item.get("index")): item for item in before}
    after_by_key = {str(item.get("index")): item for item in after}
    results: list[dict[str, Any]] = []
    for index in sorted(set(before_by_key) | set(after_by_key), key=lambda value: int(parse_number(value) or 0)):
        before_gpu = before_by_key.get(index, {})
        after_gpu = after_by_key.get(index, before_gpu)
        current = dict(after_gpu or before_gpu)
        current["index"] = int(parse_number(index) or 0)
        current["form_factor"] = detect_form_factor(current.get("name") or before_gpu.get("name"))
        if not after_core_ok:
            memory_status, memory_reason = "UNKNOWN", "测试后 nvidia-smi GPU 快照失败"
        else:
            memory_status, memory_reason = memory_verdict(current)
        if not before_ecc_ok or not after_ecc_ok:
            ecc_status, ecc_reason, ecc_delta = (
                "UNKNOWN",
                "测试前或测试后 ECC 查询失败，无法可靠计算增量",
                {},
            )
        else:
            ecc_status, ecc_reason, ecc_delta = ecc_verdict(before_gpu, after_gpu)
        nvlink_status = parse_nvlink_status(run_dir / "nvlink-status-after.stdout")
        nvlink_before = parse_error_counters(run_dir / "nvlink-errors-before.stdout")
        nvlink_after = parse_error_counters(run_dir / "nvlink-errors-after.stdout")
        nvlink_delta = {
            key: number_delta(nvlink_before.get(key), nvlink_after.get(key))
            for key in set(nvlink_before) | set(nvlink_after)
        }
        if current["form_factor"] == "PCIe":
            link_status, link_reason = "NOT_APPLICABLE", "PCIe V100 不要求 NVLink"
        elif not command_ok(run_dir, "nvlink-status-after"):
            link_status, link_reason = "UNKNOWN", "NVLink 状态查询失败"
        elif not command_ok(run_dir, "nvlink-errors-after"):
            link_status, link_reason = "UNKNOWN", "NVLink 错误计数查询失败"
        elif nvlink_status.get("raw_present"):
            if nvlink_status.get("down", 0) > 0:
                link_status, link_reason = "FAIL", "检测到 Down/Inactive NVLink 链路"
            elif any((value or 0) > 0 for value in nvlink_delta.values()):
                link_status, link_reason = "FAIL", "测试期间 NVLink 错误计数增加"
            elif nvlink_status.get("up", 0) > 0:
                link_status, link_reason = "PASS", "检测到活动 NVLink 链路且错误计数未增加"
            else:
                link_status, link_reason = "UNKNOWN", "发现 NVLink 查询结果但无法确认活动链路"
        else:
            link_status, link_reason = "UNKNOWN", "无法读取 NVLink 状态"
        current["memory"] = {"status": memory_status, "reason": memory_reason}
        current["ecc"] = {"status": ecc_status, "reason": ecc_reason, "delta": ecc_delta}
        current["nvlink"] = {
            "status": link_status,
            "reason": link_reason,
            "status_snapshot": nvlink_status,
            "error_delta": nvlink_delta,
        }
        current["status"] = combine_statuses([memory_status, ecc_status, link_status], strict)
        results.append(current)
    return results


def build_report(run_dir: Path, profile: str, strict: bool) -> dict[str, Any]:
    manifest = load_manifest(run_dir)
    tests = load_test_records(run_dir)
    gpus = build_gpu_results(run_dir, strict)
    telemetry = parse_telemetry(run_dir / "telemetry.csv")
    before_kernel = parse_kernel_lines(run_dir / "kernel-before.stdout")
    after_kernel = parse_kernel_lines(run_dir / "kernel-after.stdout")
    new_kernel = sorted(after_kernel - before_kernel)
    warning_temp = float(manifest.get("warn_temp", 75))
    abort_temp = float(manifest.get("max_temp", 82))
    telemetry_status = "PASS"
    telemetry_reasons: list[str] = []
    for index, values in telemetry.get("gpus", {}).items():
        max_temp = values.get("max_temperature_c")
        if max_temp is not None and float(max_temp) >= abort_temp:
            telemetry_status = "FAIL"
            telemetry_reasons.append(f"GPU {index} 最高温度 {max_temp}°C 达到停止阈值")
        elif max_temp is not None and float(max_temp) >= warning_temp and telemetry_status != "FAIL":
            telemetry_status = "WARN"
            telemetry_reasons.append(f"GPU {index} 最高温度 {max_temp}°C 达到警戒阈值")
    if new_kernel:
        telemetry_status = "FAIL"
        telemetry_reasons.append(f"测试期间新增 {len(new_kernel)} 条 Xid/AER/NVLink 内核错误")
    if telemetry.get("samples", 0) == 0:
        telemetry_status = "SKIPPED" if profile == "probe" else "UNKNOWN"
        telemetry_reasons.append("当前档位没有运行压力采样")
    tests.append(
        {
            "id": "telemetry",
            "status": telemetry_status,
            "command": "background nvidia-smi sampler",
            "rc": 0 if telemetry_status in {"PASS", "WARN"} else 1,
            "note": "; ".join(telemetry_reasons) or "温度、功耗和时钟采样正常",
            "details": {"summary": telemetry},
        }
    )
    gpu_statuses = [gpu.get("status", "UNKNOWN") for gpu in gpus]
    test_statuses = [str(test.get("status", "UNKNOWN")) for test in tests]
    overall = combine_statuses(gpu_statuses + test_statuses, strict)
    if not gpus:
        overall = "UNKNOWN" if profile == "probe" else "INCOMPLETE"
    report = {
        "schema_version": 1,
        "run_id": manifest.get("run_id", run_dir.name),
        "started_at": manifest.get("started_at"),
        "ended_at": now_iso(),
        "profile": profile,
        "host": {
            "platform": manifest.get("platform"),
            "hostname": manifest.get("hostname"),
            "kernel": manifest.get("kernel"),
        },
        "software": manifest.get("software", {}),
        "configuration": {
            "warn_temp_c": warning_temp,
            "max_temp_c": abort_temp,
            "memory_percent": manifest.get("memory_percent"),
            "log_limit_mb": manifest.get("log_limit_mb", 100),
            "gpu_selection": manifest.get("gpu_selection", "all"),
            "duration": manifest.get("duration"),
            "postcheck_duration": manifest.get("postcheck_duration"),
            "strict": strict,
        },
        "gpus": gpus,
        "tests": tests,
        "kernel_errors": {
            "before_count": len(before_kernel),
            "after_count": len(after_kernel),
            "new": new_kernel,
        },
        "artifacts": artifact_paths(run_dir),
        "overall": overall,
    }
    return report


def render_markdown(report: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# V100 服务器健康检查报告")
    lines.append("")
    lines.append(f"- 运行 ID：`{report.get('run_id', '')}`")
    lines.append(f"- 测试档位：`{report.get('profile', '')}`")
    lines.append(f"- 开始时间：`{report.get('started_at', '')}`")
    lines.append(f"- 结束时间：`{report.get('ended_at', '')}`")
    lines.append(f"- 总体结果：**{report.get('overall', 'UNKNOWN')}**")
    configuration = report.get("configuration", {})
    if configuration.get("duration"):
        lines.append(f"- 主烤机时长：`{configuration.get('duration')}`")
    if configuration.get("postcheck_duration"):
        lines.append(f"- 后置复核时长：`{configuration.get('postcheck_duration')}`")
    lines.append("")
    if not report.get("gpus"):
        lines.append("未识别到 NVIDIA GPU，硬件相关检查未完成。")
        lines.append("")
    else:
        lines.append("## GPU 概览")
        lines.append("")
        lines.append("| GPU | 型号 | 形态 | 显存 | 温度 | ECC | NVLink | 结果 |")
        lines.append("|---:|---|---|---:|---:|---|---|---|")
        for gpu in report["gpus"]:
            memory = gpu.get("memory_total_mib")
            memory_text = f"{float(memory) / 1024:.1f} GiB" if memory is not None else "N/A"
            temp = f"{gpu.get('temperature_c')}°C" if gpu.get("temperature_c") is not None else "N/A"
            lines.append(
                "| {index} | {name} | {form} | {memory} | {temp} | {ecc} | {nvlink} | {status} |".format(
                    index=gpu.get("index", "?"),
                    name=gpu.get("name") or "unknown",
                    form=gpu.get("form_factor", "unknown"),
                    memory=memory_text,
                    temp=temp,
                    ecc=gpu.get("ecc", {}).get("status", "UNKNOWN"),
                    nvlink=gpu.get("nvlink", {}).get("status", "UNKNOWN"),
                    status=gpu.get("status", "UNKNOWN"),
                )
            )
        lines.append("")
    lines.append("## 测试结果")
    lines.append("")
    lines.append("| 测试 | 状态 | 说明 |")
    lines.append("|---|---|---|")
    for test in report.get("tests", []):
        note = str(test.get("note", "")).replace("|", "\\|").replace("\n", " ")
        lines.append(f"| `{test.get('id', '')}` | {test.get('status', 'UNKNOWN')} | {note} |")
    lines.append("")
    if report.get("kernel_errors", {}).get("new"):
        lines.append("## 新增内核错误")
        lines.append("")
        for error in report["kernel_errors"]["new"]:
            lines.append(f"- `{error}`")
        lines.append("")
    lines.append("## 说明")
    lines.append("")
    lines.append("原始命令输出、遥测采样和前后快照保存在同一运行目录中，可用于二手设备留档和复核。")
    logging = report.get("logging")
    if logging:
        lines.append("")
        lines.append("## 离线分析文件")
        lines.append("")
        lines.append(
            f"- 测试日志：`{logging.get('path', ANALYSIS_LOG_NAME)}`，"
            f"{logging.get('actual_bytes', 0)} / {logging.get('limit_bytes', 0)} bytes"
        )
        lines.append(f"- 是否发生截断：`{logging.get('truncated', False)}`")
        lines.append(f"- 测试简报：`{BRIEF_NAME}`")
    return "\n".join(lines) + "\n"


def command_record(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    tests_dir = run_dir / "tests"
    tests_dir.mkdir(parents=True, exist_ok=True)
    write_json(
        tests_dir / f"{args.id}.json",
        {
            "id": args.id,
            "status": args.status,
            "command": args.command,
            "rc": args.rc,
            "note": args.note,
            "details": {},
        },
    )
    return 0


def finalize_command(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    report = build_report(run_dir, args.profile, args.strict)
    # Write the brief before collecting raw artifacts so it is available for
    # the bounded analysis log, then rewrite it with the final log metadata.
    initial_brief = render_markdown(report)
    (run_dir / "summary.md").write_text(initial_brief, encoding="utf-8")
    (run_dir / BRIEF_NAME).write_text(initial_brief, encoding="utf-8")
    report["logging"] = write_analysis_log(
        run_dir,
        report,
        args.log_limit_mb * 1_000_000,
    )
    report["artifacts"] = artifact_paths(run_dir)
    final_brief = render_markdown(report)
    (run_dir / "summary.md").write_text(final_brief, encoding="utf-8")
    (run_dir / BRIEF_NAME).write_text(final_brief, encoding="utf-8")
    write_json(run_dir / "result.json", report)
    print(json.dumps({"overall": report["overall"], "result": str(run_dir / "result.json")}, ensure_ascii=False))
    return 0


def self_test_command(_: argparse.Namespace) -> int:
    cases = [
        (
            "Tesla V100-PCIE-16GB",
            "PCIe",
            "PASS",
        ),
        (
            "Tesla V100-SXM2-32GB",
            "SXM2",
            "PASS",
        ),
    ]
    failures = []
    for name, expected_form, expected_memory in cases:
        gpu = {"name": name, "memory_total_mib": 16384 if "16GB" in name else 32768}
        if detect_form_factor(name) != expected_form:
            failures.append(f"form factor: {name}")
        status, _ = memory_verdict(gpu)
        if status != expected_memory:
            failures.append(f"memory: {name}")
    before = {"ecc_corrected_aggregate": "0", "ecc_uncorrected_aggregate": "0", "ecc_mode_current": "Enabled"}
    after = dict(before)
    status, _, _ = ecc_verdict(before, after)
    if status != "PASS":
        failures.append("ecc pass")
    after["ecc_uncorrected_aggregate"] = "1"
    status, _, _ = ecc_verdict(before, after)
    if status != "FAIL":
        failures.append("ecc dbe fail")
    if failures:
        print("self-test failed: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    record = subparsers.add_parser("record-test")
    record.add_argument("--run-dir", required=True)
    record.add_argument("--id", required=True)
    record.add_argument("--status", required=True)
    record.add_argument("--command", default="")
    record.add_argument("--rc", type=int, default=0)
    record.add_argument("--note", default="")
    record.set_defaults(func=command_record)

    finalize = subparsers.add_parser("finalize")
    finalize.add_argument("--run-dir", required=True)
    finalize.add_argument("--profile", required=True)
    finalize.add_argument("--strict", action="store_true")
    finalize.add_argument("--log-limit-mb", type=int, default=100)
    finalize.set_defaults(func=finalize_command)

    self_test = subparsers.add_parser("self-test")
    self_test.set_defaults(func=self_test_command)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
