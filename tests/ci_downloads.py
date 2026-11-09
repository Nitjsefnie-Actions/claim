#!/usr/bin/env python3
"""Workflow downloads and pip installs go through retrying scripts."""

from pathlib import Path
import http.server
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

root = Path(sys.argv[1])
script = root / ".github/scripts/download.sh"

for workflow in sorted((root / ".github/workflows").glob("*.yml")):
    for number, line in enumerate(workflow.read_text().splitlines(), 1):
        if not line.lstrip().startswith("#") and re.search(r"\b(curl|wget)\b", line):
            raise SystemExit(f"{workflow.name}:{number} downloads outside "
                             f"download.sh: {line.strip()}")
        pip = re.search(r"\bpip3?(?:\s+-\S+)*\s+install\b", line)
        if (pip and not line.lstrip().startswith("#")
                and ".github/scripts/retry.sh " not in line[:pip.start()]):
            raise SystemExit(f"{workflow.name}:{number} installs outside "
                             f"retry.sh: {line.strip()}")

PAYLOAD = b"the release bytes\n" * 64
# A dropped partial body, a 5xx outside curl's retry list, a redirect.
ANSWERS = [
    b"HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n",
    b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n",
    b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\npartial" % len(PAYLOAD),
    b"HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n",
    b"HTTP/1.1 302 Found\r\nLocation: /asset\r\nContent-Length: 0\r\n\r\n",
    b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(PAYLOAD) + PAYLOAD,
]
requests = []


class Release(socketserver.StreamRequestHandler):
    def handle(self):
        requests.append(self.rfile.readline().decode())
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        index = len(requests) - 1
        self.wfile.write(ANSWERS[index] if index < len(ANSWERS)
                         else b"HTTP/1.1 500 Unscripted\r\nContent-Length: 0\r\n\r\n")


with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Release) as server, \
        tempfile.TemporaryDirectory() as scratch:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/release.tar.gz"
    out = Path(scratch) / "release.tar.gz"
    usage = subprocess.run(["bash", str(script), url], capture_output=True,
                           text=True, check=False)
    assert usage.returncode == 2 and not requests, \
        f"one argument must be refused before any request: {usage}"
    started = time.monotonic()
    result = subprocess.run(["bash", str(script), url, str(out)],
                            capture_output=True, text=True, check=False,
                            timeout=120)
    elapsed = time.monotonic() - started
    server.shutdown()
    downloaded = out.read_bytes() if out.exists() else None
assert result.returncode == 0, f"exit {result.returncode}: {result.stderr}"
expected = ["GET /release.tar.gz HTTP/1.1\r\n"] * (len(ANSWERS) - 1)
assert requests == expected + ["GET /asset HTTP/1.1\r\n"], \
    f"expected one attempt per scripted answer, got {requests!r}"
assert downloaded == PAYLOAD, \
    "the downloaded file is not exactly the final answer's body"
# Doubling pauses take 1+2+4+8 seconds; a fixed one-second delay takes 4.
assert elapsed >= 15, f"retries took {elapsed:.1f}s: the pause is not doubling"

# Newer curl exits 0 with no file when Retry-After outlasts the window.
ANSWERS = [b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3600\r\n"
           b"Content-Length: 0\r\n\r\n"]
requests.clear()
with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Release) as server, \
        tempfile.TemporaryDirectory() as scratch:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    result = subprocess.run(
        ["bash", str(script), f"http://127.0.0.1:{server.server_address[1]}/x",
         str(Path(scratch) / "x")], capture_output=True, text=True,
        check=False, timeout=120)
    server.shutdown()
assert result.returncode != 0 and len(requests) == 1, \
    f"a refused download must fail: exit {result.returncode}, {requests!r}"

WHEEL = "demo-1.0-py3-none-any.whl"
with tempfile.TemporaryDirectory() as scratch:
    wheel = Path(scratch) / WHEEL
    entries = {
        "METADATA": "Metadata-Version: 2.1\nName: demo\nVersion: 1.0\n",
        "WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        "RECORD": "",
    }
    with zipfile.ZipFile(wheel, "w") as archive:
        for name, text in entries.items():
            archive.writestr(f"demo-1.0.dist-info/{name}", text)
    index_answers = [504, 429]
    seen = []

    class Index(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.path)
            if self.path.startswith("/simple/") and index_answers:
                body, status = b"", index_answers.pop(0)
            elif self.path.startswith("/simple/"):
                body, status = f'<a href="/files/{WHEEL}">{WHEEL}</a>'.encode(), 200
            else:
                body, status = wheel.read_bytes(), 200
            self.send_response(status)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Index) as pypi:
        threading.Thread(target=pypi.serve_forever, daemon=True).start()
        out = Path(scratch) / "out"
        started = time.monotonic()
        result = subprocess.run(
            ["bash", str(root / ".github/scripts/retry.sh"), sys.executable,
             "-m", "pip", "--isolated", "--disable-pip-version-check",
             "download", "--no-deps", "--no-cache-dir", "-d", str(out),
             "--index-url", f"http://127.0.0.1:{pypi.server_address[1]}/simple",
             "demo"], capture_output=True, text=True, check=False, timeout=120)
        elapsed = time.monotonic() - started
        pypi.shutdown()
    assert result.returncode == 0, f"pip exit {result.returncode}: {result.stderr}"
    assert seen == ["/simple/demo/"] * 3 + [f"/files/{WHEEL}"], \
        f"expected a 504 run, a 429 run, then the download: {seen!r}"
    assert (out / WHEEL).read_bytes() == wheel.read_bytes(), "wrong wheel bytes"
    pauses = re.findall(r"retrying in (\d+)s", result.stderr)
    assert pauses == ["1", "2"] and elapsed >= 3, \
        f"pauses {pauses} over {elapsed:.1f}s: the pause is not doubling"

RETRY = str(root / ".github/scripts/retry.sh")
usage = subprocess.run(["bash", RETRY], capture_output=True, check=False)
assert usage.returncode == 2, f"retry.sh with no command exited {usage.returncode}"
with tempfile.TemporaryDirectory() as scratch:
    shim, log = Path(scratch) / "sleep", Path(scratch) / "pauses"
    shim.write_text(f'#!/bin/sh\necho "$1" >> "{log}"\nexec {shutil.which("sleep")} "$1"\n')
    shim.chmod(0o755)
    # Started 296 seconds in: pauses of 1 and 2 fit before 300, then 4 does not.
    env = dict(os.environ, SECONDS="296", PATH=f"{scratch}{os.pathsep}{os.environ['PATH']}")
    result = subprocess.run(["bash", RETRY, "sh", "-c", "exit 7"], env=env,
                            capture_output=True, text=True, check=False, timeout=60)
    slept = log.read_text().split() if log.exists() else []
assert result.returncode == 7 and slept == ["1", "2"], \
    f"exit {result.returncode} after pauses {slept}: expected 7 after 1 and 2"
