# Shared before-import defaults for ordinary application/package loading.
# Explicit user settings and explicit image-builder settings take precedence.
function configure_compilation_defaults!(environment=ENV)
    get!(environment,"JULIA_NUM_PRECOMPILE_TASKS","1")
    get!(environment,"JULIA_IMAGE_THREADS","1")
    get!(environment,"JFEM_SOL105_PRECOMPILE_WORKLOAD","false")
    environment
end
configure_compilation_defaults!()

"""Consume the common launcher option before application-specific parsing."""
function consume_no_sysimage_option!(args,environment=ENV)
    filter!(args) do argument
        if argument=="--no-sysimage"
            environment["JFEM_NO_SYSIMAGE"]="1"
            false
        else
            true
        end
    end
    args
end
