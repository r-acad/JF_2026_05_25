#!/usr/bin/env julia
"""Local browser-asset server only; no solver packages or analysis files are loaded."""
module JFEMResultsViewerServer
using HTTP

const VIEWER_PATH="/APPS/JFEM_results_viewer/postv11.html"
const ASSET_PATHS=(
    "APPS/JFEM_results_viewer/postv11.html",
    "APPS/JFEM_results_viewer/POST_GUIDE.html",
    "APPS/jfem_binary.js", "APPS/jfem_graphics.js",
    "APPS/PANDEATOR_APP/vendor/babylon.js",
    "APPS/PANDEATOR_APP/vendor/glslang/glslang.js",
    "APPS/PANDEATOR_APP/vendor/glslang/glslang.wasm",
    "APPS/PANDEATOR_APP/vendor/twgsl/twgsl.js",
    "APPS/PANDEATOR_APP/vendor/twgsl/twgsl.wasm",
)
const MIME=Dict(".html"=>"text/html; charset=utf-8", ".js"=>"application/javascript; charset=utf-8", ".wasm"=>"application/wasm")
repo_root()=normpath(joinpath(@__DIR__,"..",".."))

function options(args)
    port=0;browser=true;i=1
    while i<=length(args)
        arg=args[i]
        if arg in ("--help","-h")
            return nothing
        elseif arg=="--no-browser"
            browser=false
        elseif arg=="--port" || startswith(arg,"--port=")
            if arg=="--port"
                i+=1;i<=length(args)||error("--port requires a number")
                value=args[i]
            else
                value=chopprefix(arg,"--port=")
            end
            parsed=tryparse(Int,value)
            parsed!==nothing&&0<=parsed<=65535||error("Port must be 0 (automatic) or a number from 1 to 65535")
            port=parsed
        else
            error("Unknown results viewer option: $arg")
        end
        i+=1
    end
    (;port,browser)
end

function handle(request::HTTP.Request,root=repo_root())
    request.method in ("GET","HEAD")||return HTTP.Response(405,["Allow"=>"GET, HEAD"],"Read-only viewer server")
    path=try HTTP.unescapeuri(HTTP.URI(request.target).path) catch; return HTTP.Response(400,"Invalid URL") end
    path=="/"&&return HTTP.Response(302,["Location"=>VIEWER_PATH],"")
    path=="/favicon.ico"&&return HTTP.Response(204)
    path=="/health"&&return HTTP.Response(200,["Content-Type"=>"text/plain; charset=utf-8"],"results-viewer ready")
    # Exact public-asset names only: no directory listing, arbitrary paths,
    # deck/result downloads or access to any other repository directories.
    relative=startswith(path,"/") ? path[2:end] : ""
    relative in ASSET_PATHS||return HTTP.Response(404,"Not found")
    file=joinpath(root,split(relative,'/')...)
    isfile(file)||return HTTP.Response(404,"Bundled viewer asset missing; extract the complete repository again")
    headers=["Content-Type"=>MIME[lowercase(splitext(file)[2])],"Cache-Control"=>"no-cache","X-Content-Type-Options"=>"nosniff"]
    HTTP.Response(200,headers,request.method=="HEAD" ? UInt8[] : read(file))
end

function start_server(;root=repo_root(),port=0)
    for relative in ASSET_PATHS
        isfile(joinpath(root,split(relative,'/')...))||error("Bundled viewer asset missing: $relative. Extract the complete repository again.")
    end
    HTTP.serve!(request->handle(request,root),"127.0.0.1",port;verbose=false)
end

function open_browser(url)
    command=Sys.iswindows() ? `cmd /c start "" $url` : Sys.isapple() ? `open $url` : `xdg-open $url`
    run(command)
end

function main(args=ARGS)
    parsed=options(args)
    if parsed===nothing
        println("Usage: Results-viewer [--no-browser] [--port N]")
        println("Serves bundled viewer assets on this computer only. Port 0 chooses an available port.")
        return 0
    end
    server=start_server(;port=parsed.port)
    url="http://127.0.0.1:$(HTTP.port(server))$VIEWER_PATH"
    println("Results viewer ready: ",url)
    println("WebGPU is preferred when available. Keep this console open; Ctrl+C stops the viewer server.")
    println("Choose result files in the browser; this server does not expose your decks or results.")
    flush(stdout)
    try
        if parsed.browser
            try open_browser(url) catch error;println(stderr,"Open the printed address in your browser: ",sprint(showerror,error));end
        end
        wait(server)
    catch error
        error isa InterruptException||rethrow()
    finally
        close(server)
    end
    0
end
end

if abspath(PROGRAM_FILE)==abspath(@__FILE__)
    try
        exit(JFEMResultsViewerServer.main())
    catch error
        println(stderr,"Results viewer could not start: ",sprint(showerror,error))
        println(stderr,"Run setup for this checkout, or open APPS/JFEM_results_viewer/postv11.html directly for the offline WebGL viewer.")
        exit(1)
    end
end
