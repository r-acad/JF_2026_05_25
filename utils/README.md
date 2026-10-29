# Supporting files

Install and launch JFEM from [Start here](<../__Start here!__/README.md>).
These supporting files are grouped here to keep the repository root and
operating-system setup folders easy to navigate.

| Folder | Contents |
| --- | --- |
| [examples](examples/precompile/README.md) | Small bundled decks for trying the solver and compiling the shared Julia image; batch manifests are under `examples/manifests/`. |
| [images](images/README.md) | Screenshots and illustrations used by the guides. |
| [julia_tools](julia_tools/README.md) | Shared installation, launch, batch, worker and image-build helpers used by all applications. |
| [python_client](python_client/README.md) | Standard-library Python interface, persistent model sessions and a Boxer wing-box thickness-sizing demonstration. |
| [test](test/README.md) | Maintained solver and installation regression checks. |

All applications and helpers use the repository-root `Project.toml` and
`Manifest.toml`; this folder does not create a separate Julia environment.
Generated results and machine-specific images stay in the ignored `output/`
and `sysimage/` folders, outside `utils/`.
