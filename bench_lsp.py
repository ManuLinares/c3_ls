#!/usr/bin/env python3
"""
c3_ls Performance, Latency & Reliability Benchmarking Harness.

Profiles end-to-end response distributions, throughput, memory stability (RSS),
and SLA compliance across project files.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

DEFAULT_SERVER_BIN = os.path.join(os.path.dirname(__file__), "build", "c3_ls")
DEFAULT_PROJECT_ROOT = os.path.abspath(os.path.dirname(__file__))


# ============================================================================
# Protocol & Server Session
# ============================================================================

def encode_lsp(obj: dict[str, Any]) -> bytes:
    body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


class LspSession:
    """Manages an active LSP server process and its JSON-RPC communication."""

    def __init__(self, binary_path: str, workspace_root: str):
        if not os.path.isfile(binary_path):
            raise FileNotFoundError(f"LSP server binary not found at '{binary_path}'. Run 'c3c build' first.")

        self.proc = subprocess.Popen(
            [binary_path, "--log-level", "error"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,  # Prevent server debug chatter from polluting bench output
        )
        self.response_queue: queue.Queue[dict[str, Any]] = queue.Queue()
        self.msg_id = 0
        self.running = True

        self.reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.reader_thread.start()

        root_uri = Path(workspace_root).as_uri()
        self.request("initialize", {
            "processId": os.getpid(),
            "rootUri": root_uri,
            "capabilities": {},
        })
        self.notify("initialized", {})

    def _reader_loop(self):
        stdout = self.proc.stdout
        while self.running:
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                ch = stdout.read(1)
                if not ch:
                    self.running = False
                    return
                header += ch

            content_length = None
            for line in header.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    content_length = int(line.split(b":")[1].strip())

            if content_length is None:
                continue

            body = stdout.read(content_length)
            if not body:
                self.running = False
                return

            try:
                msg = json.loads(body.decode("utf-8"))
                if "id" in msg and msg["id"] is not None:
                    self.response_queue.put(msg)
            except Exception:
                pass

    def notify(self, method: str, params: dict[str, Any]):
        payload = {"jsonrpc": "2.0", "method": method, "params": params}
        try:
            self.proc.stdin.write(encode_lsp(payload))
            self.proc.stdin.flush()
        except Exception:
            pass

    def request(self, method: str, params: dict[str, Any], timeout: float = 10.0) -> tuple[dict[str, Any] | None, float, bool]:
        """Returns: (response_payload, latency_ms, success)"""
        self.msg_id += 1
        req_id = self.msg_id
        payload = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params,
        }

        t0 = time.perf_counter_ns()
        try:
            self.proc.stdin.write(encode_lsp(payload))
            self.proc.stdin.flush()
        except Exception:
            return None, 0.0, False

        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.response_queue.get(timeout=0.05)
                if msg.get("id") == req_id:
                    lat_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
                    return msg, lat_ms, True
                self.response_queue.put(msg)
            except queue.Empty:
                pass

        lat_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        return None, lat_ms, False

    def open_document(self, uri: str, content: str, language_id: str = "c3", version: int = 1):
        self.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": language_id,
                "version": version,
                "text": content,
            }
        })

    def change_document(self, uri: str, content: str, version: int = 2):
        self.notify("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": content}],
        })

    def close_document(self, uri: str):
        self.notify("textDocument/didClose", {
            "textDocument": {"uri": uri}
        })

    def get_rss_kb(self) -> int:
        pid = self.proc.pid
        # Linux
        try:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1])
        except Exception:
            pass

        # macOS / BSD
        try:
            out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)])
            return int(out.strip())
        except Exception:
            pass

        return 0

    def close(self):
        try:
            self.request("shutdown", {}, timeout=1.0)
            self.notify("exit", {})
            self.proc.wait(timeout=1.0)
        except Exception:
            self.proc.kill()


# ============================================================================
# Telemetry & Workload Definition
# ============================================================================

@dataclass
class SourceTarget:
    path: str
    rel_path: str
    uri: str
    content: str
    line_count: int
    char_count: int


@dataclass
class EndpointDef:
    name: str
    method: str
    make_params: Callable[[SourceTarget], dict[str, Any]]


def build_endpoints() -> list[EndpointDef]:
    return [
        EndpointDef(
            name="completion",
            method="textDocument/completion",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "position": {"line": max(1, f.line_count // 2), "character": 4},
            },
        ),
        EndpointDef(
            name="hover",
            method="textDocument/hover",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "position": {"line": max(1, f.line_count // 2), "character": 5},
            },
        ),
        EndpointDef(
            name="definition",
            method="textDocument/definition",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "position": {"line": max(1, f.line_count // 2), "character": 5},
            },
        ),
        EndpointDef(
            name="signatureHelp",
            method="textDocument/signatureHelp",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "position": {"line": max(1, f.line_count // 2), "character": 10},
            },
        ),
        EndpointDef(
            name="references",
            method="textDocument/references",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "position": {"line": max(1, f.line_count // 2), "character": 5},
                "context": {"includeDeclaration": True},
            },
        ),
        EndpointDef(
            name="inlayHint",
            method="textDocument/inlayHint",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "range": {"start": {"line": 0, "character": 0}, "end": {"line": f.line_count, "character": 0}},
            },
        ),
        EndpointDef(
            name="documentSymbol",
            method="textDocument/documentSymbol",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri}
            },
        ),
        EndpointDef(
            name="workspaceSymbol",
            method="workspace/symbol",
            make_params=lambda _: {"query": "parse"},
        ),
        EndpointDef(
            name="semanticTokens",
            method="textDocument/semanticTokens/full",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri}
            },
        ),
        EndpointDef(
            name="foldingRange",
            method="textDocument/foldingRange",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri}
            },
        ),
        EndpointDef(
            name="formatting",
            method="textDocument/formatting",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "options": {"tabSize": 4, "insertSpaces": False},
            },
        ),
        EndpointDef(
            name="rangeFormatting",
            method="textDocument/rangeFormatting",
            make_params=lambda f: {
                "textDocument": {"uri": f.uri},
                "range": {
                    "start": {"line": max(0, (f.line_count // 2) - 10), "character": 0},
                    "end": {"line": min(f.line_count - 1, (f.line_count // 2) + 10), "character": 0},
                },
                "options": {"tabSize": 4, "insertSpaces": False},
            },
        ),
    ]


def load_project_files(root: str) -> list[SourceTarget]:
    targets = []
    for p in Path(root).rglob("*.c3"):
        if "build" in p.parts:
            continue
        try:
            content = p.read_text(encoding="utf-8", errors="ignore")
            lines = content.splitlines()
            if lines:
                targets.append(SourceTarget(
                    path=str(p),
                    rel_path=str(p.relative_to(root)),
                    uri=p.as_uri(),
                    content=content,
                    line_count=len(lines),
                    char_count=len(content),
                ))
        except Exception:
            pass
    return targets


def compute_distribution(samples: list[float]) -> dict[str, float]:
    if not samples:
        return {"min": 0, "mean": 0, "p50": 0, "p90": 0, "p95": 0, "p99": 0, "max": 0, "count": 0}
    s = sorted(samples)
    n = len(s)

    def pct(q: float) -> float:
        return s[min(int(n * q), n - 1)]

    return {
        "count": n,
        "min": s[0],
        "mean": sum(s) / n,
        "p50": pct(0.50),
        "p90": pct(0.90),
        "p95": pct(0.95),
        "p99": pct(0.99),
        "max": s[-1],
    }


def make_churn_source(iteration: int) -> str:
    return (
        f"module bench_{iteration % 5};\n"
        "import std::io;\n\n"
        "struct Vector2 { float x; float y; }\n"
        "fn Vector2 Vector2.add(&self, Vector2 other) {\n"
        "  return { .x = self.x + other.x, .y = self.y + other.y };\n"
        "}\n\n"
        "fn void Vector2.scale(&self, float factor) {\n"
        "  self.x *= factor;\n"
        "  self.y *= factor;\n"
        "}\n\n"
        "fn void run() {\n"
        f"  Vector2 v1 = {{ 1.0, {float(iteration)} }};\n"
        "  Vector2 v2 = { 3.0, 4.0 };\n"
        "  Vector2 v3 = v1.add(v2);\n"
        "  v3.scale(2.0);\n"
        "}\n"
    )


# ============================================================================
# Main Benchmark Execution
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Performance & Reliability Benchmarking Harness for c3_ls.")
    parser.add_argument("--bin", default=DEFAULT_SERVER_BIN, help=f"Path to c3_ls binary (default: {DEFAULT_SERVER_BIN})")
    parser.add_argument("--root", default=DEFAULT_PROJECT_ROOT, help=f"Project root directory (default: {DEFAULT_PROJECT_ROOT})")
    parser.add_argument("--rounds", type=int, default=5, help="Rounds per file in latency benchmark (default: 5)")
    parser.add_argument("--cycles", type=int, default=1000, help="Cycles in endurance stress run (default: 1000)")
    parser.add_argument("--sla", type=float, default=50.0, help="p95 SLA threshold in ms to flag (default: 50.0)")
    parser.add_argument("--timeout", type=float, default=2.0, help="Timeout threshold in seconds for hangs (default: 2.0)")
    parser.add_argument("--skip-endurance", action="store_true", help="Skip the 1,000-cycle memory endurance test")
    parser.add_argument("--json", metavar="FILE", help="Save complete telemetry report to JSON for regression tracking")

    args = parser.parse_args()

    files = load_project_files(args.root)
    if not files:
        print(f"Error: No .c3 files found in '{args.root}'.")
        sys.exit(1)

    total_lines = sum(f.line_count for f in files)
    total_bytes = sum(f.char_count for f in files)
    endpoints = build_endpoints()

    # Unified Suite Header
    print("=" * 105)
    print("                              c3_ls Benchmark & Profiling Suite")
    print("=" * 105)
    print(f"Server Binary : {args.bin}")
    print(f"Workspace     : {args.root}")
    print(f"Codebase Size : {len(files)} files | {total_lines:,} lines | {total_bytes / 1024:.1f} KB")
    print(f"Configuration : {args.rounds} rounds/file | SLA Target (p95): < {args.sla:.1f} ms | Timeout: {args.timeout:.1f} s")
    print("=" * 105)

    suite_start = time.time()
    total_ops_counter = 0
    hang_counter = 0

    # ------------------------------------------------------------------------
    # Phase 1: Real-Codebase Latency, Tail Percentiles & SLA Validation
    # ------------------------------------------------------------------------
    print(f"\n[Phase 1/2] Latency & Throughput ({len(files)} files × {args.rounds} rounds = {len(files) * (len(endpoints) + 1) * args.rounds:,} ops)...")

    session = LspSession(args.bin, args.root)
    for f in files:
        session.open_document(f.uri, f.content)
    time.sleep(0.3)

    measurements: dict[str, list[float]] = {ep.name: [] for ep in endpoints}
    measurements["didChange (reparse)"] = []
    anomalies: list[str] = []

    for round_idx in range(1, args.rounds + 1):
        for f in files:
            for ep in endpoints:
                params = ep.make_params(f)
                _, lat_ms, ok = session.request(ep.method, params, timeout=args.timeout)
                total_ops_counter += 1

                if not ok:
                    hang_counter += 1
                    anomalies.append(f"HANG: {ep.name} on {f.rel_path} (>{args.timeout:.1f}s)")
                else:
                    measurements[ep.name].append(lat_ms)

            # Edit + Reparse Roundtrip
            t0 = time.perf_counter_ns()
            session.change_document(f.uri, f.content + f"\n// bench_mutation_{round_idx}\n", version=round_idx + 1)
            _, _, ok = session.request("textDocument/documentSymbol", {"textDocument": {"uri": f.uri}}, timeout=args.timeout)
            t1 = time.perf_counter_ns()
            total_ops_counter += 1

            if not ok:
                hang_counter += 1
                anomalies.append(f"HANG: didChange reparse on {f.rel_path}")
            else:
                measurements["didChange (reparse)"].append((t1 - t0) / 1_000_000.0)

    # Output Results Table
    print("\n" + "-" * 105)
    print(f"{'Endpoint':<22} {'Calls':>6} {'Min':>9} {'Mean':>9} {'p50':>9} {'p90':>9} {'p95':>9} {'p99':>9} {'Max':>9}  {'SLA':>4}")
    print("-" * 105)

    stats_summary = {}
    for name, samples in measurements.items():
        dist = compute_distribution(samples)
        stats_summary[name] = dist
        if dist["count"] == 0:
            continue

        sla_met = dist["p95"] <= args.sla
        sla_mark = "\033[92mPASS\033[0m" if sla_met else "\033[93mWARN\033[0m"

        print(
            f"{name:<22} {dist['count']:>6} "
            f"{dist['min']:>7.2f}ms "
            f"{dist['mean']:>7.2f}ms "
            f"{dist['p50']:>7.2f}ms "
            f"{dist['p90']:>7.2f}ms "
            f"{dist['p95']:>7.2f}ms "
            f"{dist['p99']:>7.2f}ms "
            f"{dist['max']:>7.2f}ms  "
            f"{sla_mark}"
        )
    print("-" * 105)

    if anomalies:
        print("\n[!] Latency Anomalies Detected:")
        for a in anomalies[:10]:
            print(f"    • {a}")
        if len(anomalies) > 10:
            print(f"    ... and {len(anomalies) - 10} more.")

    # Largest files formatting speed
    sorted_files = sorted(files, key=lambda x: x.char_count, reverse=True)[:4]
    print("\n[Top Files Formatting Throughput]")
    for sf in sorted_files:
        file_lats = []
        for _ in range(3):
            _, lat, _ = session.request("textDocument/formatting", {
                "textDocument": {"uri": sf.uri},
                "options": {"tabSize": 4, "insertSpaces": False},
            })
            file_lats.append(lat)
        st = compute_distribution(file_lats)
        print(f"  • {sf.rel_path:<40} ({sf.line_count:>5,} lines): mean = {st['mean']:>5.2f} ms | p90 = {st['p90']:>5.2f} ms")

    session.close()

    # ------------------------------------------------------------------------
    # Phase 2: High-Frequency Mutation, Churn & RSS Memory Stability
    # ------------------------------------------------------------------------
    endurance_results = {}
    if not args.skip_endurance:
        print(f"\n[Phase 2/2] Memory Stability & Endurance ({args.cycles:,} churn cycles)...")
        churn_session = LspSession(args.bin, args.root)

        main_uri = Path(args.root).joinpath("virtual_bench_target.c3").as_uri()
        churn_session.open_document(main_uri, make_churn_source(0))

        # Warmup
        for _ in range(20):
            churn_session.request("textDocument/completion", {
                "textDocument": {"uri": main_uri},
                "position": {"line": 23, "character": 5},
            })

        initial_rss = churn_session.get_rss_kb()
        print(f"  • Baseline RSS       : {initial_rss / 1024:.1f} MB ({initial_rss:,} KB)")

        endurance_t0 = time.time()
        endurance_ops = 0

        for i in range(1, args.cycles + 1):
            churn_session.change_document(main_uri, make_churn_source(i), version=i + 1)

            churn_session.request("textDocument/formatting", {"textDocument": {"uri": main_uri}, "options": {"tabSize": 4, "insertSpaces": False}})
            churn_session.request("textDocument/rangeFormatting", {
                "textDocument": {"uri": main_uri},
                "range": {"start": {"line": 8, "character": 0}, "end": {"line": 10, "character": 1}},
                "options": {"tabSize": 4, "insertSpaces": False},
            })
            churn_session.request("textDocument/semanticTokens/full", {"textDocument": {"uri": main_uri}})
            churn_session.request("textDocument/documentSymbol", {"textDocument": {"uri": main_uri}})
            churn_session.request("workspace/symbol", {"query": "Vector2"})
            churn_session.request("textDocument/inlayHint", {
                "textDocument": {"uri": main_uri},
                "range": {"start": {"line": 0, "character": 0}, "end": {"line": 30, "character": 0}},
            })
            churn_session.request("textDocument/foldingRange", {"textDocument": {"uri": main_uri}})
            churn_session.request("textDocument/hover", {"textDocument": {"uri": main_uri}, "position": {"line": 3, "character": 8}})
            churn_session.request("textDocument/definition", {"textDocument": {"uri": main_uri}, "position": {"line": 23, "character": 6}})
            churn_session.request("textDocument/signatureHelp", {"textDocument": {"uri": main_uri}, "position": {"line": 22, "character": 21}})

            comp_resp, _, _ = churn_session.request("textDocument/completion", {
                "textDocument": {"uri": main_uri},
                "position": {"line": 23, "character": 5},
            })
            endurance_ops += 11

            items = (comp_resp or {}).get("result", {}).get("items", [])
            if items:
                churn_session.request("completionItem/resolve", items[0])
                endurance_ops += 1

            churn_session.request("textDocument/references", {
                "textDocument": {"uri": main_uri},
                "position": {"line": 3, "character": 8},
                "context": {"includeDeclaration": True},
            })
            churn_session.request("textDocument/prepareRename", {
                "textDocument": {"uri": main_uri},
                "position": {"line": 3, "character": 8},
            })
            endurance_ops += 2

            # Document churn every 50 cycles
            if i % 50 == 0:
                c_uri = Path(args.root).joinpath(f"virtual_temp_{i}.c3").as_uri()
                churn_session.open_document(c_uri, f"module temp_{i};\nfn void temp_func() {{}}\n")
                churn_session.request("textDocument/documentSymbol", {"textDocument": {"uri": c_uri}})
                churn_session.close_document(c_uri)
                endurance_ops += 1

            if i % 250 == 0:
                cur_rss = churn_session.get_rss_kb()
                delta_kb = cur_rss - initial_rss
                elapsed_cur = time.time() - endurance_t0
                print(f"  • Progress [{i:>4}/{args.cycles}] : RSS: {cur_rss / 1024:>5.1f} MB (delta: {delta_kb:>+6,} KB) | Throughput: {endurance_ops / elapsed_cur:5.1f} ops/s")

        endurance_time = time.time() - endurance_t0
        final_rss = churn_session.get_rss_kb()
        net_growth = final_rss - initial_rss
        growth_rate = (net_growth / endurance_ops) * 1000 if endurance_ops else 0.0

        total_ops_counter += endurance_ops
        churn_session.close()

        print(f"  • Final RSS          : {final_rss / 1024:.1f} MB (Net Delta: {net_growth:+d} KB)")
        print(f"  • Leak Growth Rate   : {growth_rate:.2f} KB / 1,000 requests")
        print(f"  • Churn Throughput   : {endurance_ops / endurance_time:.1f} ops/s ({endurance_ops:,} ops in {endurance_time:.1f}s)")

        endurance_results = {
            "initial_rss_kb": initial_rss,
            "final_rss_kb": final_rss,
            "net_growth_kb": net_growth,
            "leak_growth_rate_kb_per_1k": growth_rate,
            "throughput_ops_sec": endurance_ops / endurance_time,
        }

    # ------------------------------------------------------------------------
    # Overall Suite Verdict
    # ------------------------------------------------------------------------
    total_elapsed = time.time() - suite_start
    overall_throughput = total_ops_counter / total_elapsed if total_elapsed > 0 else 0
    mem_ok = endurance_results.get("net_growth_kb", 0) <= 10_000

    print("\n" + "=" * 105)
    print("                                      Benchmark Summary")
    print("=" * 105)
    print(f"Total Operations : {total_ops_counter:,}")
    print(f"Total Time       : {total_elapsed:.2f} s")
    print(f"Mean Throughput  : {overall_throughput:.1f} ops/s")
    print(f"SLA Violations   : {len(anomalies)} queries exceeded threshold")
    print(f"Hangs / Timeouts : {hang_counter}")

    if not args.skip_endurance:
        mem_status = "\033[92mPASS (Bounded)\033[0m" if mem_ok else "\033[91mFAIL (Leak > 10MB)\033[0m"
        print(f"Memory Stability : {mem_status}")

    suite_pass = (hang_counter == 0) and mem_ok
    verdict = "\033[92mPASSED\033[0m" if suite_pass else "\033[91mFAILED\033[0m"
    print(f"Overall Verdict  : {verdict}")
    print("=" * 105)

    # Export JSON if requested
    if args.json:
        report = {
            "timestamp": time.time(),
            "server_bin": args.bin,
            "workspace": args.root,
            "files_count": len(files),
            "total_lines": total_lines,
            "total_ops": total_ops_counter,
            "elapsed_sec": total_elapsed,
            "overall_throughput_ops_sec": overall_throughput,
            "latency": stats_summary,
            "endurance": endurance_results,
            "passed": suite_pass,
        }
        out_path = Path(args.json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"[Export] Telemetry report saved to '{out_path.resolve()}'.\n")

    sys.exit(0 if suite_pass else 1)


if __name__ == "__main__":
    main()