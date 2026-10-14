# Base-only so progress and structured errors remain available before imports.
module SensitivityFileIO

struct SharingViolation <: Exception
    path::String
    code::UInt32
end
Base.showerror(io::IO, error::SharingViolation) = print(io, "Windows file sharing violation (", error.code, ") replacing ", error.path)

function readonly_file(path)
    wide=transcode(UInt16,path*'\0')
    attributes=ccall((:GetFileAttributesW,"kernel32"),UInt32,(Ptr{UInt16},),wide)
    attributes!=typemax(UInt32)&&attributes&UInt32(1)!=0
end

function replace_file(source, destination)
    if Sys.iswindows()
        # MoveFileEx replaces atomically without first unlinking the old file.
        # Distinguish sharing/lock violations from permission and disk errors.
        from = transcode(UInt16, source * '\0')
        to = transcode(UInt16, destination * '\0')
        success = ccall((:MoveFileExW, "kernel32"), Int32,
            (Ptr{UInt16}, Ptr{UInt16}, UInt32), from, to, 0x00000001)
        if success == 0
            code = ccall((:GetLastError, "kernel32"), UInt32, ())
            # Windows also returns ACCESS_DENIED during a short reader/replace
            # race; probing after the failure cannot reliably observe that lock.
            # Read-only files are permanent errors. Other access/sharing errors
            # get bounded retries; critical result/request writes still throw.
            (code in (UInt32(32), UInt32(33)) || code==UInt32(5)&&
                !readonly_file(destination)&&!readonly_file(source)) && throw(SharingViolation(destination, code))
            throw(ErrorException("Windows atomic replacement failed (error $code): $destination"))
        end
    else
        Base.Filesystem.rename(source, destination)
    end
    destination
end

retryable(error) = error isa SharingViolation || error isa Base.IOError && error.code == Base.UV_EBUSY

function read_text(path;attempts=8,initial_delay=0.005,max_delay=0.05)
    for attempt in 1:attempts
        try
            return read(path,String)
        catch error
            busy=retryable(error)||Sys.iswindows()&&((error isa SystemError&&error.errnum in (Base.Libc.EACCES,Base.Libc.EPERM))||
                (error isa Base.IOError&&error.code in (Base.UV_EACCES,Base.UV_EPERM)))
            busy&&attempt<attempts||rethrow()
            sleep(min(max_delay,initial_delay*2.0^(attempt-1)))
        end
    end
end

"""Atomic publication; only progress may defer after bounded sharing retries.

Requests, results and errors remain strict. No solver exception is intercepted.
A deferred progress update retains the previous complete JSON; the next update
publishes the latest state. Final job status comes from the worker and result.
"""
function write_text(path::AbstractString, text::AbstractString; progress=false,
                    attempts=8, initial_delay=0.01, max_delay=0.1,
                    replace=replace_file, delay=sleep)
    attempts >= 1 || throw(ArgumentError("attempts must be positive"))
    destination=abspath(path)
    temporary, stream=mktemp(dirname(destination);cleanup=false)
    try
        try
            write(stream,text)
            flush(stream)
        finally
            close(stream)
        end
        for attempt in 1:attempts
            try
                replace(temporary,destination)
                return true
            catch error
                retryable(error) || rethrow()
                if attempt == attempts
                    progress && return false
                    rethrow()
                end
                delay(min(max_delay,initial_delay*2.0^(attempt-1)))
            end
        end
    finally
        isopen(stream) && close(stream)
        if isfile(temporary)
            try
                rm(temporary)
            catch error
                # Cleanup must not mask the write/solver exception. The uniquely
                # named temporary file is never treated as published progress.
                @warn "Could not remove sensitivity temporary file" path=temporary exception=error
            end
        end
    end
    false
end

end
