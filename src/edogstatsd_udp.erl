-module(edogstatsd_udp).

-export([
    set_server_info/2,
    send_line/1,
    current_pool_size/0
]).

-on_load(init/0).

-define(NOT_LOADED, not_loaded(?LINE)).

set_server_info(_ServerIpString, _ServerPort) -> ?NOT_LOADED.

send_line(_LineAsIOData) -> ?NOT_LOADED.

current_pool_size() -> ?NOT_LOADED.

%%% Private helpers

init() ->
    PrivDir = case code:priv_dir(?MODULE) of
        {error, _} ->
            EbinDir = filename:dirname(code:which(?MODULE)),
            AppPath = filename:dirname(EbinDir),
            filename:join(AppPath, "priv");
        Path ->
            Path
    end,
    erlang:load_nif(filename:join(PrivDir, "edogstatsd"), 0).

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).

%%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_send_test_() ->
    with_setup(fun(Socket) ->
        ok = send_line(["hello", [[" "]], <<"world">>]),

        {UdpMessages, OtherMessages} = receive_messages(Socket, 1),

        [
         ?_assertEqual(["hello world"], UdpMessages),
         ?_assertEqual([], OtherMessages)
        ]
    end, 18125).

parallel_send_test_() ->
    with_setup(fun(Socket) ->
        %% build a bunch of messages to send
        ProcessCount = 25,
        Messages = lists:map(
            fun(I) ->
                BytesCount = 20 + rand:uniform(20),
                RandomBin = base64:encode(crypto:strong_rand_bytes(BytesCount)),
                IOListMsg = [erlang:integer_to_list(I), " ", RandomBin],
                {I, IOListMsg}
            end,
            lists:seq(1, ProcessCount)
        ),
        Self = self(),

        %% now send each of these messages from a different process, after 3000
        %% sleeping a random amount of time
        {ExpectedUdpMessages, ExpectedOtherMessages} =
        lists:foldl(
            fun({I, BaseIOListMsg}, {CurrentExpectedUdpMessages, CurrentExpectedOtherMessages}) ->
                %% let's create the 3 messages we're actually going to send over
                %% UDP, of the form "1|2|3 processId randomBin"
                IOListMsgs = [[erlang:integer_to_list(Counter), " ", BaseIOListMsg]
                              || Counter <- [1, 2]],
                OkMessage = {I, ok},

                erlang:spawn(fun() ->
                    lists:foreach(
                        fun(IOListMsg) ->
                            timer:sleep(rand:uniform(50)),
                            ok = send_line(IOListMsg)
                        end,
                        IOListMsgs
                    ),
                    %% then send a simple `ok' to make sure this process didn't
                    %% crash
                    Self ! OkMessage
                end),

                StringMsgs = [erlang:binary_to_list(erlang:iolist_to_binary(IOListMsg))
                              || IOListMsg <- IOListMsgs],
                {StringMsgs ++ CurrentExpectedUdpMessages,
                 [OkMessage | CurrentExpectedOtherMessages]}
            end,
            {[], []},
            Messages
        ),

        %% now let's receive all these
        {ActualUdpMessages, ActualOtherMessages} = receive_messages(Socket, 4 * ProcessCount),

        CurrentPoolSize = edogstatsd_udp:current_pool_size(),

        [
         assert_sets_equal(udp_messages, ExpectedUdpMessages, ActualUdpMessages),
         assert_sets_equal(other_messages, ExpectedOtherMessages, ActualOtherMessages),
         %% we should have created at least one worker space
         ?_assert(CurrentPoolSize > 0)
        ]
    end, 18126).

send_binary_test_() ->
    with_setup(fun(Socket) ->
        ok = send_line(<<"hello world 2">>),

        {UdpMessages, OtherMessages} = receive_messages(Socket, 1),

        [
         ?_assertEqual(["hello world 2"], UdpMessages),
         ?_assertEqual([], OtherMessages)
        ]
    end, 18127).

bad_arg_test_() ->
    with_setup(fun(_Socket) ->
        [?_assertError(badarg, send_line(BadLine))
         || BadLine <- [i_aint_an_io_data, 42, erlang:make_ref(), erlang:self()]]
    end, 18128).

with_setup(TestFun, Port) ->
    {setup,
     fun() ->
         ok = set_server_info("localhost", Port),
         {ok, Socket} = gen_udp:open(Port, [{active, true}]),
         Socket
     end,
     fun(Socket) ->
         ok = gen_udp:close(Socket)
     end,
     TestFun
    }.

receive_messages(Socket, ExpectedCount) ->
    receive_messages(Socket, ExpectedCount, 0, {[], []}).

receive_messages(_Socket, ExpectedCount, ExpectedCount, Messages) ->
    reverse_messages(Messages);
receive_messages(Socket, ExpectedCount, CurrentCount, {UdpMessages, OtherMessages} = Messages) ->
    receive
    {udp, Socket, {127, 0, 0, 1}, _Port, Message} ->
        NewMessages = {[Message | UdpMessages], OtherMessages},
        receive_messages(Socket, ExpectedCount, CurrentCount + 1, NewMessages);
    OtherMessage ->
        NewMessages = {UdpMessages, [OtherMessage | OtherMessages]},
        receive_messages(Socket, ExpectedCount, CurrentCount + 1, NewMessages)
    after 3000 -> reverse_messages(Messages) end.

reverse_messages({UdpMessages, OtherMessages}) ->
    {lists:reverse(UdpMessages), lists:reverse(OtherMessages)}.

assert_sets_equal(Label, Expected, Actual) ->
    ExpectedSet = sets:from_list(Expected),
    ActualSet = sets:from_list(Actual),

    MissingItems = sets:subtract(ExpectedSet, ActualSet),
    ExtraItems = sets:subtract(ActualSet, ExpectedSet),

    [
     ?_assertEqual({Label, missing, []}, {Label, missing, sets:to_list(MissingItems)}),
     ?_assertEqual({Label, extra, []}, {Label, extra, sets:to_list(ExtraItems)})
    ].

-endif.
