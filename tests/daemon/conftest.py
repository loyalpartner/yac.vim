"""Daemon integration test infrastructure.

Tests talk directly to yacd via JSON-RPC (stdio), no Vim process needed.
A single daemon + ZLS instance is shared across all tests in the session.
"""

import json
import os
import queue
import shutil
import subprocess
import threading
import time
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
DATA_TMPL = PROJECT_ROOT / "tests" / "data_tmpl"


def _find_yacd_bin() -> Path:
    """Locate the yacd binary (ReleaseSafe build)."""
    for candidate in [
        PROJECT_ROOT / "yacd" / "zig-out" / "bin" / "yacd",
        PROJECT_ROOT / "zig-out" / "bin" / "yacd",
    ]:
        if candidate.exists():
            return candidate
    pytest.fail("yacd binary not found — run `make release` first")


class DaemonClient:
    """JSON-RPC client that talks directly to yacd via stdio.

    Protocol (Vim channel format):
      Request:      [id, {"method": "...", "params": {...}}]
      Response:     [-id, {"result": ...}]
      Notification: [{"method": "...", "params": {...}}]
      Push:         [{"action": "...", "params": {...}}]
    """

    def __init__(self, proc: subprocess.Popen):
        self._proc = proc
        self._stdin = proc.stdin
        self._stdout = proc.stdout
        self._id = 0
        self._push_queue: queue.Queue = queue.Queue()
        self._response_map: dict[int, dict] = {}
        self._response_events: dict[int, threading.Event] = {}
        self._lock = threading.Lock()
        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()

    def _reader_loop(self):
        """Background thread: read stdout byte-by-byte, split on newlines, dispatch."""
        try:
            buf = b""
            while True:
                chunk = self._stdout.read(1)
                if not chunk:
                    break  # EOF
                buf += chunk
                if chunk != b"\n":
                    continue
                line = buf.strip()
                buf = b""
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(parsed, list) or len(parsed) == 0:
                    continue

                # Response: [id, {"result": ...}] or [id, {"ready": ...}] etc.
                # Vim channel protocol: response id matches request id (positive)
                if len(parsed) == 2 and isinstance(parsed[0], int) and parsed[0] > 0:
                    resp_id = parsed[0]
                    with self._lock:
                        self._response_map[resp_id] = parsed[1]
                        if resp_id in self._response_events:
                            self._response_events[resp_id].set()
                # Push notification: [0, {"action": "...", "params": {...}}]
                # Vim channel protocol uses id=0 for daemon-initiated notifications
                elif len(parsed) == 2 and parsed[0] == 0 and isinstance(parsed[1], dict):
                    self._push_queue.put(parsed[1])
                # Unknown — ignore
        except (ValueError, OSError):
            pass  # process exited

    def request(self, method: str, params: dict | None = None, timeout: float = 30) -> dict | None:
        """Send request, block until response. Returns the result dict."""
        self._id += 1
        req_id = self._id
        msg = {"method": method}
        if params is not None:
            msg["params"] = params
        payload = json.dumps([req_id, msg]) + "\n"

        event = threading.Event()
        with self._lock:
            self._response_events[req_id] = event

        self._stdin.write(payload.encode())
        self._stdin.flush()

        if not event.wait(timeout):
            raise TimeoutError(f"No response for {method} (id={req_id}) within {timeout}s")

        with self._lock:
            del self._response_events[req_id]
            return self._response_map.pop(req_id, None)

    def notify(self, method: str, params: dict | None = None):
        """Send notification (no response expected)."""
        msg = {"method": method}
        if params is not None:
            msg["params"] = params
        payload = json.dumps([msg]) + "\n"
        self._stdin.write(payload.encode())
        self._stdin.flush()

    def wait_push(self, action: str, timeout: float = 10) -> dict:
        """Wait for a push notification with the given action. Returns params."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                msg = self._push_queue.get(timeout=0.2)
                if msg.get("action") == action:
                    return msg.get("params", {})
                # Not the one we want — put back? No, just drop non-matching.
                # Tests should drain relevant pushes in order.
            except queue.Empty:
                continue
        raise TimeoutError(f"No push notification '{action}' within {timeout}s")

    def drain_pushes(self, timeout: float = 0.5) -> list[dict]:
        """Drain all pending push notifications (non-blocking after timeout)."""
        result = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result.append(self._push_queue.get(timeout=0.1))
            except queue.Empty:
                break
        return result

    def wait_lsp_ready(self, file: str, timeout: float = 30):
        """Poll lsp_status until ready=true."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.request("lsp_status", {"file": file}, timeout=5)
            if result and result.get("ready"):
                return
            time.sleep(0.3)
        raise TimeoutError(f"LSP not ready for {file} within {timeout}s")

    @property
    def alive(self) -> bool:
        return self._proc.poll() is None


def _setup_workspace(tmp_path_factory) -> Path:
    """Create a workspace with test data + symlinks (same as conftest.py _make_workspace)."""
    tmpdir = tmp_path_factory.mktemp("daemon_test")
    shutil.copytree(DATA_TMPL, tmpdir / "test_data")

    for name in ["vim", "vimrc", "tests"]:
        src = PROJECT_ROOT / name
        if src.exists():
            (tmpdir / name).symlink_to(src)
    for name in ["zig-out", "yacd", "languages"]:
        src = PROJECT_ROOT / name
        if src.exists():
            (tmpdir / name).symlink_to(src)

    (tmpdir / "run").mkdir(exist_ok=True)
    return tmpdir


@pytest.fixture(scope="session")
def workspace(tmp_path_factory) -> Path:
    return _setup_workspace(tmp_path_factory)


@pytest.fixture(scope="session")
def test_file(workspace) -> str:
    """Absolute path to main.zig in the test workspace."""
    return str(workspace / "test_data" / "src" / "main.zig")


@pytest.fixture(scope="session")
def daemon(workspace, test_file) -> DaemonClient:
    """Session-scoped: start one yacd daemon, warm up ZLS, share across all tests."""
    yacd_bin = _find_yacd_bin()
    langs_dir = PROJECT_ROOT / "languages"
    log_file = workspace / "run" / "yacd-daemon-test.log"

    cmd = [str(yacd_bin), "--log-level=debug", f"--log-file={log_file}", "--no-copilot"]
    if langs_dir.exists():
        cmd.append(f"--languages-dir={langs_dir}")

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=open(workspace / "run" / "yacd-stderr.log", "w"),
        cwd=str(workspace),
        bufsize=0,  # unbuffered — critical for line-by-line JSON-RPC
    )

    client = DaemonClient(proc)

    # Wait for daemon to be ready (it sends "started" push on connect)
    try:
        started = client.wait_push("started", timeout=10)
    except TimeoutError:
        proc.kill()
        proc.wait()
        # Print stderr for debugging
        stderr_log = workspace / "run" / "yacd-stderr.log"
        if stderr_log.exists():
            print(f"yacd stderr: {stderr_log.read_text()[:2000]}")
        pytest.fail(f"yacd daemon failed to start. Log: {log_file}")

    # Open main.zig to trigger ZLS initialization
    text = Path(test_file).read_text()
    client.notify("did_open", {"file": test_file, "text": text, "language": "zig"})

    # Wait for ZLS to be ready
    try:
        client.wait_lsp_ready(test_file, timeout=30)
    except TimeoutError:
        proc.kill()
        proc.wait()
        pytest.fail(f"ZLS failed to initialize. Log: {log_file}")

    # Drain any startup pushes (ts_highlights, diagnostics, etc.)
    client.drain_pushes(timeout=2)

    yield client

    # Teardown
    try:
        client.request("exit", timeout=5)
    except (TimeoutError, OSError):
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
