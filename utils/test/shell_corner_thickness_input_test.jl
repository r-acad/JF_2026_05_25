module ShellCornerThicknessInputTests
using Test,OpenJFEM
const P=OpenJFEM.ReferenceParser
const S=OpenJFEM.Solver

function lines(n,ti,flag;format=:free,marker=false)
    head=n==4 ? "CQUAD4" : "CTRIA3"
    first=n==4 ? ["1","1","1","2","3","4","12.","-.03"] :
                 ["1","1","1","2","3","12.","-.03",""]
    last=["",string(flag),ti...]
    append!(last,fill("",8-length(last)))
    if format==:free
        return [join([head;first;marker ? ["+ABC"] : String[]],","),join(["+";last],",")]
    elseif format==:small
        return [rpad(head,8)*join(rpad.(first,8)),rpad("+",8)*join(rpad.(last,8))]
    end
    data=[first;last]
    [rpad(i==1 ? head*"*" : "*",8)*join(rpad.(data[i:i+3],16)) for i in 1:4:16]
end

function parse(lines)
    cards=P.process_cards(lines)
    only(values(P.extract_shells(only(values(cards)))))
end

@testset "Shell thickness input retains physical field positions" begin
    for n in (3,4),format in (:free,:small,:large),flag in (0,1)
        ti=([".002","","2.7-3","+0.004"])[1:n]
        for marker in (false,true)
            format!=:free && marker && continue
            el=parse(lines(n,ti,flag;format,marker))
            @test el["NODES"]==collect(1:n)
            @test el["THETA"]==12.
            @test el["ZOFFS"]==-.03
            @test el["TFLAG"]==flag
            @test el["CORNER_THICKNESSES_SPECIFIED"]
            @test el["CORNER_THICKNESSES"]==([.002,nothing,.0027,.004])[1:n]
            d=S.shell_corner_thickness_data(el,Dict("T"=>.003))
            @test d.thickness==[(v===nothing ? .003 : flag==1 ? v*.003 : v) for v in el["CORNER_THICKNESSES"]]
            @test !d.uniform
        end
    end
    for n in (3,4)
        # An omitted continuation and an explicit all-blank continuation retain
        # distinct input metadata, while both inherit the original property.
        ls=lines(n,fill("",n),"")
        no=parse(ls[1:1]);blank=parse(ls)
        @test !no["CORNER_THICKNESSES_SPECIFIED"]
        @test blank["CORNER_THICKNESSES_SPECIFIED"]
        @test all(isnothing,no["CORNER_THICKNESSES"])
        @test S.shell_corner_thickness_data(no,Dict("T"=>.003))===nothing
        @test S.shell_corner_thickness_data(blank,Dict("T"=>.003))===nothing
        for value in ("0.","-.001","NaN","Inf","bad")
            @test_throws ArgumentError parse(lines(n,fill(value,n),0))
        end
        for flag in ("-1","2","0.5","bad","NaN")
            @test_throws ArgumentError parse(lines(n,fill(".002",n),flag))
        end
        el=parse(lines(n,fill(".004",n),0));prop=Dict("T"=>.003)
        before=deepcopy(prop)
        d=S.shell_corner_thickness_data(el,prop)
        @test d.uniform && all(==(.004),d.thickness)
        @test prop==before
        d=S.shell_corner_thickness_data(el,Dict("T"=>0.))
        @test d.uniform && d.reference_thickness==.004
        el=parse(lines(n,fill("2.",n),1))
        @test S.shell_corner_thickness_data(el,prop).thickness==fill(.006,n)
        @test_throws ArgumentError S.shell_corner_thickness_data(el,Dict("T"=>0.))
        @test_throws ArgumentError S.shell_corner_thickness_data(el,Dict("T"=>.003,"TYPE"=>"PCOMP_CLT"))
        el["CORNER_THICKNESSES"]=fill(.002,n-1)
        @test_throws ArgumentError S.shell_corner_thickness_data(el,prop)
    end
    # Raw-model builds receive the same validation as card input.
    el=Dict("ID"=>7,"TYPE"=>"CQUAD4","TFLAG"=>0,"CORNER_THICKNESSES"=>Any[.002,nothing,.004,.005])
    @test_throws ArgumentError S.shell_corner_thickness_data(el,Dict("T"=>0.))
    el["TFLAG"]=1.5
    @test_throws ArgumentError S.shell_corner_thickness_data(el,Dict("T"=>.003))
    el["TFLAG"]=0;el["CORNER_THICKNESSES"][1]=0.
    @test_throws ArgumentError S.shell_corner_thickness_data(el,Dict("T"=>.003))
end
end
