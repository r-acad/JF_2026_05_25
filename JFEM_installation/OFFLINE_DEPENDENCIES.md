# JFEM Julia dependencies (for offline / air-gapped installs)

Building the sysimage — or even just running JFEM — requires the project's Julia
packages to be present in the Julia depot (`~/.julia` by default). On a machine
with internet, `julia --project=. -e "using Pkg; Pkg.instantiate()"` downloads
them automatically. On an **offline** machine that download fails (errors like
`Connection reset by peer` / `failed to clone ... FileIO.jl`).

This file lists what must be present. **The authoritative, exact set is the
committed `Manifest.toml`** at the repository root — these tables are generated
from it for convenience.

> Julia version: the Manifest was resolved with Julia **1.12.3**. Use a
> **1.12.x** Julia on the target machine. Packages with native binaries
> (the `*_jll` entries) are **OS- and CPU-specific** — a Linux target needs the
> Linux artifacts; you cannot reuse a Windows depot.

## Direct dependencies (from `Project.toml`)

| Package | UUID | compat |
|---|---|---|
| AlgebraicMultigrid | 2169fc97-5a83-5252-b627-83903c6c433c | |
| Dates (stdlib) | ade2ca70-3891-5945-98fb-dc099432e06a | |
| ForwardDiff | f6369f11-7733-5829-9624-2563aa707210 | 1.3.3 |
| HDF5 | f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f | 0.17.2 |
| HTTP | cd3eb016-35fb-5094-929b-558a96fad6f3 | 1.11.0 |
| IterativeSolvers | 42fd0dbc-a981-5370-80f2-aaf504508153 | |
| JSON | 682c06a0-de6a-54ab-a142-c8b1cf79cde6 | |
| KrylovKit | 0b1a1467-8014-51b9-945f-bf0ae24f4b77 | 0.10.2 |
| LinearAlgebra (stdlib) | 37e2e46d-f89d-539d-b4ee-838fcccc9c8e | |
| MsgPack | 99f44e22-a591-53d1-9472-aa23ef4bd671 | 1.2.1 |
| NPZ | 15e1cf62-19b3-5cfa-8e77-841668bca605 | |
| PackageCompiler | 9b87118b-4619-50d2-8e1e-99f35a4d4d9d | 2.3.0 |
| PrecompileTools | aea7be01-6a6a-4083-8856-8a6e6704d82a | 1.3.4 |
| Printf (stdlib) | de0858da-6303-5e67-8744-51eddeeeb8d7 | |
| SparseArrays (stdlib) | 2f01184e-e22b-5df5-ae63-d93ebab69eaf | |
| StaticArrays | 90137ffa-7385-5640-81b9-e52037218182 | |
| Statistics (stdlib) | 10745b16-79ce-11e8-11f9-7d13ad32a3b2 | |
| WriteVTK | 64499a7a-5c06-52f2-abe2-ccb03c286192 | |

## Full transitive set (from `Manifest.toml`, 145 entries, exact versions)

`(stdlib)` ships with Julia itself; `*_jll` are native-binary artifacts (the
platform-specific ones). Everything else is a registered package.

```
ADTypes                       1.21.0
Accessors                     0.1.43
Adapt                         4.4.0
AlgebraicMultigrid            1.2.0
ArgTools                      (stdlib)
ArrayInterface                7.22.0
Artifacts                     (stdlib)
Base64                        (stdlib)
BitFlags                      0.1.9
ChainRulesCore                1.26.0
CodecZlib                     0.7.8
CommonSolve                   0.2.6
CommonSubexpressions          0.3.1
Compat                        4.18.1
CompilerSupportLibraries_jll  1.3.0+1
CompositionsBase              0.1.2
ConcreteStructs               0.2.3
ConcurrentUtilities           2.5.1
ConstructionBase              1.6.0
Dates                         (stdlib)
DiffResults                   1.1.0
DiffRules                     1.15.1
Distributed                   (stdlib)
DocStringExtensions           0.9.5
Downloads                     (stdlib)
EnumX                         1.0.6
ExceptionUnwrapping           0.1.11
ExprTools                     0.1.10
ExproniconLite                0.10.14
FileIO                        1.19.0
FileWatching                  (stdlib)
FillArrays                    1.16.0
ForwardDiff                   1.3.3
FunctionWrappers              1.1.3
FunctionWrappersWrappers      0.1.3
Future                        (stdlib)
GPUArraysCore                 0.2.0
Glob                          1.5.0
HDF5                          0.17.2
HDF5_jll                      1.14.6+0
HTTP                          1.11.0
Hwloc_jll                     2.12.1+0
IntelOpenMP_jll               2025.2.0+0
InteractiveUtils              (stdlib)
InverseFunctions              0.1.17
IrrationalConstants           0.2.6
IterativeSolvers              0.9.4
IteratorInterfaceExtensions   1.0.0
JLLWrappers                   1.7.1
JSON                          1.4.0
JUNASTRAN                     0.1.0
Jieko                         0.2.1
JuliaSyntaxHighlighting       (stdlib)
Krylov                        0.10.5
KrylovKit                     0.10.2
LazyArtifacts                 (stdlib)
LibCURL                       (stdlib)
LibCURL_jll                   8.15.0+0
LibGit2                       (stdlib)
LibGit2_jll                   1.9.0+0
LibSSH2_jll                   1.11.3+1
Libdl                         (stdlib)
Libiconv_jll                  1.18.0+0
LightXML                      0.9.3
LinearAlgebra                 (stdlib)
LinearSolve                   3.59.1
LogExpFunctions               0.3.29
Logging                       (stdlib)
LoggingExtras                 1.2.0
MKL_jll                       2025.2.0+0
MPICH_jll                     4.3.2+0
MPIPreferences                0.1.12
MPItrampoline_jll             5.5.5+0
MacroTools                    0.5.16
Markdown                      (stdlib)
MbedTLS                       1.1.10
MbedTLS_jll                   2.28.1010+0
MicrosoftMPI_jll              10.1.4+3
Mmap                          (stdlib)
Moshi                         0.3.7
MozillaCACerts_jll            2025.5.20
MsgPack                       1.2.1
NPZ                           0.4.3
NaNMath                       1.1.3
NetworkOptions                (stdlib)
OpenBLAS_jll                  0.3.29+0
OpenLibm_jll                  0.8.7+0
OpenMPI_jll                   5.0.10+0
OpenSSL                       1.6.1
OpenSSL_jll                   3.5.4+0
OpenSpecFun_jll               0.5.6+0
PackageCompiler               2.3.0
PackageExtensionCompat        1.0.2
Parsers                       2.8.3
Pkg                           (stdlib)
PreallocationTools            1.1.2
PrecompileTools               1.3.4
Preferences                   1.5.1
Printf                        (stdlib)
Random                        (stdlib)
RecipesBase                   1.3.4
RecursiveArrayTools           3.48.0
Reexport                      1.2.2
RelocatableFolders            1.0.1
Requires                      1.3.1
RuntimeGeneratedFunctions     0.5.17
SHA                           (stdlib)
SciMLBase                     2.142.0
SciMLLogging                  1.9.1
SciMLOperators                1.15.1
SciMLPublic                   1.0.1
SciMLStructures               1.10.0
Scratch                       1.3.0
Serialization                 (stdlib)
Setfield                      1.1.2
SimpleBufferStream            1.2.0
Sockets                       (stdlib)
SparseArrays                  (stdlib)
SpecialFunctions              2.7.2
StaticArrays                  1.9.17
StaticArraysCore              1.4.4
Statistics                    (stdlib)
StructUtils                   2.6.3
StyledStrings                 (stdlib)
SuiteSparse_jll               7.8.3+2
SymbolicIndexingInterface     0.3.46
TOML                          (stdlib)
Tar                           (stdlib)
Test                          (stdlib)
TimerOutputs                  0.5.29
TranscodingStreams            0.11.3
URIs                          1.6.1
UUIDs                          (stdlib)
Unicode                       (stdlib)
VTKBase                       1.0.1
VectorInterface               0.5.0
WriteVTK                      1.21.2
XML2_jll                      2.15.1+0
ZipFile                       0.10.1
Zlib_jll                      1.3.1+2
libaec_jll                    1.1.6+0
libblastrampoline_jll         5.15.0+0
nghttp2_jll                   1.64.0+1
oneTBB_jll                    2022.0.0+1
p7zip_jll                     17.7.0+0
```

## Getting these onto an offline machine

The reliable way is to **populate a Julia depot on a connected machine of the
SAME OS** (here: Linux) and copy it over — do NOT copy a Windows depot to Linux,
the `*_jll` binaries are wrong.

On a connected **Linux** machine (a laptop, a VM, or WSL2 all work):

```bash
# 1) Same Julia 1.12.x and the JFEM repo on the connected machine.
cd /path/to/JFEM
export JULIA_DEPOT_PATH="$PWD/offline_depot"          # collect into a portable folder
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
# PackageCompiler is already a dependency, so instantiate pulls it in.

# 2) Bundle the depot (packages, artifacts, registries, compiled cache):
tar czf jfem_julia_depot_linux.tgz -C "$PWD" offline_depot
```

On the **offline** machine:

```bash
cd /path/to/JFEM                       # the JF_2026_05_25 folder
tar xzf jfem_julia_depot_linux.tgz     # creates ./offline_depot
export JULIA_DEPOT_PATH="$PWD/offline_depot"
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh     # now finds everything locally, no internet
```

Set `JULIA_DEPOT_PATH` the same way before running `./jfem` or
`POST/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh`
so they use the bundled depot.

### Alternative: ask IT for a Julia package-server mirror
If your site can expose an internal mirror, set one env var and the normal build
works with no copying:

```bash
export JULIA_PKG_SERVER="https://<your-internal-mirror>"
# (or a proxy:  export HTTPS_PROXY=http://proxy:port  HTTP_PROXY=http://proxy:port)
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
```
