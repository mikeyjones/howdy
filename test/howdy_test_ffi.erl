-module(howdy_test_ffi).
-include_lib("public_key/include/public_key.hrl").
-export([spawn_task/1, await/1, catch_panic/1, channel_member/1, stop_member/1]).
-export([parallel_at_once/1]).
-export([with_static_tree/1]).
-export([with_http_server/2, http_status/3]).
-export([free_port/0, test_certificate/0, tls_probe/2, h2c_probe/1]).

%% A port nobody is listening on right now. `howdy.start` does not report
%% the port it chose, so tests pick one first.
free_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    Port.

%% A throwaway self-signed chain as PEM {Cert, Key}.
test_certificate() ->
    %% A single chain yields the server config list directly.
    Server = public_key:pkix_test_data(#{
        root => [{key, {rsa, 2048, 65537}}, {digest, sha256}],
        peer => [{key, {rsa, 2048, 65537}}, {digest, sha256},
                 {extensions, [#'Extension'{extnID = ?'id-ce-subjectAltName',
                                            extnValue = [{dNSName, "localhost"}],
                                            critical = false}]}]}),
    Cert = proplists:get_value(cert, Server),
    CaCerts = proplists:get_value(cacerts, Server),
    {KeyType, KeyDer} = proplists:get_value(key, Server),
    CertPem = public_key:pem_encode([{'Certificate', C, not_encrypted} || C <- [Cert | CaCerts]]),
    KeyPem = public_key:pem_encode([{KeyType, KeyDer, not_encrypted}]),
    {CertPem, KeyPem}.

%% Connect over TLS advertising Alpn, then speak whichever protocol was
%% negotiated. Returns {Negotiated, Outcome} where Outcome is the HTTP/1.1
%% status, or `settings` once the server answers an HTTP/2 SETTINGS frame.
tls_probe(Port, Alpn) ->
    {ok, S} = ssl:connect({127,0,0,1}, Port,
        [binary, {active, false}, {verify, verify_none},
         {alpn_advertised_protocols, [Alpn]}, {server_name_indication, "localhost"}], 5000),
    try
        Negotiated = case ssl:negotiated_protocol(S) of
            {ok, P} -> P;
            {error, protocol_not_negotiated} -> none
        end,
        {Negotiated, exchange(ssl, S, Negotiated)}
    after ssl:close(S)
    end.

%% Plaintext HTTP/2 with prior knowledge: preface and SETTINGS, no upgrade.
h2c_probe(Port) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000),
    try exchange(gen_tcp, S, <<"h2">>) after gen_tcp:close(S) end.

exchange(Mod, S, <<"h2">>) ->
    ok = Mod:send(S, [<<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>, <<0:24, 4:8, 0:8, 0:1, 0:31>>]),
    {ok, <<_Len:24, Type:8, _/binary>>} = recv_at_least(Mod, S, 9, <<>>),
    case Type of 4 -> settings; Other -> {frame_type, Other} end;
exchange(Mod, S, _Http1) ->
    ok = Mod:send(S, <<"GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>),
    {ok, Data} = recv_at_least(Mod, S, 12, <<>>),
    <<"HTTP/1.1 ", Status:3/binary, _/binary>> = Data,
    binary_to_integer(Status).

recv_at_least(Mod, S, N, Acc) when byte_size(Acc) >= N -> {ok, Acc};
recv_at_least(Mod, S, N, Acc) ->
    case Mod:recv(S, 0, 5000) of
        {ok, More} -> recv_at_least(Mod, S, N, <<Acc/binary, More/binary>>);
        Error -> Error
    end.

with_http_server(Start, Run) ->
    {Pid, Port} = Start(),
    try Run(Port)
    after
        unlink(Pid),
        Ref = monitor(process, Pid),
        exit(Pid, shutdown),
        receive {'DOWN', Ref, process, Pid, _} -> ok
        after 5000 -> error(server_stop_timeout)
        end
    end.

http_status(Port, Path, Origin) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
        [binary, {active, false}, {packet, http_bin}], 5000),
    try
        OriginHeader = case Origin of <<>> -> []; _ -> ["Origin: ", Origin, "\r\n"] end,
        ok = gen_tcp:send(Socket, ["GET ", Path, " HTTP/1.1\r\nHost: localhost:",
            integer_to_binary(Port), "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
            OriginHeader, "\r\n"]),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(Socket, 0, 5000),
        Status
    after gen_tcp:close(Socket)
    end.

with_static_tree(Test) ->
    Base = filename:join(case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
        "howdy-static-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Root = filename:join(Base, "public"),
    ok = filelib:ensure_dir(filename:join(Root, "nested/placeholder")),
    try
        ok = file:write_file(filename:join(Base, "secret.txt"), <<"outside">>),
        ok = file:write_file(filename:join(Root, "ok.txt"), <<"inside">>),
        ok = file:write_file(filename:join(Root, "index.html"), <<"home">>),
        ok = file:make_symlink("../secret.txt", filename:join(Root, "escape.txt")),
        ok = file:make_symlink("ok.txt", filename:join(Root, "inside-link.txt")),
        ok = file:make_symlink("..", filename:join(Root, "escape-dir")),
        ok = file:make_symlink("../../secret.txt", filename:join(Root, "nested/index.html")),
        ok = file:make_symlink(Root, filename:join(Base, "root-link")),
        Test(unicode:characters_to_binary(Root))
    after file:del_dir_r(Base)
    end.

%% Hold every worker at a barrier before releasing competing operations.
parallel_at_once(Tasks) ->
    Parent = self(),
    Batch = make_ref(),
    Workers = [spawn_monitor(fun() ->
        receive {go, Batch} -> Parent ! {Batch, self(), Task()} end
    end) || Task <- Tasks],
    try
        [Pid ! {go, Batch} || {Pid, _} <- Workers],
        [receive
            {Batch, Pid, Value} -> Value;
            {'DOWN', Ref, process, Pid, Reason} -> erlang:error({worker_failed, Reason})
         after 5000 -> erlang:error(worker_timeout)
         end || {Pid, Ref} <- Workers]
    after
        [begin exit(Pid, kill), demonitor(Ref, [flush]) end || {Pid, Ref} <- Workers]
    end.

spawn_task(Fun) ->
    Parent = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Parent ! {Ref, Fun()} end),
    Ref.

await(Ref) ->
    receive
        {Ref, Result} -> Result
    after 5000 ->
        erlang:error(timeout)
    end.

catch_panic(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% A process that joins Topics on its own behalf and stays alive until told
%% to stop. Returns its pid.
channel_member(Topics) ->
    spawn(fun() ->
        [howdy_ffi:channel_join(T, self()) || T <- Topics],
        receive stop -> ok end
    end).

stop_member(Pid) ->
    Pid ! stop,
    %% Wait until pg has processed the exit so membership is settled.
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> erlang:error(timeout) end,
    timer:sleep(20),
    nil.
