using Test
include(joinpath(@__DIR__,"../src/native_windows_dialog.jl"))
include(joinpath(@__DIR__,"../src/native_dialogs.jl"))
const D=JFEMWindowsDialog
@testset "Script-free native dialog ABI and safe capability selection" begin
    @test sizeof(D.OpenFileNameW)==(Sys.WORD_SIZE==64 ? 152 : 88)
    @test fieldoffset(D.OpenFileNameW,8)==(Sys.WORD_SIZE==64 ? 48 : 28)
    @test D.wide("A\u03b2")==UInt16[0x41,0x03b2,0]
    @test D.choices(:save,"Test.toml","auto").extension=="toml"
    @test D.choices(:save,"Test.wingfem.json","auto").extension=="json"
    @test occursin("*.inp.gz",D.choices(:open,"","abaqus").filter)
    @test_throws ArgumentError D.request(:bad)
    @test_throws ArgumentError D.request(:save;name="bad\0name")
    @test_throws ArgumentError D.request(:open;format="bad")
    selected=Sys.iswindows() ? raw"C:\Chosen folder\unicode "*"\u03b2.wingfem.json" : "/Chosen folder/unicode \u03b2.wingfem.json"
    callback=(mode,ref)->begin
        @test mode===:save
        record=ref[]
        @test record.size==sizeof(D.OpenFileNameW)
        @test record.flags&0x00010000!=0 # picker never creates a test file
        units=D.wide(selected)
        for (i,value) in enumerate(units);unsafe_store!(record.file,value,i);end
        GC.gc(false) # backing buffers must remain rooted across native calls
        Cint(1)
    end
    @test D.choose(:save;name="Study.wingfem.json",invoke=callback)==selected
    @test D.choose(:open;invoke=(args...)->0,extended_error=()->0)===nothing
    @test_throws ErrorException D.choose(:open;invoke=(args...)->0,extended_error=()->0x3002)
    @test native_windows_dialog_result("CANCEL\r\n")["cancelled"]
    @test native_windows_dialog_result("PATH\t"*selected*"\r\n")["path"]==selected
    @test_throws ErrorException native_windows_dialog_result("unexpected response")
    command=native_windows_dialog_command(:save;name="Study file.wingfem.json",initial="Chosen folder")
    @test command.exec[end-3:end]==["save","Study file.wingfem.json","Chosen folder","auto"]
    @test any(endswith("native_windows_dialog.jl"),command.exec)
    @test !occursin("powershell",lowercase(join(command.exec," ")))
    @test !occursin("executionpolicy",lowercase(join(command.exec," ")))
end
