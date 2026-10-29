"""Size a Boxer wing box through one persistent JFEM SOL105 worker.

Run ``python -B utils/python_client/wingbox_sizing_demo.py --help`` from the
repository root. Python uses only its standard library.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import time
from pathlib import Path
from typing import Any, Mapping

try:
    from .jfem_client import JFEMWorker
except ImportError:
    from jfem_client import JFEMWorker


def checked_design(response: Mapping[str, Any], expected_modes: int) -> tuple[float, dict[str, Any]]:
    """Reject incomplete spectra and choose the highest-energy eligible PID.

    Roots are global, not per-property values. The eligible variables in this
    template are active isotropic PSHELL thicknesses. Other properties remain
    part of the solve and of the total-energy normalization.
    """
    spectra = response.get("spectra", [])
    if not spectra or any(len(s.get("eigenvalues", [])) != expected_modes for s in spectra):
        raise ValueError("Missing spectrum or incorrect number of returned modes")
    roots = [float(x) for s in spectra for x in s["eigenvalues"]]
    if any(not math.isfinite(x) or x <= 0 for x in roots):
        raise ValueError("Expected finite positive buckling load factors")
    critical = min(roots)
    if not math.isclose(critical, float(response["minimum_positive_eigenvalue"]), rel_tol=1e-12):
        raise ValueError("Critical root does not match returned spectra")
    choices = [r for r in response["property_energy"] if r["updateable"]]
    if not choices:
        raise ValueError("No eligible PSHELL thickness has mode energy")
    if any(not math.isfinite(float(r["strain_energy"])) or float(r["strain_energy"]) < 0 for r in choices):
        raise ValueError("Invalid property strain energy")
    chosen = min(choices, key=lambda r: (-float(r["strain_energy"]), int(r["pid"])))
    if float(chosen["strain_energy"]) <= 0:
        raise ValueError("Eligible properties have zero critical-mode energy")
    return critical, dict(chosen)


def write_json(path: Path, data: Any) -> None:
    with path.open("x", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, allow_nan=False)
        stream.write("\n")


def run(args: argparse.Namespace) -> dict[str, Any]:
    repo = Path(args.repo).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    start = time.perf_counter()
    summary: dict[str, Any] = {"status": "failed", "target": args.target,
        "update_factor": args.factor, "selection": "largest eligible PSHELL strain energy in the lowest positive mode"}
    history: list[dict[str, Any]] = []
    worker = None
    try:
        if args.input:
            deck = Path(args.input).resolve()
        else:
            generated = output / "model"
            command = [args.julia, "--startup-file=no", f"--project={repo}",
                str(repo / "utils/python_client/generate_wingbox.jl"),
                str(Path(args.config).resolve()), str(generated)]
            with (output / "generation.log").open("w", encoding="utf-8") as log:
                subprocess.run(command, cwd=repo, stdout=log, stderr=log, check=True)
            deck = generated / "wingbox.bdf"
        with (output / "worker.log").open("w", encoding="utf-8") as log, JFEMWorker(
            repo_root=repo, julia=args.julia, threads=args.threads,
            sysimage=None if args.no_sysimage else args.sysimage,
            request_timeout=args.timeout, stderr=log) as worker:
            write_json(output / "worker_ready.json", worker.ready)
            loaded = worker.load_model(deck)
            write_json(output / "loaded_model.json", loaded)
            pid, session = worker.ready["pid"], worker.ready["worker_session_id"]
            revision = loaded["revision"]
            update: dict[str, float] = {}
            previous: dict[str, Any] = {}
            for iteration in range(args.max_updates + 1):
                tick = time.perf_counter()
                response = worker.solve_model(thicknesses=update, expected_revision=revision,
                                              expected_modes=args.modes)
                elapsed = time.perf_counter() - tick
                if response["pid"] != pid or response["worker_session_id"] != session or response["parse_count"] != 1:
                    raise RuntimeError("Worker identity or parse-once contract changed")
                critical, chosen = checked_design(response, args.modes)
                revision = response["revision"]
                write_json(output / f"iteration_{iteration:03d}.json", response)
                row = {"iteration": iteration, "minimum_eigenvalue": critical,
                    "selected_pid": chosen["pid"], "energy_fraction": chosen["fraction"],
                    "updated_pid": previous.get("pid"), "thickness_before": previous.get("before"),
                    "thickness_after": previous.get("after"), "request_seconds": elapsed,
                    "pid": pid, "worker_session_id": session, "revision": revision}
                history.append(row)
                print(f"iteration {iteration:3d}: minimum lambda={critical:.8g}, "
                      f"controlling PSHELL={chosen['pid']}, request={elapsed:.3f}s", flush=True)
                # Every returned positive root must exceed the target. Checking
                # the finite, complete minimum is equivalent and mode-order safe.
                if critical > args.target:
                    summary.update(status="converged", updates=iteration,
                        analyses=iteration+1, minimum_eigenvalue=critical,
                        final_spectra=response["spectra"], pid=pid, worker_session_id=session,
                        parse_count=1, input_sha256=response["input_sha256"],
                        actual_image=worker.ready.get("image_file"))
                    write_json(output / "final_thicknesses.json", response["thicknesses"])
                    break
                if iteration == args.max_updates:
                    raise RuntimeError("Sizing did not converge before max_updates")
                key = str(chosen["pid"])
                before = float(response["thicknesses"][key])
                after = before * args.factor
                if not math.isfinite(after):
                    raise ValueError("Thickness overflow")
                update = {key: after}  # Only the changed scalar crosses the pipe.
                previous = {"pid": chosen["pid"], "before": before, "after": after}
            # Confirms a graceful shutdown; no daemon is left after the demo.
            summary["completed_worker_commands"] = worker.status()["commands"]
        summary["worker_exit_code"] = worker.process.returncode
        return summary
    except BaseException as error:
        summary["error"] = str(error)
        raise
    finally:
        if history:
            with (output / "history.csv").open("x", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=list(history[0]))
                writer.writeheader()
                writer.writerows(history)
        if worker is not None:
            summary["worker_exit_code"] = worker.process.poll()
        summary["total_seconds"] = time.perf_counter() - start
        write_json(output / "summary.json", summary)


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(repo))
    parser.add_argument("--output", required=True, help="new output directory; never overwritten")
    parser.add_argument("--input", help="existing SOL105 deck; omit to generate the Boxer demo")
    parser.add_argument("--config", default=str(Path(__file__).with_name("examples") / "wingbox_sizing.toml"))
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--threads", default="1")
    parser.add_argument("--sysimage", default="auto", help="auto or a current image with a provenance receipt")
    parser.add_argument("--no-sysimage", action="store_true", help="explicit source-loading fallback; still one warm worker")
    parser.add_argument("--timeout", type=float, default=600, help="timeout per request in seconds")
    parser.add_argument("--modes", type=int, default=4, help="required root count per buckling subcase")
    parser.add_argument("--target", type=float, default=1.0)
    parser.add_argument("--factor", type=float, default=1.1)
    parser.add_argument("--max-updates", type=int, default=250)
    args = parser.parse_args()
    if not math.isfinite(args.target) or args.target <= 0 or not math.isfinite(args.factor) or args.factor <= 1:
        parser.error("target must be positive and finite; factor must be finite and greater than 1")
    if args.modes < 1 or args.max_updates < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("modes, max-updates and timeout must be positive")
    summary = run(args)
    print(f"Converged after {summary['updates']} updates; results: {Path(args.output).resolve()}")


if __name__ == "__main__":
    main()
