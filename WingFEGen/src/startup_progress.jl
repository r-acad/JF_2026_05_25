# Separate lightweight process: the clock stays alive while the app compiles.
# EOF closes it even if the parent terminates unexpectedly.
started = time()
finished = Ref(false)
stage = Ref("Loading Julia packages and wing generator")
@async try
    for line in eachline(stdin)
        stage[] = line
    end
finally
    finished[] = true
end
last_print = -2.0
while !finished[]
    elapsed = time() - started
    if elapsed - last_print >= 2
        seconds = floor(Int, elapsed)
        println(stdout, "  [", div(seconds, 60), ":", lpad(mod(seconds, 60), 2, '0'), "] ", stage[], "…")
        flush(stdout)
        global last_print = elapsed
    end
    sleep(0.1)
end
