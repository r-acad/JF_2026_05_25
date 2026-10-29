"""Small stdlib-only Python client for OpenJFEM batch execution.

For repeated thickness changes to a fixed model, use ``load_model`` once and
``solve_model`` for each update. See ``wingbox_sizing_demo.py`` and README.md.
For independent input decks, the batch workflow is:

1. Start one JSONL worker process.
2. Generate one JSON manifest per optimization iteration.
3. Send ``{"command": "run_batch", "manifest": "..."}`` to the worker.
4. Read ``batch_summary.json`` or ``batch_summary.csv``.

This module intentionally has no third-party Python dependencies.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Union


DEFAULT_FAST_FLAGS: Dict[str, str] = {
    "JFEM_EXPORT_BINARY": "false",
    "JFEM_MATRIX_ASYMMETRY_CHECK": "false",
    "JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES": "false",
    "JFEM_SUPPRESS_THREAD_HINT": "1",
}


def resolve_sysimage(repo_root: Union[str, Path], sysimage: Union[str, Path],
                     *, julia: str = "julia") -> Path:
    """Resolve ``auto`` or an explicit image and verify its provenance receipt.

    An existing DLL/SO alone is insufficient: it must match this checkout,
    sources, package lock and Julia runtime. Validation uses a bare Julia
    process, before an image containing older compiled code can be loaded.
    """
    repo = Path(repo_root).resolve()
    suffix = ".dll" if sys.platform == "win32" else ".dylib" if sys.platform == "darwin" else ".so"
    image = repo / "sysimage" / ("OpenJFEM_sysimage" + suffix) if str(sysimage) == "auto" else Path(sysimage).resolve()
    if not image.is_file():
        raise FileNotFoundError(f"JFEM sysimage does not exist: {image}")
    check = subprocess.run([julia, "--startup-file=no", f"--project={repo}",
        str(repo / "utils/julia_tools/check_sysimage.jl"), str(repo), str(image)],
        cwd=repo, text=True, encoding="utf-8", capture_output=True, timeout=120)
    if check.returncode:
        raise RuntimeError(f"JFEM sysimage is not current: {check.stderr.strip()}")
    return image


def write_batch_manifest(
    path: Union[str, Path],
    cases: Iterable[Mapping[str, Any]],
    output_root: Union[str, Path],
    *,
    batch_id: Optional[str] = None,
    backend: Optional[str] = None,
    flags: Optional[Mapping[str, Any]] = None,
    output_options: Optional[Mapping[str, Any]] = None,
    gc_between: bool = True,
    stop_on_error: bool = False,
) -> Path:
    """Write an OpenJFEM JSON batch manifest and return its path.

    Each case must contain at least ``input``. ``case_id`` and ``output_dir`` are
    optional; JFEM will derive stable output folders when they are omitted.
    Use ``output_options={"json": True, "binary": False, "eigenvalues_only": True,
    "report": False}`` when a SOL 105 optimization loop needs buckling factors
    but not mode shapes or Markdown reports.
    Use ``output_options={"json": True, "binary": False, "eigenvectors": True,
    "report": False}`` when the loop also needs buckling eigenvectors; read
    the file named by ``case["result_json"]`` in ``batch_summary.json``.
    """

    manifest_path = Path(path)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    merged_flags = dict(DEFAULT_FAST_FLAGS)
    if flags:
        merged_flags.update({str(k): str(v) for k, v in flags.items()})
    manifest: Dict[str, Any] = {
        "output_root": str(output_root),
        "defaults": {
            "flags": merged_flags,
            "output_options": dict(output_options or {"binary": False, "json": True}),
            "gc_between": gc_between,
            "stop_on_error": stop_on_error,
        },
        "cases": [dict(case) for case in cases],
    }
    if backend is not None:
        manifest["defaults"]["backend"] = str(backend)
    if batch_id is not None:
        manifest["batch_id"] = str(batch_id)
    with manifest_path.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    return manifest_path


def run_batch_once(
    manifest: Union[str, Path],
    *,
    repo_root: Union[str, Path] = ".",
    julia: str = "julia",
    threads: str = "auto",
    quiet: bool = False,
    stop_on_error: bool = False,
    sysimage: Optional[Union[str, Path]] = None,
) -> subprocess.CompletedProcess[str]:
    """Run a manifest by launching one Julia process for the full batch."""

    repo = Path(repo_root).resolve()
    cmd: List[str] = [
        julia,
        f"--threads={threads}",
        "--startup-file=no",
    ]
    if sysimage is not None:
        image = resolve_sysimage(repo, sysimage, julia=julia)
        cmd.append(f"--sysimage={image}")
    cmd.extend(
        [
            f"--project={repo}",
            str(repo / "utils" / "julia_tools" / "run_batch_manifest.jl"),
            str(Path(manifest).resolve()),
        ]
    )
    if quiet:
        cmd.append("--quiet")
    if stop_on_error:
        cmd.append("--stop-on-error")
    return subprocess.run(cmd, cwd=repo, text=True, encoding="utf-8", check=True)


class JFEMWorker:
    """One persistent Julia process, with serialized requests and owned cleanup.

    Pass ``sysimage="auto"`` or a receipt-verified explicit image for fast
    startup. ``None`` deliberately uses normal package loading. Loaded model
    sessions avoid BDF parsing and result-file transfers on each iteration.
    """

    def __init__(
        self,
        *,
        repo_root: Union[str, Path] = ".",
        julia: str = "julia",
        threads: str = "auto",
        flags: Optional[Mapping[str, Any]] = None,
        sysimage: Optional[Union[str, Path]] = None,
        stderr: Any = None,
        startup_timeout: float = 900,
        request_timeout: Optional[float] = None,
    ) -> None:
        self.repo_root = Path(repo_root).resolve()
        self.request_timeout = request_timeout
        self._responses: queue.Queue[Any] = queue.Queue()
        self._lock = threading.Lock()
        self._next_id = 0
        merged_flags = dict(DEFAULT_FAST_FLAGS)
        if flags:
            merged_flags.update({str(k): str(v) for k, v in flags.items()})
        flags_raw = ",".join(f"{k}={v}" for k, v in sorted(merged_flags.items()))
        cmd: List[str] = [
            julia,
            f"--threads={threads}",
            "--startup-file=no",
            "--compiled-modules=existing",
        ]
        if sysimage is not None:
            image = resolve_sysimage(self.repo_root, sysimage, julia=julia)
            cmd.append(f"--sysimage={image}")
        cmd.extend(
            [
                f"--project={self.repo_root}",
                str(self.repo_root / "utils" / "julia_tools" / "jfem_worker_jsonl.jl"),
                flags_raw,
            ]
        )
        self.process = subprocess.Popen(
            cmd,
            cwd=self.repo_root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr if stderr is not None else sys.stderr,
            # A sysimage initializes its packages before the worker script runs.
            env={**os.environ, **merged_flags},
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._reader = threading.Thread(target=self._receive, daemon=True)
        self._reader.start()
        try:
            self.ready = self._read_response(startup_timeout)
            if self.ready.get("status") != "ready":
                raise RuntimeError(f"OpenJFEM worker did not start cleanly: {self.ready}")
        except BaseException:
            self._terminate()
            self._close_pipes()
            raise

    def _receive(self) -> None:
        try:
            assert self.process.stdout is not None
            for line in self.process.stdout:
                self._responses.put(json.loads(line))
            self._responses.put(RuntimeError("OpenJFEM worker closed its response stream"))
        except BaseException as error:
            self._responses.put(error)

    def _read_response(self, timeout: Optional[float] = None) -> Dict[str, Any]:
        try:
            response = self._responses.get(timeout=timeout)
        except queue.Empty as error:
            self._terminate()
            raise TimeoutError("JFEM response timed out; owned worker stopped") from error
        if isinstance(response, BaseException):
            raise RuntimeError(f"JFEM protocol/worker failure: {response}") from response
        if not isinstance(response, dict):
            raise RuntimeError("JFEM response must be a JSON object")
        return response

    def request(self, payload: Mapping[str, Any]) -> Dict[str, Any]:
        with self._lock:
            if self.process.stdin is None or self.process.poll() is not None:
                raise RuntimeError("worker is not running")
            command = dict(payload)
            self._next_id += 1
            command.setdefault("id", self._next_id)
            encoded = json.dumps(command, allow_nan=False)
            try:
                self.process.stdin.write(encoded + "\n")
                self.process.stdin.flush()
                response = self._read_response(self.request_timeout)
            except BaseException:
                self._terminate()
                raise
            if response.get("id") != command["id"]:
                self._terminate()
                raise RuntimeError("JFEM response ID does not match the request")
            if response.get("status") == "error":
                raise RuntimeError(response.get("error", "OpenJFEM worker command failed"))
            return response

    def load_model(self, input_path: Union[str, Path], *, model_id: str = "default") -> Dict[str, Any]:
        """Parse one SOL105 deck once; retain a clean baseline in Julia memory."""
        return self.request({"command": "load_model", "input": str(Path(input_path).resolve()), "model_id": model_id})

    def solve_model(self, *, model_id: str = "default",
                    thicknesses: Optional[Mapping[Union[int, str], float]] = None,
                    expected_revision: Optional[int] = None,
                    expected_modes: Optional[int] = None) -> Dict[str, Any]:
        """Apply absolute PSHELL thicknesses and solve in the existing process.

        Failed commands commit no property changes. Model vectors and result
        matrices stay in Julia; the reply contains spectra and property energy.
        """
        command: Dict[str, Any] = {"command": "solve_model", "model_id": model_id,
            "thicknesses": {str(k): v for k, v in (thicknesses or {}).items()}}
        if expected_revision is not None:
            command["expected_revision"] = expected_revision
        if expected_modes is not None:
            command["expected_modes"] = expected_modes
        return self.request(command)

    def unload_model(self, model_id: str = "default") -> Dict[str, Any]:
        return self.request({"command": "unload_model", "model_id": model_id})

    def status(self) -> Dict[str, Any]:
        return self.request({"command": "status"})

    def gc(self) -> Dict[str, Any]:
        return self.request({"command": "gc"})

    def run_batch(self, manifest: Union[str, Path], *, request_id: Optional[str] = None) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"command": "run_batch", "manifest": str(manifest)}
        if request_id is not None:
            payload["id"] = request_id
        return self.request(payload)

    def close(self) -> None:
        try:
            if self.process.poll() is None and self.process.stdin is not None:
                self.process.stdin.write(json.dumps({"command": "quit"}) + "\n")
                self.process.stdin.flush()
                self._read_response(10)
        except (OSError, RuntimeError, TimeoutError):
            pass
        finally:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._terminate()
            self._close_pipes()

    def _close_pipes(self) -> None:
        for stream in (self.process.stdin, self.process.stdout):
            if stream is not None:
                stream.close()
        self._reader.join(timeout=2)

    def _terminate(self) -> None:
        """Stop only the child process owned by this client."""
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)

    def __enter__(self) -> "JFEMWorker":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close()


def load_summary(path: Union[str, Path]) -> Dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as f:
        return json.load(f)


__all__ = [
    "DEFAULT_FAST_FLAGS",
    "JFEMWorker",
    "load_summary",
    "run_batch_once",
    "write_batch_manifest",
    "resolve_sysimage",
]
