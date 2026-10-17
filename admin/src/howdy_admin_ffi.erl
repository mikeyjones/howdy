-module(howdy_admin_ffi).
-export([cells/1, postgres_pool/1, listen/5, listen_via/12, cached_token/2, cache_token/3, forget_token/2]).

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

%% FALLBACK, used only when the app did not say how to connect with
%% `howdy/admin.notify_via`. pgo has no public way to read a running
%% pool's settings, so this walks its supervision tree: the pool process is
%% linked to its `pgo_pool_sup`, whose `connection_sup` child spec carries
%% the settings as its last argument. Every step is guarded, so a pgo whose
%% shape has changed gives `{error, nil}` and the grid polls instead.
pool_config(Name) ->
    try
        case whereis(Name) of
            undefined ->
                {error, nil};
            Pool ->
                case process_info(Pool, links) of
                    {links, Links} ->
                        find_config([Pid || Pid <- Links, is_pid(Pid), is_pool_sup(Pid)]);
                    _ ->
                        {error, nil}
                end
        end
    catch
        _:_ -> {error, nil}
    end.

is_pool_sup(Pid) ->
    try proc_lib:initial_call(Pid) of
        {pgo_pool_sup, _, _} -> true;
        {supervisor, pgo_pool_sup, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

find_config([]) ->
    {error, nil};
find_config([Sup | Rest]) ->
    try supervisor:get_childspec(Sup, connection_sup) of
        {ok, #{start := {pgo_connection_sup, start_link, [_, _, _, Config]}}} when is_map(Config) ->
            {ok, Config};
        _ ->
            find_config(Rest)
    catch
        _:_ -> find_config(Rest)
    end.

%% The settings for a listening connection, from what the app gave
%% `howdy/admin.notify_via`: the public fields of a `pog.Config`, turned
%% into pgo's map the way pog itself does.
listener_config(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion) ->
    HostList = unicode:characters_to_list(Host),
    {SslActivated, SslOptions} = ssl_options(HostList, Ssl),
    Config = #{
        host => HostList,
        port => Port,
        database => unicode:characters_to_list(Database),
        user => unicode:characters_to_list(User),
        ssl => SslActivated,
        ssl_options => SslOptions,
        connection_parameters => Parameters,
        socket_options => case IpVersion of ipv6 -> [inet6]; _ -> [] end
    },
    case Password of
        {some, Pw} -> Config#{password => unicode:characters_to_list(Pw)};
        none -> Config
    end.

ssl_options(_Host, ssl_disabled) ->
    {false, []};
ssl_options(_Host, ssl_unverified) ->
    {true, [{verify, verify_none}]};
ssl_options(Host, ssl_verified) ->
    {true, [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ]}.

%% Listen through the pool's own settings, found by the fallback above.
listen(Pool, Channel, Owner, Notify, Lost) ->
    case pool_config(Pool) of
        {error, nil} -> {error, nil};
        {ok, Config} -> listen_with(Config, Channel, Owner, Notify, Lost)
    end.

%% Listen with settings the app gave.
listen_via(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion, Channel, Owner, Notify, Lost) ->
    Config = listener_config(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion),
    listen_with(Config, Channel, Owner, Notify, Lost).

%% Open one more connection to the server and LISTEN on Channel, calling
%% Notify with each payload, until Owner exits. The connection is pgo's own
%% notification client, which reconnects on its own. The listener is linked
%% to the caller, the grid's runtime, so neither outlives the other, and its
%% answer carries a reference of this call's own so a late one can never be
%% mistaken for anything else in the caller's mailbox.
listen_with(Config, Channel, Owner, Notify, Lost) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() -> start_listener(Parent, Ref, Config, Channel, Owner, Notify, Lost) end),
    receive
        {howdy_admin_listening, Ref, ok} -> {ok, nil};
        {howdy_admin_listening, Ref, error} -> {error, nil}
    after 5000 ->
        unlink(Pid),
        exit(Pid, kill),
        receive
            {howdy_admin_listening, Ref, _} -> ok
        after 0 ->
            ok
        end,
        {error, nil}
    end.

start_listener(Parent, Ref, Config, Channel, Owner, Notify, Lost) ->
    process_flag(trap_exit, true),
    Monitor = monitor(process, Owner),
    Started = try pgo_notifications:start_link(Config) catch _:_ -> error end,
    case Started of
        {ok, Listener} ->
            Listening = try pgo_notifications:listen(Listener, Channel) catch _:_ -> error end,
            case Listening of
                {Tag, _} when Tag =:= ok; Tag =:= eventually ->
                    Parent ! {howdy_admin_listening, Ref, ok},
                    listener_loop(Listener, Monitor, Notify, Lost);
                _ ->
                    stop_listener(Listener),
                    Parent ! {howdy_admin_listening, Ref, error}
            end;
        _ ->
            Parent ! {howdy_admin_listening, Ref, error}
    end.

listener_loop(Listener, Monitor, Notify, Lost) ->
    receive
        {notification, _, _, _, Payload} ->
            Notify(Payload),
            listener_loop(Listener, Monitor, Notify, Lost);
        {'DOWN', Monitor, process, _, _} ->
            stop_listener(Listener);
        {'EXIT', Listener, _} ->
            %% The connection went; tell the owner so it stops expecting us.
            Lost(),
            ok;
        {'EXIT', _Parent, _} ->
            stop_listener(Listener);
        _ ->
            listener_loop(Listener, Monitor, Notify, Lost)
    end.

stop_listener(Listener) ->
    try gen_statem:stop(Listener) catch _:_ -> ok end.

%% Session tokens the API pages hold for the users they call as, so each
%% call does not open a new session. Development only, and rarely written,
%% which is what persistent_term suits. One map holds them all, keyed by
%% the Auth they were opened with as well as the user, so two auths never
%% hand out each other's tokens; it keeps the newest ?TOKEN_LIMIT, and an
%% entry goes when the admin revokes the user's sessions, deletes the user
%% or is told the token no longer works.
-define(TOKENS, howdy_admin_api_tokens).
-define(TOKEN_LIMIT, 32).

tokens() ->
    persistent_term:get(?TOKENS, #{}).

cached_token(Auth, UserId) ->
    case maps:find({Auth, UserId}, tokens()) of
        {ok, {_At, Token}} -> {ok, Token};
        error -> {error, nil}
    end.

cache_token(Auth, UserId, Token) ->
    Tokens = maps:remove({Auth, UserId}, tokens()),
    Trimmed = case map_size(Tokens) >= ?TOKEN_LIMIT of
        true -> drop_oldest(Tokens);
        false -> Tokens
    end,
    At = erlang:unique_integer([monotonic]),
    persistent_term:put(?TOKENS, Trimmed#{{Auth, UserId} => {At, Token}}),
    nil.

forget_token(Auth, UserId) ->
    Tokens = tokens(),
    case maps:is_key({Auth, UserId}, Tokens) of
        true -> persistent_term:put(?TOKENS, maps:remove({Auth, UserId}, Tokens));
        false -> ok
    end,
    nil.

drop_oldest(Tokens) ->
    {Oldest, _} = maps:fold(
        fun(Key, {At, _}, {_, Best}) when Best =:= undefined; At < Best -> {Key, At};
           (_, _, Acc) -> Acc
        end,
        {undefined, undefined},
        Tokens
    ),
    maps:remove(Oldest, Tokens).
