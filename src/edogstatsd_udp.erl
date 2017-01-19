-module(edogstatsd_udp).

-export([
    init/2,
    send/1,
    send/2,
    buffer/0
]).

-on_load(init/0).

-define(NOT_LOADED, not_loaded(?LINE)).

init(_ServerIpString, _ServerPort) -> ?NOT_LOADED.

send(Line) ->
    case buffer() of
        {ok, Buffer} -> send(Buffer, Line);
        {error, _Why} = Error -> Error
    end.

send(_Buffer, _Line) -> ?NOT_LOADED.

buffer() ->
    case erlang:get(?MODULE) of
        undefined -> try_to_allocate_new_buffer();
        Buffer -> {ok, Buffer}
    end.

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

try_to_allocate_new_buffer() ->
    case new_buffer() of
        {ok, Buffer} = Success ->
            erlang:put(?MODULE, Buffer),
            Success;
        error ->
            {error, could_not_allocate_buffer}
    end.

new_buffer() -> ?NOT_LOADED.

%%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(PORT, 8125).

basic_send_test_() ->
    with_setup(fun(Socket) ->
        ok = send(["hello", [[" "]], <<"world">>]),

        {UdpMessages, OtherMessages} = receive_messages(Socket, 1),

        [
         ?_assertEqual(["hello world"], UdpMessages),
         ?_assertEqual([], OtherMessages)
        ]
    end).

parallel_send_test_() ->
    with_setup(fun(Socket) ->
        %% build a bunch of messages to send
        ProcessCount = 20,
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
                            ok = send(IOListMsg)
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

        [
         assert_sets_equal(udp_messages, ExpectedUdpMessages, ActualUdpMessages),
         assert_sets_equal(other_messages, ExpectedOtherMessages, ActualOtherMessages)
        ]
    end).

with_setup(TestFun) ->
    {setup,
     fun() ->
         ok = init("localhost", ?PORT),
         {ok, Socket} = gen_udp:open(?PORT, [{active, true}]),
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
    Messages;
receive_messages(Socket, ExpectedCount, CurrentCount, {UdpMessages, OtherMessages} = Messages) ->
    receive
    {udp, Socket, {127, 0, 0, 1}, _Port, Message} ->
        NewMessages = {[Message | UdpMessages], OtherMessages},
        receive_messages(Socket, ExpectedCount, CurrentCount + 1, NewMessages);
    OtherMessage ->
        NewMessages = {UdpMessages, [OtherMessage | OtherMessages]},
        receive_messages(Socket, ExpectedCount, CurrentCount + 1, NewMessages)
    after 3000 -> Messages end.

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
