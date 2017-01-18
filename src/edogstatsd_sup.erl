-module(edogstatsd_sup).
-behaviour(supervisor).
-export([init/1]).
-export([start_link/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    ok = edogstatsd_udp:init(stillir:get_config(dogstatsd, agent_address),
                             stillir:get_config(dogstatsd, agent_port)),

    Children = case stillir:get_config(dogstatsd, vm_stats) of
        true -> [#{
                   id => dogstatsd_vm_stats,
                   start => {edogstatsd_vm_stats, start_link, []},
                   restart => permanent,
                   shutdown => brutal_kill
                 }];
        false ->
            []
    end,
    SupFlags = #{
      strategy => one_for_one,
      intensity => 5,
      period => 60
     },
    new_to_old({ok, {SupFlags, Children}}).

new_to_old({ok, {SupFlags, Children}}) ->
    {ok, {new_to_old_supflags(SupFlags), new_to_old_children(Children)}}.
new_to_old_supflags(#{strategy := S, intensity := I, period := P}) ->
    {S, I, P}.
new_to_old_children(Children) ->
    lists:map(fun (Child = #{id := Id, start := Start, restart := Restart, shutdown := Shutdown}) ->
                      Type = maps:get(type, Child, worker),
                      {StartModule,_,_} = Start,
                      Modules = maps:get(modules, Child, [StartModule]),
                      {Id, Start, Restart, Shutdown, Type, Modules}
              end,
              Children).
