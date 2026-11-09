#!/usr/bin/env python3
"""Every workflow download goes through download.sh, which retries."""

from pathlib import Path
import re
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

root = Path(sys.argv[1])
script = root / ".github/scripts/download.sh"

for workflow in sorted((root / ".github/workflows").glob("*.yml")):
    for number, line in enumerate(workflow.read_text().splitlines(), 1):
        if not line.lstrip().startswith("#") and re.search(r"\b(curl|wget)\b", line):
            raise SystemExit(f"{workflow.name}:{number} downloads outside "
                             f"download.sh: {line.strip()}")

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
