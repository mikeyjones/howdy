-module(howdy_remote_ffi).
-export([
    start_directory/1, dispatch/4, dispatch_local/3, run/2,
    call_cluster/4, call_node/5, cast_cluster/3, cast_node/4, spawn_cast/1,
    multicall/4, apply/5, providers/1, connect/1, self_node/0,
    scope/0, init_casts/0
]).

%% Servers are `howdy_remote_directory` processes, one per started server,
%% found through the `howdy_remote` pg scope. `erpc` runs each call in a
%% fresh process on the serving node.
%%
%% Replies cross the wire as `{ok, Json}` for a handler's success and
%% `{error, Json}` for a service error. Transport failures are raised as the
%% constructors of the Gleam `remote.Error` type: `timeout`,
%% `{unavailable, Message}`, `{no_handler, Name}` and `{crashed, Message}`.

-define(SCOPE, howdy_remote).
-define(CASTS_KEY, {?MODULE, casts}).
%% Casts in flight at once, over HTTP or looking for a server, before more
%% are dropped. A cast promises nothing, so under a flood dropping beats
%% growing without bound.
-define(MAX_CASTS, 64).
-define(DISCOVERY_MS, 1000).

%% The scope is a child of the `howdy_remote` application's supervisor.
%% Callers outside a boot, such as a peer node that has only just loaded
%% the code, start the application on first use.
scope() ->
    case whereis(?SCOPE) of
        undefined ->
            case application:ensure_all_started(?SCOPE) of
                {ok, _} -> ok;
                {error, _} -> start_unsupervised()
            end;
        _ ->
            ok
    end,
    ?SCOPE.

%% Only if the application cannot start, as when the code is on the path
%% but the `.app` is not.
start_unsupervised() ->
    case pg:start(?SCOPE) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

%% -- Serving ------------------------------------------------------------------

start_directory(Handlers) ->
    case howdy_remote_directory:start_link(Handlers) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, format(Reason)}
    end.

%% Run a call against the directory `Pid`, which lives on this node. The
%% directory may have stopped since the caller looked it up. `Trace` holds
%% the caller's trace headers, so the handler's span joins its trace.
dispatch(Pid, Name, Payload, Trace) ->
    case howdy_remote_directory:lookup(Pid, Name) of
        {ok, Handler} -> Handler(Payload, {some, Trace});
        error -> error({howdy_remote, {no_handler, Name}})
    end.

%% Run a call against any directory on this node that serves `Name`.
dispatch_local(Name, Payload, Trace) ->
    case pg:get_local_members(scope(), Name) of
        [] -> error({howdy_remote, {no_handler, Name}});
        Members -> dispatch(pick(Members), Name, Payload, Trace)
    end.

%% Run a handler in the calling process, turning an exception into
%% `{error, Message}`. Used by the HTTP transport, where no `erpc` process
%% stands between the handler and the connection.
run(Handler, Payload) ->
    try Handler(Payload, none) of
        Reply -> {ok, Reply}
    catch
        Class:Reason:Stack -> {error, format({Class, Reason, Stack})}
    end.

%% -- Calling ------------------------------------------------------------------

call_cluster(Name, Payload, Trace, Timeout) ->
    case choose(Name, Timeout) of
        {ok, Pid} ->
            guard(fun() ->
                erpc:call(node(Pid), ?MODULE, dispatch, [Pid, Name, Payload, Trace], Timeout)
            end);
        {error, Error} ->
            {error, Error}
    end.

call_node(Node, Name, Payload, Trace, Timeout) ->
    guard(fun() ->
        erpc:call(to_node(Node), ?MODULE, dispatch_local, [Name, Payload, Trace], Timeout)
    end).

%% Nothing waits: a server pg already knows gets the cast at once, and
%% when pg knows none, asking the connected nodes happens in a process of
%% its own, bounded by `DISCOVERY_MS`, which drops the cast if nothing
%% serves `Name`.
cast_cluster(Name, Payload, Trace) ->
    Scope = scope(),
    case known(Scope, Name) of
        {ok, Pid} ->
            safe_cast(node(Pid), dispatch, [Pid, Name, Payload, Trace]);
        none ->
            spawn_cast(fun() ->
                case ask_connected(Scope, Name, ?DISCOVERY_MS) of
                    {ok, Pid} ->
                        safe_cast(node(Pid), dispatch, [Pid, Name, Payload, Trace]);
                    {error, _} ->
                        logger:debug("howdy_remote: dropped cast to ~ts, nothing serves it", [Name])
                end
            end)
    end,
    nil.

cast_node(Node, Name, Payload, Trace) ->
    safe_cast(to_node(Node), dispatch_local, [Name, Payload, Trace]),
    nil.

%% Call every node that serves `Name`, in parallel. Returns `{Node, Result}`
%% pairs ordered by node name.
multicall(Name, Payload, Trace, Timeout) ->
    Scope = scope(),
    Members = case pg:get_members(Scope, Name) of
        [] -> connected_members(Scope, Name, Timeout);
        Known -> Known
    end,
    Nodes = lists:usort([node(Pid) || Pid <- Members]),
    Results = erpc:multicall(Nodes, ?MODULE, dispatch_local, [Name, Payload, Trace], Timeout),
    lists:zipwith(
        fun(Node, Result) -> {atom_to_binary(Node), multicall_result(Result)} end,
        Nodes,
        Results
    ).

multicall_result({ok, Reply}) -> {ok, Reply};
multicall_result({Class, Reason}) -> {error, failure(Class, Reason)}.

apply(Node, Module, Function, Args, Timeout) ->
    guard(fun() ->
        erpc:call(to_node(Node), binary_to_atom(Module), binary_to_atom(Function), Args, Timeout)
    end).

%% The nodes with a server for `Name`, sorted.
providers(Name) ->
    [atom_to_binary(Node) || Node <- lists:usort([node(Pid) || Pid <- pg:get_members(scope(), Name)])].

connect(Node) ->
    case net_kernel:connect_node(to_node(Node)) of
        true -> {ok, nil};
        false -> {error, {unavailable, <<"could not connect to ", Node/binary>>}};
        ignored -> {error, {unavailable, <<"this node is not distributed">>}}
    end.

self_node() ->
    atom_to_binary(node()).

%% -- Helpers ------------------------------------------------------------------

%% Run `Fun` in a process of its own, unlinked, while fewer than
%% `MAX_CASTS` such processes are running; otherwise drop it.
spawn_cast(Fun) ->
    Casts = casts(),
    case atomics:add_get(Casts, 1, 1) of
        Count when Count > ?MAX_CASTS ->
            atomics:sub(Casts, 1, 1),
            logger:warning("howdy_remote: dropped cast, ~p already in flight", [?MAX_CASTS]);
        _ ->
            spawn(fun() ->
                try Fun() after atomics:sub(Casts, 1, 1) end
            end)
    end,
    nil.

init_casts() ->
    case persistent_term:get(?CASTS_KEY, undefined) of
        undefined -> persistent_term:put(?CASTS_KEY, atomics:new(1, []));
        _ -> ok
    end.

casts() ->
    case persistent_term:get(?CASTS_KEY, undefined) of
        undefined ->
            init_casts(),
            persistent_term:get(?CASTS_KEY);
        Casts ->
            Casts
    end.

%% `erpc:cast` only raises for arguments it cannot use, such as a malformed
%% node name. A cast promises nothing, so that is dropped too.
safe_cast(Node, Function, Args) ->
    try erpc:cast(Node, ?MODULE, Function, Args) catch error:_ -> ok end.

guard(Call) ->
    try Call() of
        Reply -> {ok, Reply}
    catch
        Class:Reason -> {error, failure(Class, Reason)}
    end.

failure(error, {erpc, timeout}) -> timeout;
failure(error, {erpc, noconnection}) -> {unavailable, <<"node is not connected">>};
failure(error, {erpc, Reason}) -> {unavailable, format(Reason)};
failure(error, {exception, {howdy_remote, Error}, _}) -> Error;
failure(error, {exception, Reason, Stack}) -> {crashed, format({error, Reason, Stack})};
failure(exit, {exception, Reason}) -> {crashed, format({exit, Reason})};
failure(exit, {signal, Reason}) -> {crashed, format({exit, Reason})};
failure(throw, Value) -> {crashed, format({throw, Value})};
failure(Class, Reason) -> {crashed, format({Class, Reason})}.

to_node(Node) when is_binary(Node) -> binary_to_atom(Node);
to_node(Node) -> Node.

%% Prefer a server on this node: it needs no network hop and keeps working
%% while the node is cut off from the cluster.
choose(Name, Timeout) ->
    Scope = scope(),
    case known(Scope, Name) of
        {ok, Pid} -> {ok, Pid};
        none -> ask_connected(Scope, Name, Timeout)
    end.

%% A server pg knows of now, local first.
known(Scope, Name) ->
    case pg:get_local_members(Scope, Name) of
        [] ->
            case pg:get_members(Scope, Name) of
                [] -> none;
                Members -> {ok, pick(Members)}
            end;
        Local ->
            {ok, pick(Local)}
    end.

%% `pg` learns about other nodes' members asynchronously, so a scope that
%% has only just started, or a node that has only just connected, can look
%% empty for a moment. Before reporting that nothing serves `Name`, ask the
%% connected nodes directly.
ask_connected(Scope, Name, Timeout) ->
    case connected_members(Scope, Name, Timeout) of
        [] -> {error, {no_handler, Name}};
        Members -> {ok, pick(Members)}
    end.

connected_members(Scope, Name, Timeout) ->
    Replies = erpc:multicall(nodes(), pg, get_local_members, [Scope, Name], Timeout),
    lists:append([Pids || {ok, Pids} <- Replies]).

pick([Only]) -> Only;
pick(Members) -> lists:nth(rand:uniform(length(Members)), Members).

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Term, 40])).
