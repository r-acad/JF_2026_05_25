"""Supervise an optional image build and retain memory for the running apps."""
module JFEMSysimageBuildGuard

using TOML

const GIB = UInt64(1024)^3
const MINIMUM_AVAILABLE = 16GIB
const MINIMUM_RESERVE = 2GIB

struct BuildUnavailable <: Exception
    reason::Symbol
    message::String
    directory::String
end

Base.showerror(io::IO, failure::BuildUnavailable) = print(io, failure.message)

function memory_snapshot()
    try
        available = UInt64(Sys.free_memory())
        total = UInt64(Sys.total_memory())
        total > 0 && available <= total || return nothing
        return (; available, total)
    catch
        return nothing
    end
end

function sample_memory(probe)
    try
        probe()
    catch
        nothing
    end
end

gibibytes(bytes) = string(round(bytes / GIB; digits=1), " GiB")
memory_reserve(snapshot) = max(MINIMUM_RESERVE, snapshot.total ÷ 10)

# These layouts follow JOBOBJECT_EXTENDED_LIMIT_INFORMATION. UInt gives the
# platform SIZE_T/ULONG_PTR layout used by the supported Windows Julia runtime.
struct BasicJobLimits
    process_time::Int64
    job_time::Int64
    flags::UInt32
    minimum_working_set::UInt
    maximum_working_set::UInt
    active_process_limit::UInt32
    affinity::UInt
    priority_class::UInt32
    scheduling_class::UInt32
end

struct JobIOCounters
    read_operations::UInt64
    write_operations::UInt64
    other_operations::UInt64
    read_bytes::UInt64
    write_bytes::UInt64
    other_bytes::UInt64
end

struct ExtendedJobLimits
    basic::BasicJobLimits
    io::JobIOCounters
    process_memory::UInt
    job_memory::UInt
    peak_process_memory::UInt
    peak_job_memory::UInt
end

mutable struct OwnedBuild
    process::Base.Process
    job::Ptr{Cvoid}
    group_id::Int32
end

function create_windows_job()
    job = ccall((:CreateJobObjectW, "kernel32"), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{UInt16}), C_NULL, C_NULL)
    job == C_NULL && error("Could not create an isolated image-build job")
    limits = ExtendedJobLimits(
        BasicJobLimits(0, 0, 0x2000, 0, 0, 0, 0, 0, 0),
        JobIOCounters(0, 0, 0, 0, 0, 0), 0, 0, 0, 0)
    configured = ccall((:SetInformationJobObject, "kernel32"), Cint,
        (Ptr{Cvoid}, Cint, Ref{ExtendedJobLimits}, UInt32), job, 9, limits, sizeof(limits))
    if configured == 0
        ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), job)
        error("Could not configure image-build child cleanup")
    end
    job
end

function assign_windows_job(job, process)
    # AssignProcessToJobObject requires PROCESS_SET_QUOTA and PROCESS_TERMINATE.
    handle = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Cint, UInt32), 0x0101, 0, getpid(process))
    handle == C_NULL && error("Could not open the image-build process for isolation")
    try
        assigned = ccall((:AssignProcessToJobObject, "kernel32"), Cint,
            (Ptr{Cvoid}, Ptr{Cvoid}), job, handle)
        assigned != 0 || error("Could not isolate the image-build process tree")
    finally
        ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), handle)
    end
end

function stop_unassigned_process(process)
    process_running(process) || return
    if Sys.iswindows()
        command = Cmd(`taskkill /PID $(getpid(process)) /T /F`; windows_hide=true)
        try
            run(pipeline(ignorestatus(command); stdout=devnull, stderr=devnull))
        catch
        end
        process_running(process) && kill(process)
    else
        kill(process)
    end
    try
        wait(process)
    catch
    end
end

function start_owned_build(command, log)
    job = Sys.iswindows() ? create_windows_job() : C_NULL
    process = nothing
    try
        isolated = Sys.iswindows() ? Cmd(command; windows_hide=true) : detach(command)
        process = run(pipeline(ignorestatus(isolated); stdout=log, stderr=log); wait=false)
        group_id = getpid(process)
        Sys.iswindows() && assign_windows_job(job, process)
        OwnedBuild(process, job, group_id)
    catch
        process === nothing || stop_unassigned_process(process)
        job == C_NULL || ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), job)
        rethrow()
    end
end

function close_owned_build!(owned)
    if Sys.iswindows()
        if owned.job != C_NULL
            ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), owned.job)
            owned.job = C_NULL
        end
    else
        # The detached command owns this process group, including compiler
        # descendants that could survive an early exit of the builder itself.
        ccall(:kill, Cint, (Cint, Cint), -owned.group_id, Base.SIGTERM)
        sleep(0.1)
        ccall(:kill, Cint, (Cint, Cint), -owned.group_id, Base.SIGKILL)
    end
    try
        wait(owned.process)
    catch
    end
end

"""Run one owned compiler tree, stopping it if available memory becomes low."""
function run_build(command; log_root, memory_probe=memory_snapshot, sample_interval=1.)
    initial = sample_memory(memory_probe)
    initial === nothing && throw(BuildUnavailable(:memory_unknown,
        "Available memory could not be measured", ""))
    initial.available >= MINIMUM_AVAILABLE || throw(BuildUnavailable(:low_memory,
        "Available memory is $(gibibytes(initial.available)); image creation needs $(gibibytes(MINIMUM_AVAILABLE)) of free memory", ""))

    mkpath(log_root)
    directory = mktempdir(log_root; prefix="setup_", cleanup=false)
    log_path = joinpath(directory, "compiler.log")
    status = Dict{String,Any}("status"=>"starting", "initial_available_bytes"=>initial.available,
        "minimum_available_bytes"=>MINIMUM_AVAILABLE, "reserve_bytes"=>memory_reserve(initial))
    started = time()
    owned = nothing
    try
        open(log_path, "w") do log
            owned = start_owned_build(command, log)
            status["builder_pid"] = owned.group_id
            status["status"] = "running"
            while process_running(owned.process)
                current = sample_memory(memory_probe)
                current === nothing && throw(BuildUnavailable(:memory_unknown,
                    "Memory monitoring became unavailable", directory))
                current.available >= memory_reserve(current) || throw(BuildUnavailable(:low_memory,
                    "Available memory fell below $(gibibytes(memory_reserve(current))) while creating the image", directory))
                sleep(sample_interval)
            end
            success(owned.process) || throw(BuildUnavailable(:compiler_failed,
                "The image compiler stopped with exit code $(owned.process.exitcode)", directory))
            status["status"] = "complete"
        end
    catch failure
        status["status"] = "stopped"
        status["message"] = sprint(showerror, failure)
        failure isa InterruptException && rethrow()
        failure isa BuildUnavailable && rethrow()
        throw(BuildUnavailable(:compiler_failed, sprint(showerror, failure), directory))
    finally
        owned === nothing || close_owned_build!(owned)
        status["elapsed_seconds"] = time() - started
        open(joinpath(directory, "status.toml"), "w") do io
            TOML.print(io, status)
        end
    end
    directory
end

end
