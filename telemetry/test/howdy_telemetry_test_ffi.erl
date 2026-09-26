-module(howdy_telemetry_test_ffi).
-export([rescue/1, websocket_roundtrip/3, crash_process/0, putenv/2]).

rescue(Run) ->
    try {ok, Run()} catch _:_ -> {error, nil} end.

%% Open a websocket to 127.0.0.1:Port at Path, send one masked text frame,
%% wait for the echo, and close.
websocket_roundtrip(Port, Path, Text) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ok = gen_tcp:send(Socket, [<<"GET ">>, Path, <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ">>, Key,
                               <<"\r\n\r\n">>]),
    {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(Socket, 0, 2000),
    Mask = crypto:strong_rand_bytes(4),
    Masked = mask(Text, Mask),
    ok = gen_tcp:send(Socket, <<1:1, 0:3, 1:4, 1:1, (byte_size(Text)):7, Mask/binary, Masked/binary>>),
    {ok, Reply} = gen_tcp:recv(Socket, 0, 2000),
    gen_tcp:close(Socket),
    Reply.

mask(Data, <<M:4/binary>>) ->
    << <<(B bxor binary:at(M, I rem 4))>> || {B, I} <- lists:zip(binary_to_list(Data), lists:seq(0, byte_size(Data) - 1)) >>.

%% A proc_lib process that crashes outside any span, as a worker would.
crash_process() ->
    Pid = proc_lib:spawn(fun() -> error(worker_gave_up) end),
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    timer:sleep(50),
    nil.

putenv(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.
