> **Before first launch:** run `setup.cmd` (Windows), `bash setup.sh` (Linux), or `bash setup.command` (macOS) at the repository root. This installs shared packages and creates the shared image under the root `sysimage/` directory. Wait until setup completes.

# Python: keep JFEM warm and size a wing box

This standard-library Python client owns one Julia JSONL worker. A sysimage
reduces startup compilation; keeping that process alive avoids paying startup
and compilation again on every design iteration.

The runnable example uses the production **JFEM-Boxer** generator to create a
small swept wing box, runs **SOL105**, and increases one shell thickness by
**10%** per update until every requested positive buckling load factor is
strictly greater than **1**. Python controls the design; JFEM performs the
finite-element analysis and strain-energy recovery.

## Run the complete example

Use the complete repository with its Julia environment already installed.
Setup is centralized in `__Start here!__/Windows`, `Linux` and `Mac`.
There is no separate Boxer setup script.

From the repository root, with a **current** local sysimage:

```powershell
python -B utils/python_client/wingbox_sizing_demo.py --output C:\runs\warm_wingbox_001
```

```bash
python3 -B utils/python_client/wingbox_sizing_demo.py --output /tmp/warm_wingbox_001
```

The output directory must not exist. The script generates the model once,
starts the worker once, runs the sizing loop, writes the results and closes
the worker. It does not start the Boxer browser or a reference solver.
`examples/wingbox_sizing.toml` controls the intentionally slender starting
design. The default requests four modes per buckling subcase.

The supplied 64-node sample was verified to require **13 updates / 14 analyses**.
Its lowest factor starts at **0.320273** and finishes at **1.051519**. The final
four factors are **1.051519, 1.575257, 1.637356 and 1.896561**. The selected upper
skin PSHELL thickness grows from **0.7 mm** to **2.416590 mm**. Stopping follows
the actual factors; the loop does not force extra iterations after convergence.

Useful options:

```powershell
python -B utils/python_client/wingbox_sizing_demo.py --output C:\runs\warm_wingbox_002 `
  --input C:\models\wingbox.bdf --modes 4 --sysimage C:\images\OpenJFEM_sysimage.dll `
  --julia C:\Julia\bin\julia.exe --threads 2 --max-updates 250
```

On Linux/macOS, use `\` for command continuation. `--target`, `--factor` and
`--timeout` control the acceptance threshold, thickness multiplier and timeout
per request. `--no-sysimage` explicitly enables source loading for development;
it still keeps one warm process for the whole loop.
`--modes` is a count check and must match the deck/configuration's eigenvalue
request; it does not silently rewrite the EIGRL request.

## Image selection and first-use warmup

`--sysimage auto` selects `sysimage/OpenJFEM_sysimage.dll` (Windows), `.so`
(Linux) or `.dylib` (macOS). An explicit image is supported too. Before loading
either, the client runs the existing provenance checker in a bare Julia
process. A missing or stale receipt, changed source/package lock, different
Julia runtime, moved checkout or modified image causes a clear startup error.
An existing file alone is not evidence that its compiled code is current.

Refresh the image with the central setup launcher, optionally passing
`--deck <representative.bdf>` to train the relevant solve path. The Julia helper
can also build an image directly:

```powershell
julia --startup-file=no --project=. utils/julia_tools/deploy_fast.jl `
  --deck C:\models\wingbox.bdf --sysimage=sysimage/OpenJFEM_sysimage.dll
```

Use the platform's `.so` or `.dylib` filename on Linux/macOS. Image building
can take substantial time; reuse a current image across runs. The first solve
may still compile specializations not present in its training workload. The
history records that first call separately instead of claiming it is already
steady-state performance.

## The iteration and its physical meaning

1. Boxer builds geometry, mesh, properties, supports and fixed external loads,
   then writes one standalone `wingbox.bdf`.
2. Python calls `load_model` once. Julia parses the BDF, resolves the model and
   retains a clean baseline. The returned property table contains eligible
   **PSHELL thickness** variables in metres.
3. Python calls `solve_model`. JFEM rebuilds elastic stiffness, solves the
   static preload, builds geometric stiffness and extracts the requested
   buckling modes.
4. JFEM identifies the lowest positive mode across the selected subcases and
   evaluates each element's elastic strain energy, `0.5 * phi_e' * K_e * phi_e`,
   using the production transformed stiffness matrices. It sums energy by PID.
5. Python chooses the **largest strain-energy contribution among updateable
   PSHELL properties**, with PID as a deterministic tie-break. It sends the
   absolute new thickness, `t_new = 1.1 * t_old`, for that PID.
6. Repeat in the same process until all returned factors exceed the target.

Eigenvalues belong to the full model, not individual properties. The energy
ranking is a practical localization heuristic for selecting a design variable;
it does not assign a fictitious local eigenvalue to a property. Energy scales
with the eigenvector's arbitrary amplitude, so normalized energy fractions
are reported. Beam/rod and other supported element contributions remain in
the total energy, but this template sizes isotropic shell thicknesses only.

The worker uses JFEM's existing ESE recovery, which captures another production
stiffness assembly for energy evaluation. No eigenvectors or element matrices
cross the Python pipe. A changed thickness invalidates stiffness, preload and
geometric stiffness, so those are recomputed. The parsed geometry and compiled
code are retained; matrix factorizations are not reused across changed designs.
Each solve gets a fresh working copy of the parsed baseline to prevent stale
mutable solver state from contaminating the next design.

This is a sizing heuristic and a connection template, not a minimum-mass
optimizer. Arbitrary models may need additional design variables, constraints,
mode-cluster treatment or a sensitivity-based selection strategy. Reaching
`max-updates` is an explicit failure. The example accepts finite positive roots
only and requires the configured mode count in every returned subcase. Empty,
missing, non-finite or incomplete spectra cannot count as convergence.

## Minimal application code

```python
from pathlib import Path
from utils.python_client.jfem_client import JFEMWorker
from utils.python_client.wingbox_sizing_demo import checked_design

with JFEMWorker(repo_root=Path.cwd(), sysimage="auto", threads="1") as jfem:
    info = jfem.load_model("wingbox.bdf")
    revision = info["revision"]
    patch = {}
    for update in range(251):
        result = jfem.solve_model(thicknesses=patch,
                                  expected_revision=revision, expected_modes=4)
        revision = result["revision"]
        minimum, controlling = checked_design(result, expected_modes=4)
        if minimum > 1.0:
            break
        if update == 250:
            raise RuntimeError("Sizing did not converge")
        pid = str(controlling["pid"])
        patch = {pid: 1.1 * result["thicknesses"][pid]}
```

The adapter sends a small JSON line containing only the changed PID/value.
Thicknesses are **absolute**, not multiplicative worker commands, which avoids
accidental double application. `expected_revision` detects a stale caller.
Updates commit only after a complete successful solve and energy recovery.
Invalid requests leave the stored design unchanged. Requests on one client
are serialized; use one worker per independent concurrent design stream.

The existing `run_batch` interface remains available for independent decks.
Use in-memory sessions for repeated property changes to one fixed topology.

## Protocol and returned data

Stdout contains exactly one JSON object per line. Diagnostics go to stderr.
The Python client matches request IDs, checks startup readiness and handles
timeouts. It terminates only its owned child if a request times out. Context
manager exit requests a graceful shutdown and waits for the actual process exit.

| Command | Main fields | Result |
| --- | --- | --- |
| `status` | none | Worker PID/session, counters, loaded model IDs. |
| `load_model` | `input`, optional `model_id` | Active PSHELL table, input hash, revision 0. |
| `solve_model` | `model_id`, `thicknesses`, optional `expected_revision`, `expected_modes` | Spectra, critical-mode identity, property energies, full current thickness table and timing. |
| `unload_model` | `model_id` | Releases that parsed baseline. |
| `run_batch` | `manifest` or `manifest_data` | Existing file-based batch result summary. |
| `gc`, `quit` | none | Explicit collection or graceful shutdown. |

`solve_model` returns `pid`, `worker_session_id`, `parse_count`, `solve_count`
and `revision`. The demo asserts the same PID/session and `parse_count == 1`
throughout. The ready reply records the actual Julia image path.

## Outputs and replay

| File | Contents |
| --- | --- |
| `model/wingbox.bdf`, `model/boxer_input.toml` | Original Boxer-generated model and input parameters (when generation is requested). |
| `generation.log`, `worker.log` | Generator and persistent-worker diagnostics. |
| `worker_ready.json`, `loaded_model.json` | Runtime identity and initial property table. |
| `iteration_NNN.json` | Complete compact response for each analysis. |
| `history.csv` | Root, selected PID, applied thickness change, request time and worker identity. |
| `final_thicknesses.json` | Absolute thicknesses for replay. |
| `summary.json` | Convergence status, update count, final roots, elapsed time and actual worker exit code. |

Load the original BDF into a new session and pass `final_thicknesses.json` as
`thicknesses` to replay the final design. The original deck is kept unchanged;
the iteration operates on the model in memory. External loads remain fixed in
the demonstration. If your loads depend on the updated mass or geometry, update
them explicitly in an extended protocol or regenerate the relevant model data.

Topology, materials and laminate/beam sizing are outside this initial session
adapter. Load a new model ID for a different topology. Only setup and the initial
Boxer generation are separate one-time processes; the sizing loop uses one
persistent solver process.

## Client checks

Run the acceptance, timeout, response-ID and UTF-8 transport checks from the
repository root:

```powershell
python -B -m unittest discover -s utils/python_client -p "test_*.py" -v
```

These use small protocol fixtures. Run the full sizing demo for a real
finite-element integration check; inspect its PID/session and iteration history.
