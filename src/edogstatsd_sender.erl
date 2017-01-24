-module(edogstatsd_sender).

-export([
    send_metrics/2,
    send_event/5
]).

-spec send_metrics(edogstatsd:metric_type(), [edogstatsd:metric_data()])
-> ok | {error, _Why}.
send_metrics(_Type, []) ->
    ok;
send_metrics(Type, MetricDataList) ->
    if_enabled(fun(Config) ->
        Lines = [build_metric_line(Type, normalize_metric_data(MetricData), Config)
             || MetricData <- MetricDataList],
        send_lines(Lines)
    end).

-spec send_event(edogstatsd:event_title(), edogstatsd:event_text(), edogstatsd:event_type(), edogstatsd:event_priority(), edogstatsd:event_tags())
-> ok | {error, _Why}.
send_event(Title, Text, Type, Priority, Tags) ->
    if_enabled(fun(Config) ->
        Line = build_event_line(Title, Text, Type, Priority, Tags, Config),
        send_lines([Line])
    end).

%%% Private helpers

-record(config, {
    enabled :: boolean(),
    prefix  :: string() | undefined,
    tags    :: #{} | undefined
}).

config() ->
    case erlang:get(?MODULE) of
        undefined ->
            Config = new_config(),
            erlang:put(?MODULE, Config),
            Config;
        Config ->
            Config
    end.

new_config() ->
    case stillir:get_config(edogstatsd, send_metrics, false) of
        true ->
            #config{
                enabled = true,
                prefix  = stillir:get_config(edogstatsd, global_prefix, ""),
                tags    = stillir:get_config(edogstatsd, global_tags, #{})
            };
        _Else ->
            #config{enabled = false}
    end.

if_enabled(Fun) ->
    case config() of
        #config{enabled = true} = Config -> Fun(Config);
        _Else -> ok
    end.

normalize_metric_data({Name, Value}) ->
    {Name, Value, 1.0, #{}};
normalize_metric_data({Name, Value, SampleRate}) when is_number(SampleRate) ->
    {Name, Value, SampleRate, #{}};
normalize_metric_data({Name, Value, Tags}) when is_map(Tags) ->
    {Name, Value, 1.0, Tags};
normalize_metric_data({_Name, _Value, _SampleRate, _Tags} = AlreadyNormalized) ->
    AlreadyNormalized.

build_metric_line(Type, {Name, Value, SampleRate, Tags}, Config) ->
    LineStart = io_lib:format("~s:~.3f|~s|@~.2f", [prepend_global_prefix(Name, Config), float(Value),
                                                    metric_type_to_str(Type), float(SampleRate)]),
    TagLine = build_tag_line(Tags, Config),
    [LineStart, TagLine].

prepend_global_prefix(Name, #config{prefix=""}) -> Name;
prepend_global_prefix(Name, #config{prefix=GlobalPrefix}) -> [GlobalPrefix, $., Name].

metric_type_to_str(counter) -> "c";
metric_type_to_str(gauge) -> "g";
metric_type_to_str(histogram) -> "h";
metric_type_to_str(timer) -> "ms";
metric_type_to_str(set) -> "s".

kv(K, V) when is_atom(K) ->
    kv(atom_to_list(K), V);
kv(K, V) when is_atom(V) ->
    kv(K, atom_to_list(V));
kv(K, V) when is_number(K) ->
    kv(io_lib:format("~b", [K]), V);
kv(K, V) when is_number(V) ->
    kv(K, io_lib:format("~b", [V]));
kv(K, V) ->
    [K, $:, V].

iodata_to_bin(Bin) when is_binary(Bin) -> Bin;
iodata_to_bin(IoList) -> iolist_to_binary(IoList).

build_event_line(Title, Text, Type, Priority, Tags, Config) ->
    TitleBin = iodata_to_bin(Title),
    TextBin = iodata_to_bin(Text),
    TitleLen = byte_size(TitleBin),
    TextLen = byte_size(TextBin),
    LineStart = io_lib:format("_e{~b,~b}:~s|~s|t:~s|p:~s", [TitleLen, TextLen, TitleBin,
                                                            TextBin, Type, Priority]),
    TagLine = build_tag_line(Tags, Config),
    [LineStart, TagLine].

build_tag_line(Tags, #config{tags=GlobalTags}) ->
    maps:fold(fun (Key, Val, []) ->
                      ["|#", kv(Key, Val)];
                  (Key, Val, Acc) ->
                      [Acc, ",", kv(Key, Val)]
              end,
              [],
              maps:merge(GlobalTags, Tags)).

send_lines(Lines) ->
    Errors = lists:foldl(
        fun(Line, CurrentErrors) ->
            case edogstatsd_udp:send_line(Line) of
                ok -> CurrentErrors;
                {error, Why} -> [{Line, Why} | CurrentErrors]
            end
        end,
        [],
        Lines
    ),

    case Errors =:= [] of
        true -> ok;
        false -> {error, Errors}
    end.

%%% Tests
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

normalize_metric_data_test_() ->
    [
     ?_assertEqual({"key", "value", 1.0, #{}}, normalize_metric_data({"key", "value"}))
    ,?_assertEqual({"key", "value", 12, #{}}, normalize_metric_data({"key", "value", 12}))
    ,?_assertEqual({"key", "value", 1.0, #{foo => bar}},
                    normalize_metric_data({"key", "value", #{foo => bar}}))
    ,?_assertEqual({"key", "value", 12, #{foo => bar}},
                   normalize_metric_data({"key", "value", 12, #{foo => bar}}))
    ].

build_metric_line_test_() ->
    Type = histogram,
    Name = ["mymetric_", [<<"name">>]],
    Value = 28.0,
    SampleRate = 12,
    Tags = #{"version" => 42},

    ExpectedLine = <<"test_global_prefix.mymetric_name:28.000|h|@12.00|#test:true,version:42">>,
    ActualLine = build_metric_line(Type, {Name, Value, SampleRate, Tags}, test_config()),

    ?_assertEqual(ExpectedLine, iolist_to_binary(ActualLine)).

build_event_line_test_() ->
    Title = ["my ", <<"eve">>, ["nt's title"]],
    Text = <<"my event's text">>,
    Type = success,
    Priority = low,
    Tags = #{"event" => "awesome"},

    ExpectedLine = <<"_e{16,15}:my event's title|my event's text|t:success|p:low|#event:awesome,test:true">>,
    ActualLine = build_event_line(Title, Text, Type, Priority, Tags, test_config()),

    ?_assertEqual(ExpectedLine, iolist_to_binary(ActualLine)).

test_config() ->
    #config{
        prefix = "test_global_prefix",
        tags = #{"test" => true}
    }.

-endif.
