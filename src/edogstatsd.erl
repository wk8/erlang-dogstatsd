-module(edogstatsd).

-type metric_name() :: iodata().
-type metric_value() :: number().
-type metric_type() :: counter | gauge | histogram | timer | set.
-type metric_sample_rate() :: number().
-type metric_tags() :: map().

-type metric_data() :: {metric_name(), metric_value()}
    | {metric_name(), metric_value(), metric_sample_rate()|metric_tags()}
    | {metric_name(), metric_value(), metric_sample_rate(), metric_tags()}.

-type event_title() :: iodata().
-type event_text() :: iodata().
-type event_type() :: info | error | warning | success.
-type event_priority() :: normal | low.
-type event_tags() :: map().

-export_type([
              metric_name/0
             ,metric_value/0
             ,metric_type/0
             ,metric_sample_rate/0
             ,metric_tags/0
             ,metric_data/0
             ,event_title/0
             ,event_text/0
             ,event_type/0
             ,event_priority/0
             ,event_tags/0
             ]).

-export([
        gauge/1, gauge/2, gauge/3, gauge/4
        ,counter/1 ,counter/2, counter/3, counter/4
        ,increment/1, increment/2, increment/3, increment/4
        ,histogram/1, histogram/2, histogram/3, histogram/4
        ,timer/1, timer/2, timer/3, timer/4
        ,timing/1, timing/2, timing/3, timing/4
        ,set/1, set/2, set/3, set/4
        ,event/1, event/2, event/3, event/4, event/5
        ]).
-define(SPEC_TYPE_1(Type), -spec Type(metric_data() | [metric_data()]) -> ok | {error, _Why}).
-define(MK_TYPE_1(Type),
        Type(MetricDataList) when is_list(MetricDataList) ->
               edogstatsd_sender:send_metrics(Type, MetricDataList);
        Type(MetricData) when is_tuple(MetricData) ->
               edogstatsd_sender:send_metrics(Type, [MetricData])
).
-define(SPEC_TYPE_2(Type), -spec Type(metric_name(), metric_value()) -> ok | {error, _Why}).
-define(MK_TYPE_2(Type),
        Type(Name, Value) when is_number(Value) ->
               edogstatsd_sender:send_metrics(Type, [{Name, Value}])
).
-define(SPEC_TYPE_3(Type), -spec Type(metric_name(), metric_value(), metric_sample_rate()|metric_tags()) -> ok | {error, _Why}).
-define(MK_TYPE_3(Type),
        Type(Name, Value, SampleRateOrTags) when is_number(Value) andalso (is_number(SampleRateOrTags) orelse is_map(SampleRateOrTags)) ->
               edogstatsd_sender:send_metrics(Type, [{Name, Value, SampleRateOrTags}])
).
-define(SPEC_TYPE_4(Type), -spec Type(metric_name(), metric_value(), metric_sample_rate(), metric_tags()) -> ok | {error, _Why}).
-define(MK_TYPE_4(Type),
        Type(Name, Value, SampleRate, Tags) when is_number(SampleRate), is_map(Tags) ->
               edogstatsd_sender:send_metrics(Type, [{Name, Value, SampleRate, Tags}])
).

-define(ALIAS_TYPE_1(Alias, Real), Alias(A) -> Real(A)).
-define(ALIAS_TYPE_2(Alias, Real), Alias(A, B) -> Real(A, B)).
-define(ALIAS_TYPE_3(Alias, Real), Alias(A, B, C) -> Real(A, B, C)).
-define(ALIAS_TYPE_4(Alias, Real), Alias(A, B, C, D) -> Real(A, B, C, D)).

?SPEC_TYPE_1(gauge).
?SPEC_TYPE_2(gauge).
?SPEC_TYPE_3(gauge).
?SPEC_TYPE_4(gauge).
?MK_TYPE_1(gauge).
?MK_TYPE_2(gauge).
?MK_TYPE_3(gauge).
?MK_TYPE_4(gauge).

?SPEC_TYPE_1(counter).
?SPEC_TYPE_2(counter).
?SPEC_TYPE_3(counter).
?SPEC_TYPE_4(counter).
?MK_TYPE_1(counter).
?MK_TYPE_2(counter).
?MK_TYPE_3(counter).
?MK_TYPE_4(counter).
?ALIAS_TYPE_1(increment, counter).
?ALIAS_TYPE_2(increment, counter).
?ALIAS_TYPE_3(increment, counter).
?ALIAS_TYPE_4(increment, counter).

?SPEC_TYPE_1(histogram).
?SPEC_TYPE_2(histogram).
?SPEC_TYPE_3(histogram).
?SPEC_TYPE_4(histogram).
?MK_TYPE_1(histogram).
?MK_TYPE_2(histogram).
?MK_TYPE_3(histogram).
?MK_TYPE_4(histogram).

?SPEC_TYPE_1(timer).
?SPEC_TYPE_2(timer).
?SPEC_TYPE_3(timer).
?SPEC_TYPE_4(timer).
?MK_TYPE_1(timer).
?MK_TYPE_2(timer).
?MK_TYPE_3(timer).
?MK_TYPE_4(timer).
?ALIAS_TYPE_1(timing, timer).
?ALIAS_TYPE_2(timing, timer).
?ALIAS_TYPE_3(timing, timer).
?ALIAS_TYPE_4(timing, timer).

?SPEC_TYPE_1(set).
?SPEC_TYPE_2(set).
?SPEC_TYPE_3(set).
?SPEC_TYPE_4(set).
?MK_TYPE_1(set).
?MK_TYPE_2(set).
?MK_TYPE_3(set).
?MK_TYPE_4(set).

-spec event(event_title()) -> ok | {error, _Why}.
event(Title) -> event(Title, "").
-spec event(event_title(), event_text()) -> ok | {error, _Why}.
event(Title, Text) -> event(Title, Text, info).
-spec event(event_title(), event_text(), event_type()) -> ok | {error, _Why}.
event(Title, Text, Type) -> event(Title, Text, Type, normal).
-spec event(event_title(), event_text(), event_type(), event_priority()) -> ok | {error, _Why}.
event(Title, Text, Type, Priority) -> event(Title, Text, Type, Priority, #{}).
-spec event(event_title(), event_text(), event_type(), event_priority(), event_tags()) -> ok | {error, _Why}.
event(Title, Text, Type, Priority, Tags) ->
    edogstatsd_sender:send_event(Title, Text, Type, Priority, Tags).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%% Tests
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

gauge_test_() ->
    edogstatsd_app:configure(),

    [
     ?_assertEqual(ok, edogstatsd:gauge("foo.bar", 1))
    ,?_assertEqual(ok, edogstatsd:gauge("foo.bar", 1, 0.5))
    ,?_assertEqual(ok, edogstatsd:gauge("foo.bar", 1, #{baz => qux}))
    ,?_assertEqual(ok, edogstatsd:gauge("foo.bar", 1, 0.25, #{baz => qux}))
    ,?_assertError(function_clause, edogstatsd:gauge("foo.bar", #{baz => qux}))
    ,?_assertError(function_clause, edogstatsd:gauge("foo.bar", #{baz => qux}, 0.5))
    ,?_assertError(function_clause, edogstatsd:gauge("foo.bar", 1, "hello"))
    ,?_assertEqual(ok, edogstatsd:gauge([{"foo.bar", 1, 0.5, #{foo => bar}},
                                         {"foo.bar", 1, 0.5, #{foo => bar}}]))
    ,?_assertError(function_clause, edogstatsd:gauge([{"foo.bar", 1, 0.5, #{foo => bar}},
                                                      {"foo.bar", 1, "hello"}]))
    ].

-endif.
