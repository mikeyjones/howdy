-module(howdy_mail_test_ffi).
-export([new_table/0, table_push/2, table_all/1, start_smtp/1, stop_smtp/1, smtp_port/1, received/1, mime_header/2, mime_leaves/1, closed_port/0]).

%% A test SMTP server on a free loopback port, reporting to the caller.
start_smtp(Auth) ->
    {ok, _} = application:ensure_all_started(gen_smtp),
    Name = {howdy_mail_test, make_ref()},
    {ok, _} = gen_smtp_server:start(Name, howdy_mail_test_smtp, [
        {address, {127, 0, 0, 1}},
        {port, 0},
        {domain, "test.local"},
        {sessionoptions, [{callbackoptions, [{collector, self()}, {auth, Auth}]}]}
    ]),
    Name.

stop_smtp(Name) ->
    gen_smtp_server:stop(Name),
    nil.

smtp_port(Name) -> ranch:get_port(Name).

received(Timeout) ->
    receive
        {howdy_mail_test_smtp, From, To, Data} -> {ok, {From, To, Data}}
    after Timeout -> {error, nil}
    end.

%% A port nothing listens on.
closed_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    gen_tcp:close(Socket),
    Port.

mime_header(Data, Name) ->
    {_, _, Headers, _, _} = mimemail:decode(Data),
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> {ok, Value};
        false -> {error, nil}
    end.

%% Every leaf part as {"type/subtype", DecodedBody}.
mime_leaves(Data) ->
    leaves(mimemail:decode(Data)).

leaves({_Type, _Subtype, _Headers, _Params, Parts}) when is_list(Parts) ->
    lists:append([leaves(Part) || Part <- Parts]);
leaves({Type, Subtype, _Headers, _Params, Body}) ->
    [{<<Type/binary, "/", Subtype/binary>>, Body}].

%% A list that outlives the closures appending to it.
new_table() -> ets:new(howdy_mail_test, [public, duplicate_bag]).
table_push(Table, Value) ->
    ets:insert(Table, {erlang:unique_integer([monotonic]), Value}),
    nil.
table_all(Table) ->
    [Value || {_, Value} <- lists:keysort(1, ets:tab2list(Table))].
