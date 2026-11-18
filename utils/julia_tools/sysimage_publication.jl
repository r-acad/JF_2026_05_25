module JFEMSysimagePublication

using Libdl

receipt_path(image) = image * ".jfem.toml"

function atomic_replace(source, destination)
    temporary, stream = mktemp(dirname(destination); cleanup=false)
    close(stream)
    try
        cp(source, temporary; force=true)
        # A same-directory rename exposes a complete file in one operation.
        Base.Filesystem.rename(temporary, destination)
    finally
        isfile(temporary) && rm(temporary)
    end
end

"""Publish a completed candidate and retain the prior pair for recovery."""
function publish_image(candidate, destination; validator=()->nothing)
    destination = abspath(destination)
    candidate = abspath(candidate)
    candidate == destination && error("Build into a separate candidate file before publication")
    candidate_receipt = receipt_path(candidate)
    isfile(candidate) && isfile(candidate_receipt) || error("Candidate image/receipt is incomplete")
    mkpath(dirname(destination))

    backup = joinpath(dirname(candidate), "previous-image." * Libdl.dlext)
    receipt = receipt_path(destination)
    backup_receipt = receipt_path(backup)
    had_image = isfile(destination)
    had_receipt = isfile(receipt)
    had_image && cp(destination, backup; force=true)
    had_receipt && cp(receipt, backup_receipt; force=true)

    receipt_replaced = false
    image_replaced = false
    try
        # A process stopped between these two complete-file replacements leaves
        # a checksum mismatch. Runtime image selection then uses normal Julia.
        atomic_replace(candidate_receipt, receipt)
        receipt_replaced = true
        atomic_replace(candidate, destination)
        image_replaced = true
        validator()
    catch
        # Restore the previous state on an ordinary publication/validation error.
        # Keep the candidate and backup in the build directory for diagnosis.
        try
            if image_replaced
                if had_image
                    atomic_replace(backup, destination)
                elseif isfile(destination)
                    rm(destination)
                end
            end
        finally
            if receipt_replaced
                if had_receipt
                    atomic_replace(backup_receipt, receipt)
                elseif isfile(receipt)
                    rm(receipt)
                end
            end
        end
        rethrow()
    end
    destination
end

end
