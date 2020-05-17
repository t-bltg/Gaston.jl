## Copyright (c) 2013 Miguel Bazdresch
##
## This file is distributed under the 2-clause BSD License.

# Asynchronously reads the specified IO.
# In case of timeout sends :timeout; in case of end of file, sends :eof.
function async_reader(io::IO, timeout_sec)::Channel
    ch = Channel(1)
    task = @async begin
        reader_task = current_task()
        function timeout_cb(timer)
            put!(ch, :timeout)
            Base.throwto(reader_task, InterruptException())
        end
        timeout = Timer(timeout_cb, timeout_sec)
        data = String(readavailable(io))
        if data == ""; put!(ch, :eof); return; end
        timeout_sec > 0 && close(timeout) # Cancel the timeout
        put!(ch, data)
    end
    bind(ch, task)
    return ch
end

# Write plotting data to file.
# `curve` is a Curve.
# `file` is the file to write to.
# If `append` is true, data is appended at the end of the file (for `plot!`)
# TODO: generalize to more formats
function write_data(curve, dims, file; append = false)
    mode = "w"
    append && (mode = "a")
    x = curve.x
    y = curve.y
    z = curve.z
    supp = curve.supp
    ps = curve.conf.plotstyle
    open(file, mode) do io
        # 2-d plot
        if dims == 2
            # image; format is "x y z" with reversed "y"
            if ndims(x) == 1 && ndims(y) == 1 && ndims(z) == 2
                xx = repeat(x,inner=length(y))
                yy = repeat(reverse(y),length(x))
                zz = vec(z)
                writedlm(io,[xx yy zz])
            # rgbimage; format is "x y r g b" with reversed "y"
            elseif ndims(z) == 3
                xx = repeat(x,inner=length(y))
                yy = repeat(reverse(y),length(x))
                r = vec(z[1,:,:])
                g = vec(z[2,:,:])
                b = vec(z[3,:,:])
                if isempty(supp)
                    writedlm(io,[xx yy r g b])
                else
                    writedlm(io,[xx yy r g b supp])
                end
            # regular plot
            else
                if isempty(supp)
                    data = [x y]
                else
                    data = [x y supp]
                end
                writedlm(io, data)
            end
        # 3-D image
        elseif dims == 3
            # surface plot
            if ndims(x) == 1 && ndims(y) == 1 && ndims(z) == 2
                for (yi,yy) in enumerate(y)
                    for (xi,xx) in enumerate(x)
                        write(io, "$xx $yy $(z[yi,xi])\n")
                    end
                    write(io, "\n")
                end
            # scatter plot
            elseif ndims(x) == 1 && ndims(y) == 1 && ndims(z) == 1
                if isempty(supp)
                    for k in 1:length(x)
                        write(io, "$(x[k]) $(y[k]) $(z[k])\n")
                    end
                else
                    for k in 1:length(x)
                        write(io, "$(x[k]) $(y[k]) $(z[k]) ")
                        s = string(supp[k,:])[2:end-1]
                        write(io, s, "\n")
                    end
                end
            # arbitrary plot
            elseif ndims(x) == 2 && ndims(y) == 2 && ndims(z) == 2
                for col = 1:size(x)[2]
                    writedlm(io, [x[:,col] y[:,col] z[:,col]])
                    write(io, "\n")
                end
            end
        end
        write(io,"\n\n")
    end
end

# llplot() is our workhorse plotting function
function llplot(fig::Figure;print=false)
    global gnuplot_state

    # if figure has no data, stop here
    if isempty(fig)
        return
    end

    gnuplot_send("\nreset session\n")

    # Send all commands to gnuplot
    # Build terminal setup string
    gnuplot_send(termstring(fig,print))
    # Build figure configuration string
    gnuplot_send(figurestring(fig))
    # Set output file if necessary
    print && gnuplot_send("set output '$(fig.print.output)'")
    # Send user command to gnuplot
    gnuplot_send(fig.gpcom)
    # send plot command to gnuplot
    gnuplot_send(plotstring(fig))
    # Close output files, if any
    gnuplot_send("set output")

    # Make sure gnuplot is done.
    err = ""
    gnuplot_state.gp_lasterror = err
    gnuplot_state.gp_error = false

    gnuplot_send("""set print '-'
                    print 'GastonDone'""")

    # Start reading gnuplot's streams in "background"
    ch_out = async_reader(P.gstdout, config[:timeouts][:stdout_timeout])
    out = take!(ch_out)
    out === :timeout && @warn("Gnuplot is taking too long to respond.")
    out === :eof     && error("Gnuplot crashed")

    # check for errors while plotting
    if bytesavailable(P.gstderr) > 0
        err = String(readavailable(P.gstderr))
        gnuplot_state.gp_lasterror = err
        gnuplot_state.gp_error = true
        @warn("Gnuplot returned an error message:\n  $err")
    end

    return nothing

end
