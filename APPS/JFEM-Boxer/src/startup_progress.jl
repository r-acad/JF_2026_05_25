# Separate lightweight process: the clock stays alive while the app compiles.
# EOF closes it even if the parent terminates unexpectedly.
started = time()
finished = Ref(false)
stage = Ref("Waiting for the launcher to report its first stage")
stage_started = Ref(started)
last_print = Ref(started)
function report_stage(message)
    seconds = floor(Int, time()-started)
    println(stdout, "  [", div(seconds,60), ":", lpad(mod(seconds,60),2,'0'), "] ", message)
    flush(stdout)
    last_print[] = time()
end
@async try
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        stage[] = line
        stage_started[] = time()
        report_stage(line)
    end
finally
    finished[] = true
end
while !finished[]
    if time() - last_print[] >= 5
        seconds = floor(Int,time()-stage_started[])
        report_stage("Still working: $(stage[]) (this stage: $(seconds) s)")
    end
    sleep(0.1)
end
