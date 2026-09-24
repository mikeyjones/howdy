-module(howdy_admin_ffi).
-export([cells/1, postgres_pool/1, listen/4]).

%% A database row as it came from the driver, as a list of optional strings.
%% pog rows are tuples and sqlight rows are lists; every value becomes text
%% so the admin can show any column without knowing its type.
cells(Row) when is_tuple(Row) -> cells(tuple_to_list(Row));
cells(Row) when is_list(Row) -> [cell(V) || V <- Row];
cells(Other) -> [cell(Other)].

cell(nil) -> none;
cell(null) -> none;
cell(undefined) -> none;
cell(true) -> {some, <<"true">>};
cell(false) -> {some, <<"false">>};
cell(V) when is_binary(V) -> {some, text(V)};
cell(V) when is_integer(V) -> {some, integer_to_binary(V)};
cell(V) when is_float(V) -> {some, float_to_binary(V, [short])};
cell(V) when is_atom(V) -> {some, atom_to_binary(V, utf8)};
cell({{Y, Mo, D}, {H, Mi, S}})
  when is_integer(Y), is_integer(Mo), is_integer(D),
       is_integer(H), is_integer(Mi) ->
    {some, iolist_to_binary([date(Y, Mo, D), " ", pad(H), ":", pad(Mi), ":", seconds(S)])};
cell({Y, Mo, D}) when is_integer(Y), is_integer(Mo), is_integer(D) ->
    {some, iolist_to_binary(date(Y, Mo, D))};
cell(V) ->
    {some, unicode:characters_to_binary(io_lib:format("~p", [V]))}.

text(B) ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        B when byte_size(B) =/= 16 -> B;
        B -> maybe_uuid(B);
        _ when byte_size(B) =:= 16 -> uuid(B);
        _ -> <<"\\x", (binary:encode_hex(B))/binary>>
    end.

%% Sixteen valid UTF-8 bytes are almost always text, but a random UUID can
%% happen to be valid too; only treat it as a UUID when it is not printable.
maybe_uuid(B) ->
    case io_lib:printable_unicode_list(unicode:characters_to_list(B)) of
        true -> B;
        false -> uuid(B)
    end.

uuid(<<A:32, B:16, C:16, D:16, E:48>>) ->
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])).

date(Y, Mo, D) -> [io_lib:format("~4..0b", [Y]), "-", pad(Mo), "-", pad(D)].

pad(N) -> io_lib:format("~2..0b", [N]).

seconds(S) when is_integer(S) -> pad(S);
seconds(S) when is_float(S) -> io_lib:format("~6.3.0f", [S]);
seconds(S) -> io_lib:format("~p", [S]).

%% The pgo pool behind a Gloo Repo on PostgreSQL, or nothing for SQLite or
%% an unrecognised Repo. Reads Gloo's public adapter record.
postgres_pool({repo, Adapter}) when element(1, Adapter) =:= adapter ->
    case element(3, Adapter) of
        {pg_connection, {pool, Name}, _} when is_atom(Name) -> {ok, Name};
        _ -> {error, nil}
    end;
postgres_pool(_) ->
    {error, nil}.

%% pgo keeps the pool's configuration in the child specification of the
%% pool supervisor, which the pool process is linked to.
pool_config(Name) ->
    case whereis(Name) of
        undefined -> {error, nil};
        Pool ->
            {links, Links} = process_info(Pool, links),
            find_config([Pid || Pid <- Links, is_pid(Pid), is_pool_sup(Pid)])
    end.

is_pool_sup(Pid) ->
    case proc_lib:initial_call(Pid) of
        {pgo_pool_sup, _, _} -> true;
        {supervisor, pgo_pool_sup, _} -> true;
        _ -> false
    end.

find_config([]) ->
    {error, nil};
find_config([Sup | Rest]) ->
    try supervisor:get_childspec(Sup, connection_sup) of
        {ok, #{start := {pgo_connection_sup, start_link, [_, _, _, Config]}}} -> {ok, Config};
        _ -> find_config(Rest)
    catch
        _:_ -> find_config(Rest)
    end.

%% Open one more connection to the pool's server and LISTEN on Channel,
%% calling Notify with each payload, until Owner exits. The connection is
%% pgo's own notification client, which reconnects on its own.
listen(Pool, Channel, Owner, Notify) ->
    case pool_config(Pool) of
        {error, nil} ->
            {error, nil};
        {ok, Config} ->
            Parent = self(),
            Pid = spawn(fun() -> start_listener(Parent, Config, Channel, Owner, Notify) end),
            receive
                {howdy_admin_listening, Pid, ok} -> {ok, nil};
                {howdy_admin_listening, Pid, error} -> {error, nil}
            after 5000 ->
                exit(Pid, kill),
                {error, nil}
            end
    end.

start_listener(Parent, Config, Channel, Owner, Notify) ->
    process_flag(trap_exit, true),
    Monitor = monitor(process, Owner),
    case pgo_notifications:start_link(Config) of
        {ok, Listener} ->
            case pgo_notifications:listen(Listener, Channel) of
                {Tag, _} when Tag =:= ok; Tag =:= eventually ->
                    Parent ! {howdy_admin_listening, self(), ok},
                    listener_loop(Listener, Monitor, Notify);
                _ ->
                    Parent ! {howdy_admin_listening, self(), error}
            end;
        _ ->
            Parent ! {howdy_admin_listening, self(), error}
    end.

listener_loop(Listener, Monitor, Notify) ->
    receive
        {notification, _, _, _, Payload} ->
            Notify(Payload),
            listener_loop(Listener, Monitor, Notify);
        {'DOWN', Monitor, process, _, _} ->
            try gen_statem:stop(Listener) catch _:_ -> ok end,
            ok;
        {'EXIT', Listener, _} ->
            ok;
        _ ->
            listener_loop(Listener, Monitor, Notify)
    end.
