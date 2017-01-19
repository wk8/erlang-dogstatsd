-module(edogstatsd_app).
-behaviour(application).
-export([start/2, stop/1]).
-export([configure/0]).

start(_Type, _Args) ->
    configure(),
    edogstatsd_sup:start_link().

stop(_State) ->
    ok.

configure() ->
    Config = [
              {agent_address, "AGENT_ADDRESS", [{default, "localhost"}]}
             ,{agent_port, "AGENT_PORT", [{default, 8125}, {transform, integer}]}
             ,{global_prefix, "GLOBAL_PREFIX", [{default, ""}]}
             ,{global_tags, "GLOBAL_TAGS", [{default, #{}}, {transform, fun transform_map/1}]}
             ,{send_metrics, "SEND_METRICS", [{default, true}, {transform, fun transform_boolean/1}]}
             ,{vm_stats, "VM_STATS", [{default, true}, {transform, fun transform_boolean/1}]}
             ,{vm_stats_delay, "VM_STATS_DELAY", [{default, 60000}, {transform, integer}]}
             ,{vm_stats_scheduler, "VM_STATS_SCHEDULER", [{default, true}, {transform, fun transform_boolean/1}]}
             ,{vm_stats_base_key, "VM_STATS_BASE_KEY", [{default, "erlang.vm"}]}
             ],
    Config1 = read_app_config(Config),
    ok = stillir:set_config(edogstatsd, Config1),

    ok = edogstatsd_udp:set_server_info(stillir:get_config(edogstatsd, agent_address),
                                        stillir:get_config(edogstatsd, agent_port)).

read_app_config(Config) ->
    lists:map(fun ({AppVar, EnvVar, Opts0}) ->
                      Opts1 = case application:get_env(edogstatsd, AppVar) of
                                  {ok, Value} ->
                                      lists:keystore(default, 1, Opts0, {default, Value});
                                  undefined ->
                                      Opts0
                              end,
                      {AppVar, EnvVar, Opts1}
              end,
              Config).

transform_map(String) ->
    CompressedString = re:replace(String, <<" ">>, <<>>, [global]),
    TrimmedString = case re:run(CompressedString, <<"#{(.*)}">>, [{capture, all_but_first, list}]) of
                        nomatch ->
                            CompressedString;
                        {match, [Inner]} ->
                            Inner
                    end,
    lists:foldl(fun (<<>>, Acc) ->
                        Acc;
                    (El, Acc) ->
                        io:format("El=~p", [El]),
                        case re:split(El, <<"=>?">>, [{return, binary}]) of
                            [Key, Value] ->
                                maps:put(Key, Value, Acc);
                            Other ->
                                erlang:error({cannot_parse_kv_pair, Other})
                        end
                end,
                #{},
                re:split(TrimmedString, <<$,>>, [{return, binary}])).

transform_boolean(String) ->
    case string:to_lower(string:strip(String)) of
        "true" ->
            true;
        "yes" ->
            true;
        "1" ->
            true;
        "false" ->
            false;
        "no" ->
            false;
        "0" ->
            false;
        _ ->
            erlang:error({not_a_boolean, String})
    end.

%%% Tests
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

transform_boolean_test_() -> [
                              ?_assert(transform_boolean("true"))
                             ,?_assert(transform_boolean("TRUE"))
                             ,?_assert(transform_boolean("True"))
                             ,?_assert(transform_boolean("Yes"))
                             ,?_assert(transform_boolean("1"))
                             ,?_assertNot(transform_boolean("0"))
                             ,?_assertNot(transform_boolean("NO"))
                             ,?_assertNot(transform_boolean("false"))
                             ,?_assertNot(transform_boolean("FALSE"))
                             ,?_assertError({not_a_boolean, "nope"}, transform_boolean("nope"))
                             ,?_assertError({not_a_boolean, ""}, transform_boolean(""))
                             ,?_assertError(function_clause, transform_boolean(0))
                             ].

transform_map_test_() -> [
                          ?_assertEqual(#{<<"hello">> => <<"world">>}, transform_map("#{hello=>world}"))
                         ,?_assertEqual(#{<<"hello">> => <<"world">>}, transform_map("hello=world"))
                         ,?_assertEqual(#{<<"hello">> => <<"world">>}, transform_map("hello = world"))
                         ,?_assertEqual(#{<<"hello">> => <<"world">>}, transform_map("hello=> world"))
                         ,?_assertEqual(#{<<"a">> => <<"1">>, <<"b">> => <<"2">>, <<"c">> => <<"3">>},
                                        transform_map("#{a=>1,b=>2,c=>3}"))
                         ,?_assertEqual(#{<<"hello">> => <<"world">>}, transform_map("#{ hello => world }"))
                         ,?_assertEqual(#{}, transform_map(""))
                         ,?_assertError({cannot_parse_kv_pair, _}, transform_map("hello"))
                         ,?_assertError({cannot_parse_kv_pair, _}, transform_map("#{hello}"))
                         ,?_assertError({cannot_parse_kv_pair, _}, transform_map("#{hello,world}"))
                         ].

supervisor_test_() ->
    {setup,
     fun () ->
         configure()
     end,
     fun (_) ->
         ok
     end,
     [
      ?_assertMatch({ok,_Pid}, edogstatsd_sup:start_link())
     ]}.

application_test_() ->
    {setup,
     fun () ->
         application:ensure_all_started(edogstatsd),
         {ok, Socket} = gen_udp:open(8125, [{active, true}]),
         Socket
     end,
     fun (Socket) ->
         ok = gen_udp:close(Socket)
     end,
     fun(Socket) ->
         MetricResult = edogstatsd:gauge("test", 1),
         MetricMessage = receive
             {udp, Socket, {127, 0, 0, 1}, _Port1, Msg1} -> Msg1
             after 3000 -> metric_time_out end,

         EventResult = edogstatsd:event("my_title", "my_text"),
         EventMessage = receive
             {udp, Socket, {127, 0, 0, 1}, _Port2, Msg2} -> Msg2
             after 3000 -> event_time_out end,

         [
             ?_assertEqual(ok, MetricResult),
             ?_assertEqual("test:1.000|g|@1.00", MetricMessage),
             ?_assertEqual(ok, EventResult),
             ?_assertEqual("_e{8,7}:my_title|my_text|t:info|p:normal", EventMessage)
         ]
     end}.

-endif.
