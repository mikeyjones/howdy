-module(howdy_remote_ffi).
-export([
    start_directory/1, dispatch/3, dispatch_local/2, run/2,
    call_cluster/3, call_node/4, cast_cluster/2, cast_node/3,
    multicall/3, apply/5, providers/1, connect/1, self_node/0
]).

%% Every started server is a small directory process. It joins one `pg`
%% group per procedure name and answers "which function handles this name?".
%% Calls never run inside the directory: `erpc` starts a fresh process on
%% the serving node, that process fetches the handler from the directory and
%% runs it. A slow or crashing handler therefore only affects its own call,
%% and `erpc` reports timeouts, crashes and lost nodes to the caller.
%%
%% Replies cross the wire as `{ok, Json}` for a handler's success and
%% `{error, Json}` for a service error. Transport failures are raised as the
%% constructors of the Gleam `remote.Error` type: `timeout`,
%% `{unavailable, Message}`, `{no_handler, Name}` and `{crashed, Message}`.

-define(SCOPE, howdy_remote).

%% Start the scope on first use. It is not linked to the caller, so it
%% outlives the server that happened to start it.
scope() ->
    case whereis(?SCOPE) of
        undefined ->
            case pg:start(?SCOPE) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end,
    ?SCOPE.

%% -- Serving ------------------------------------------------------------------

start_directory(Handlers) ->
    case proc_lib:start_link(erlang, apply, [fun directory_init/2, [self(), Handlers]]) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, format(Reason)}
    end.

directory_init(Parent, Handlers) ->
    Scope = scope(),
    lists:foreach(fun(Name) -> ok = pg:join(Scope, Name, self()) end, maps:keys(Handlers)),
    proc_lib:init_ack(Parent, {ok, self()}),
    directory_loop(Handlers).

directory_loop(Handlers) ->
    receive
        {howdy_remote_lookup, From, Ref, Name} ->
            From ! {Ref, maps:find(Name, Handlers)},
            directory_loop(Handlers);
        _ ->
            directory_loop(Handlers)
    end.

%% Run a call against the directory `Pid`, which lives on this node. The
%% directory may have stopped since the caller looked it up.
dispatch(Pid, Name, Payload) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {howdy_remote_lookup, self(), Ref, Name},
    receive
        {Ref, {ok, Handler}} ->
            erlang:demonitor(Ref, [flush]),
            Handler(Payload);
        {Ref, error} ->
            erlang:demonitor(Ref, [flush]),
            error({howdy_remote, {no_handler, Name}});
        {'DOWN', Ref, process, Pid, _} ->
            error({howdy_remote, {no_handler, Name}})
    end.

%% Run a call against any directory on this node that serves `Name`.
dispatch_local(Name, Payload) ->
    case pg:get_local_members(scope(), Name) of
        [] -> error({howdy_remote, {no_handler, Name}});
        Members -> dispatch(pick(Members), Name, Payload)
    end.

%% Run a handler in the calling process, turning an exception into
%% `{error, Message}`. Used by the HTTP transport, where no `erpc` process
%% stands between the handler and the connection.
run(Handler, Payload) ->
    try Handler(Payload) of
        Reply -> {ok, Reply}
    catch
        Class:Reason:Stack -> {error, format({Class, Reason, Stack})}
    end.

%% -- Calling ------------------------------------------------------------------

%% Prefer a server on this node: it needs no network hop and keeps working
%% while the node is cut off from the cluster.
call_cluster(Name, Payload, Timeout) ->
    Scope = scope(),
    case pg:get_local_members(Scope, Name) of
        [] ->
            case pg:get_members(Scope, Name) of
                [] -> {error, {no_handler, Name}};
                Members -> call_pid(pick(Members), Name, Payload, Timeout)
            end;
        Local ->
            call_pid(pick(Local), Name, Payload, Timeout)
    end.

call_pid(Pid, Name, Payload, Timeout) ->
    guard(fun() ->
        erpc:call(node(Pid), ?MODULE, dispatch, [Pid, Name, Payload], Timeout)
    end).

call_node(Node, Name, Payload, Timeout) ->
    guard(fun() ->
        erpc:call(to_node(Node), ?MODULE, dispatch_local, [Name, Payload], Timeout)
    end).

cast_cluster(Name, Payload) ->
    Scope = scope(),
    case pg:get_local_members(Scope, Name) ++ pg:get_members(Scope, Name) of
        [] -> nil;
        [Pid | _] when node(Pid) =:= node() -> cast(node(), Pid, Name, Payload);
        Members -> Pid = pick(Members), cast(node(Pid), Pid, Name, Payload)
    end.

cast(Node, Pid, Name, Payload) ->
    catch erpc:cast(Node, ?MODULE, dispatch, [Pid, Name, Payload]),
    nil.

cast_node(Node, Name, Payload) ->
    catch erpc:cast(to_node(Node), ?MODULE, dispatch_local, [Name, Payload]),
    nil.

%% Call every node that serves `Name`, in parallel. Returns `{Node, Result}`
%% pairs ordered by node name.
multicall(Name, Payload, Timeout) ->
    Nodes = lists:usort([node(Pid) || Pid <- pg:get_members(scope(), Name)]),
    Results = erpc:multicall(Nodes, ?MODULE, dispatch_local, [Name, Payload], Timeout),
    lists:zipwith(
        fun(Node, Result) -> {atom_to_binary(Node), multicall_result(Result)} end,
        Nodes,
        Results
    ).

multicall_result({ok, Reply}) -> {ok, Reply};
multicall_result({Class, Reason}) -> {error, failure(Class, Reason)}.

apply(Node, Module, Function, Args, Timeout) ->
    guard(fun() ->
        {ok, erpc:call(to_node(Node), binary_to_atom(Module), binary_to_atom(Function), Args, Timeout)}
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

guard(Call) ->
    try Call() of
        Reply -> Reply
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

pick([Only]) -> Only;
pick(Members) -> lists:nth(rand:uniform(length(Members)), Members).

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Term, 40])).
