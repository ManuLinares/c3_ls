#!/usr/bin/env python3
"""
lsp_oracle.py — annotation-driven LSP correctness tester for c3_ls.

Annotation syntax (place on the line IMMEDIATELY after the code line under test):

    some_token_or_expression
    // ^hover: expected substring      <- hover text must CONTAIN this
    // ^!hover: bad substring          <- hover text must NOT contain this
    // ^def: line:<N>                  <- definition target is line N (0-based) in same file
    // ^def: file:<basename> line:<N>  <- definition target is in a different file
    // ^!def:                          <- definition must return NO results
    // ^nodef:                         <- alias for ^!def:

The caret ^ must be placed directly under the token being probed (same column).
Multiple annotation lines may stack under the same code line.

Usage:
    python3 lsp_oracle.py [--server PATH] [--log-level LEVEL] [-v] <file.c3> ...

Exit code 0 = all pass, 1 = any failure.

c3c build && python3 lsp_oracle.py test/programs/http_server.c3
"""

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Optional


# ---------------------------------------------------------------------------
# LSP wire protocol
# ---------------------------------------------------------------------------

DEFAULT_SERVER = os.path.join(os.path.dirname(__file__), "build", "c3_ls")
_msg_id = 0


def _next_id() -> int:
    global _msg_id
    _msg_id += 1
    return _msg_id


def _encode(obj: dict) -> bytes:
    body = json.dumps(obj, separators=(",", ":")).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def _read_message(stdout) -> Optional[dict]:
    header = b""
    while not header.endswith(b"\r\n\r\n"):
        ch = stdout.read(1)
        if not ch:
            return None
        header += ch
    content_length = None
    for line in header.split(b"\r\n"):
        if line.startswith(b"Content-Length:"):
            content_length = int(line.split(b":")[1].strip())
    if content_length is None:
        return None
    body = stdout.read(content_length)
    return json.loads(body)


def _recv_response(proc, expected_id: int) -> dict:
    while True:
        msg = _read_message(proc.stdout)
        if msg is None:
            raise RuntimeError("Server closed connection unexpectedly")
        if msg.get("id") == expected_id:
            return msg


def _send(proc, obj: dict):
    proc.stdin.write(_encode(obj))
    proc.stdin.flush()


# ---------------------------------------------------------------------------
# LSP session
# ---------------------------------------------------------------------------

def lsp_initialize(proc, root_uri: str):
    mid = _next_id()
    _send(proc, {
        "jsonrpc": "2.0", "id": mid, "method": "initialize",
        "params": {
            "processId": os.getpid(),
            "clientInfo": {"name": "lsp_oracle.py", "version": "1.0"},
            "rootUri": root_uri,
            "workspaceFolders": [{"uri": root_uri, "name": "workspace"}],
            "capabilities": {
                "textDocument": {
                    "hover": {"contentFormat": ["plaintext", "markdown"]},
                    "definition": {},
                }
            },
        },
    })
    _recv_response(proc, mid)
    _send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})


def lsp_open(proc, uri: str, text: str):
    _send(proc, {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {"uri": uri, "languageId": "c3", "version": 1, "text": text}
        },
    })


def lsp_hover(proc, uri: str, line: int, character: int) -> Optional[str]:
    mid = _next_id()
    _send(proc, {
        "jsonrpc": "2.0", "id": mid, "method": "textDocument/hover",
        "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}},
    })
    resp = _recv_response(proc, mid)
    result = resp.get("result")
    if not result:
        return None
    contents = result.get("contents", "")
    if isinstance(contents, str):
        return contents
    if isinstance(contents, dict):
        return contents.get("value", "")
    if isinstance(contents, list):
        parts = []
        for c in contents:
            if isinstance(c, str):
                parts.append(c)
            elif isinstance(c, dict):
                parts.append(c.get("value", ""))
        return "\n".join(parts)
    return str(contents)


def lsp_definition(proc, uri: str, line: int, character: int) -> list:
    mid = _next_id()
    _send(proc, {
        "jsonrpc": "2.0", "id": mid, "method": "textDocument/definition",
        "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}},
    })
    resp = _recv_response(proc, mid)
    result = resp.get("result")
    if not result:
        return []
    if isinstance(result, list):
        return result
    return [result]


def lsp_shutdown(proc):
    mid = _next_id()
    _send(proc, {"jsonrpc": "2.0", "id": mid, "method": "shutdown"})
    _recv_response(proc, mid)
    _send(proc, {"jsonrpc": "2.0", "method": "exit"})
    proc.stdin.flush()


# ---------------------------------------------------------------------------
# Annotation parser
# ---------------------------------------------------------------------------

_ANNO_RE = re.compile(
    r'^[ \t]*//'
    r'[ \t]*'
    r'\^'
    r'(?P<bang>!?)'
    r'(?P<kind>hover|def|nodef)'
    r'(?::[ \t]*(?P<payload>.*))?$'
)


class Annotation:
    __slots__ = ("code_line", "character", "kind", "negate", "payload", "anno_line")

    def __init__(self, code_line, character, kind, negate, payload, anno_line):
        self.code_line = code_line
        self.character = character
        self.kind = kind
        self.negate = negate
        self.payload = payload
        self.anno_line = anno_line


def parse_annotations(source: str) -> list:
    lines = source.splitlines()
    results = []
    for i, line in enumerate(lines):
        m = _ANNO_RE.match(line)
        if not m or i == 0:
            continue
        caret_col = line.index("^")
        kind_raw = m.group("kind")
        negate = bool(m.group("bang")) or kind_raw == "nodef"
        kind = "def" if kind_raw == "nodef" else kind_raw
        payload = (m.group("payload") or "").strip()
        # Walk backwards past any stacked annotation lines to find the real code line.
        code_line = i - 1
        while code_line > 0 and _ANNO_RE.match(lines[code_line]):
            code_line -= 1
        results.append(Annotation(code_line, caret_col, kind, negate, payload, i))
    return results


def _parse_def_payload(payload: str):
    file_m = re.search(r'file:(\S+)', payload)
    line_m = re.search(r'line:(\d+)', payload)
    return (file_m.group(1) if file_m else None,
            int(line_m.group(1)) if line_m else None)


def _loc_line(loc: dict) -> int:
    r = loc.get("range", loc.get("targetSelectionRange", loc.get("targetRange", {})))
    if isinstance(r, dict):
        return r.get("start", {}).get("line", -1)
    return -1


def _loc_uri(loc: dict) -> str:
    return loc.get("uri", loc.get("targetUri", ""))


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


def run_file(proc, file_path: str, verbose: bool) -> list:
    abs_path = os.path.abspath(file_path)
    uri = "file://" + abs_path

    with open(abs_path) as f:
        source = f.read()

    lsp_open(proc, uri, source)
    annotations = parse_annotations(source)

    if not annotations:
        return [(SKIP, file_path, "no annotations found")]

    results = []
    for anno in annotations:
        label = (
            f"{os.path.basename(file_path)}:{anno.code_line + 1}:{anno.character + 1}  "
            f"{'!' if anno.negate else ''}{anno.kind}"
            + (f":{anno.payload}" if anno.payload else "")
        )

        try:
            if anno.kind == "hover":
                text = lsp_hover(proc, uri, anno.code_line, anno.character) or ""
                if verbose:
                    print(f"  [hover raw] {repr(text[:200])}")
                if anno.negate:
                    ok = anno.payload not in text
                    detail = f"hover CONTAINS {repr(anno.payload)}" if not ok else ""
                else:
                    ok = anno.payload in text
                    detail = f"not found in hover\n      expected: {repr(anno.payload)}\n      got:      {repr(text[:300])}" if not ok else ""

            elif anno.kind == "def":
                locs = lsp_definition(proc, uri, anno.code_line, anno.character)
                if verbose:
                    print(f"  [def raw]   {json.dumps(locs)[:300]}")
                if anno.negate:
                    ok = len(locs) == 0
                    detail = f"expected no definition, got {len(locs)} result(s): {json.dumps(locs)[:200]}" if not ok else ""
                else:
                    if not locs:
                        ok = False
                        detail = "definition returned no results"
                    else:
                        exp_file, exp_line = _parse_def_payload(anno.payload)
                        loc = locs[0]
                        got_uri = _loc_uri(loc)
                        got_line = _loc_line(loc)
                        checks = []
                        ok = True
                        if exp_file:
                            file_ok = os.path.basename(got_uri) == exp_file or exp_file in got_uri
                            if not file_ok:
                                checks.append(f"file: expected {repr(exp_file)}, got {repr(os.path.basename(got_uri))}")
                                ok = False
                        if exp_line is not None:
                            # Annotations use 1-based lines; LSP returns 0-based.
                            if got_line != exp_line - 1:
                                checks.append(f"line: expected {exp_line} (0-based: {exp_line - 1}), got {got_line}")
                                ok = False
                        detail = "; ".join(checks)
            else:
                ok = False
                detail = f"unknown kind {anno.kind!r}"

        except Exception as e:
            ok = False
            detail = f"exception: {e}"

        results.append((PASS if ok else FAIL, label, detail))

    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="c3_ls annotation-driven LSP oracle")
    parser.add_argument("files", nargs="+", metavar="FILE")
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--log-level", default="error",
                        choices=["debug", "info", "warn", "error"])
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.server):
        print(f"ERROR: server binary not found: {args.server}", file=sys.stderr)
        sys.exit(1)

    proc = subprocess.Popen(
        [args.server, "--log-level", args.log_level],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
    )

    root = "file://" + os.path.abspath(os.path.dirname(args.files[0]))
    lsp_initialize(proc, root)

    all_results = []
    for f in args.files:
        all_results.extend(run_file(proc, f, args.verbose))

    lsp_shutdown(proc)
    proc.wait(timeout=5)

    passes = [r for r in all_results if r[0] == PASS]
    fails  = [r for r in all_results if r[0] == FAIL]
    skips  = [r for r in all_results if r[0] == SKIP]

    print()
    print("=" * 72)
    for status, label, detail in all_results:
        icon = {"PASS": "✓", "FAIL": "✗", "SKIP": "○"}.get(status, "?")
        print(f"  {icon} {label}")
        if detail:
            for dl in detail.splitlines():
                print(f"      {dl}")
    print("=" * 72)
    print(f"\n  {len(passes)} passed  {len(fails)} failed  {len(skips)} skipped\n")

    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
