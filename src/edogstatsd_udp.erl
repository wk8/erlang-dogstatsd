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
        MsgCount = 1000,
        MsgList = [{I, base64:encode(crypto:strong_rand_bytes(32))}
                   || I <- lists:seq(1, MsgCount)],
        Self = self(),

        %% now send each of these messages from a different process, after
        %% sleeping a random amount of time
        lists:foreach(
            fun({I, Message}) ->
                erlang:spawn(fun() ->
                    RawMessage = [erlang:integer_to_list(I), " ", Message],
                    %% we send the message twice
                    timer:sleep(rand:uniform(50)),
                    ok = send(RawMessage),
                    timer:sleep(rand:uniform(50)),
                    ok = send(RawMessage),
                    %% then send a simple `ok' to make sure this process didn't
                    %% crash
                    Self ! {I, ok}
                end),
                ok
            end,
            MsgList
        ),

        %% now let's receive all these
        {UdpMessages, OtherMessages} = receive_messages(Socket, 3 * MsgCount),

        ParsedUdpMessages = lists:foldl(
            fun(RawMessage, Acc) ->
                [IBin, Message] = binary:split(erlang:list_to_binary(RawMessage), <<" ">>),
                I = erlang:binary_to_integer(IBin),
                maps:update_with(
                    I,
                    fun({PreviousCount, SameMessage}) when SameMessage =:= Message ->
                        {PreviousCount + 1, Message}
                    end,
                    {1, Message},
                    Acc)
            end,
            #{},
            UdpMessages
        ),
        ExpectedParsedUdpMessages = lists:foldl(
            fun({I, Message}, Acc) ->
                maps:put(I, {2, Message}, Acc)
            end,
            #{},
            MsgList
        ),

        ExpectedSortedOtherMessages = [{I, ok} || I <- lists:seq(1, MsgCount)],

        [
         ?_assertEqual(ExpectedParsedUdpMessages, ParsedUdpMessages),
         ?_assertEqual(lists:sort(OtherMessages), ExpectedSortedOtherMessages)
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
    after 200 -> Messages end.

-endif.
