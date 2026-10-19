# Native card capability inventory, shared by parsing and solver entry points.
function _report_card_inventory(cards)
    processed = Set(["GRID", "GRDSET", "CORD2R", "CORD1R", "CORD1C", "CORD1S", "CORD2C", "CORD2S",
        "CTRIA3", "CTRIA6", "CQUAD4", "CQUADR", "CQUAD8", "CSHEAR", "CBAR", "CBEAM", "CROD", "CONROD", "CELAS1", "CELAS2", "CBUSH",
        "RBE1", "RBE2", "RBE3", "RBAR", "RSPLINE",
        "PSHELL", "PSHEAR", "PBARL", "PBAR", "PBAR*", "PBEAM", "PBEAM*", "PBEAML", "PROD", "PCOMP", "PELAS", "PBUSH", "PSOLID",
        "MAT1", "MAT2", "MAT8", "MATT1", "TABLEM1",
        "DESVAR", "DRESP1", "DVPREL1", "DVMREL1", "DCONSTR", "DOPTPRM",
        "FORCE", "MOMENT", "PLOAD4", "PLOAD2", "PLOAD", "PLOAD1", "GRAV", "RFORCE", "ACCEL1",
        "SPC1", "SPC", "SPCADD", "SPCD", "MPC", "MPCADD", "LOAD",
        "CONM2", "CONM1", "CMASS1", "CMASS2", "PMASS",
        "CTETRA", "CHEXA", "CPENTA",
        "EIGRL", "EIGB", "NLPARM", "TEMP", "TEMPD", "DMIG", "PARAM"])
    unprocessed = Dict{String,Int}()
    for (cname, clist) in cards
        if cname == "ACCEL"
            println("    ACCEL: $(length(clist)) retained unsupported load card(s); selecting one raises a capability error.")
            continue
        end
        if !(cname in processed)
            unprocessed[cname] = length(clist)
        end
    end
    if !isempty(unprocessed)
        println("    WARNING: $(length(unprocessed)) unprocessed card type(s):")
        for (cname, cnt) in sort(collect(unprocessed), by=x->x[1])
            println("      $cname: $cnt")
        end
    end
end
