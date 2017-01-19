-module(rebar_gdb_plugin).
-compile(export_all).

%% can also come in handy: https://sideshowcoder.com/post/tag/gdb and
%% https://groups.google.com/forum/#!topic/erlang-programming/Gz2zbQjC144
%% TL;DR: vi $(which erl) and
%%
%% if [ ! -z "$USE_GDB" ]; then
%% gdb $BINDIR/erlexec --args $BINDIR/erlexec ${1+"$@"}
%% else
%% exec $BINDIR/erlexec ${1+"$@"}
%% fi
%%
%% or else gdb --eval-command=run --eval-command=quit $BINDIR/erlexec --args $BINDIR/erlexec ${1+"$@"}

pre_eunit(_Config, _AppFile) ->
    case os:getenv("USE_GDB") of
        false ->
            ok;
        _ ->
            Prompt = io_lib:format("GDB Attach to: ~s~n", [os:getpid()]),
            io:get_line(Prompt)
    end,
    ok.

