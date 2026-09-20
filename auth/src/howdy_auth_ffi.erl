-module(howdy_auth_ffi).
-export([now/0, with_repo_lock/2, normalize_password/1, canonical_host/1, cache_new/0, cache_run/4, cache_invalidate/0, cache_transaction/1, cache_changing/1,
         sessions_new/0, sessions_put/5, sessions_get/2, sessions_list/2, sessions_delete/3, sessions_delete_user/3, sessions_prune/2]).

now() -> erlang:system_time(second).

%% A fair mutex per Repo. One small server hands each Repo's lock to waiters
%% in arrival order, so contention costs a message round trip rather than the
%% randomised sleeps of global:trans. Run executes in the calling process,
%% which keeps Gloo's transaction and the caller's mailbox where they belong.
%% The lock is reentrant within a process and is released if its holder dies.
with_repo_lock(Repo, Run) ->
    Key = {howdy_auth_repo_lock, Repo},
    case get(Key) of
        true ->
            Run();
        _ ->
            {Server, Ref} = acquire(Repo),
            put(Key, true),
            try
                Run()
            after
                erase(Key),
                Server ! {release, self(), Repo},
                erlang:demonitor(Ref, [flush])
            end
    end.

acquire(Repo) ->
    Server = server(),
    Ref = erlang:monitor(process, Server),
    Server ! {acquire, self(), Ref, Repo},
    receive
        {granted, Ref} -> {Server, Ref};
        %% The server died before granting; a fresh one holds no locks.
        {'DOWN', Ref, process, _, _} -> acquire(Repo)
    end.

server() ->
    case whereis(howdy_auth_repo_locks) of
        undefined ->
            %% Unlinked: the server must outlive whichever request started it.
            %% Losing the registration race just exits the spare process.
            Pid = spawn(fun() ->
                try register(howdy_auth_repo_locks, self()) of
                    true ->
                        ets:new(howdy_auth_cache_versions, [named_table, public, set]),
                        ets:insert(howdy_auth_cache_versions, {generation, erlang:unique_integer([positive, monotonic])}),
                        serve(#{})
                catch
                    error:badarg -> ok
                end
            end),
            Ref = erlang:monitor(process, Pid),
            wait_registered(Pid, Ref);
        Pid ->
            Pid
    end.

wait_registered(Pid, Ref) ->
    case whereis(howdy_auth_repo_locks) of
        undefined ->
            receive
                {'DOWN', Ref, process, _, _} -> server()
            after 1 ->
                wait_registered(Pid, Ref)
            end;
        Registered ->
            erlang:demonitor(Ref, [flush]),
            Registered
    end.

%% Locks maps Repo => {Holder, HolderMonitor, Waiters}, where Waiters is a
%% queue of {Pid, GrantRef, Monitor}.
serve(Locks) ->
    receive
        {acquire, Pid, Ref, Repo} ->
            Monitor = erlang:monitor(process, Pid),
            case Locks of
                #{Repo := {Holder, HolderMonitor, Waiters}} ->
                    Waiting = queue:in({Pid, Ref, Monitor}, Waiters),
                    serve(Locks#{Repo := {Holder, HolderMonitor, Waiting}});
                _ ->
                    Pid ! {granted, Ref},
                    serve(Locks#{Repo => {Pid, Monitor, queue:new()}})
            end;
        {release, Pid, Repo} ->
            case Locks of
                #{Repo := {Pid, Monitor, Waiters}} ->
                    erlang:demonitor(Monitor, [flush]),
                    serve(grant_next(Repo, Waiters, Locks));
                _ ->
                    serve(Locks)
            end;
        {'DOWN', Monitor, process, Pid, _} ->
            serve(maps:fold(
                fun(Repo, {Holder, HolderMonitor, Waiters}, Acc) ->
                    case HolderMonitor of
                        Monitor ->
                            grant_next(Repo, Waiters, Acc);
                        _ ->
                            Alive = queue:filter(
                                fun({P, _, M}) -> not (P =:= Pid andalso M =:= Monitor) end,
                                Waiters
                            ),
                            Acc#{Repo := {Holder, HolderMonitor, Alive}}
                    end
                end,
                Locks,
                Locks
            ));
        _ ->
            serve(Locks)
    end.

grant_next(Repo, Waiters, Locks) ->
    case queue:out(Waiters) of
        {{value, {Pid, Ref, Monitor}}, Rest} ->
            Pid ! {granted, Ref},
            Locks#{Repo := {Pid, Monitor, Rest}};
        {empty, _} ->
            maps:remove(Repo, Locks)
    end.

normalize_password(Value) -> unicode:characters_to_nfc_binary(Value).


%% Caches belong to the process constructing Authorization (normally the app
%% supervisor). Generation changes bracket grant/suspension mutations, so a
%% slow read cannot install a stale grant after a mutation has committed.
cache_new() -> ets:new(howdy_auth_cache, [public, set, {read_concurrency, true}]).

cache_generation() ->
    Server = server(),
    try {Server, ets:lookup_element(howdy_auth_cache_versions, generation, 2)}
    catch error:badarg -> cache_generation() end.

cache_invalidate() ->
    _ = cache_generation(),
    try ets:update_counter(howdy_auth_cache_versions, generation, 1), nil
    catch error:badarg -> cache_invalidate() end.

cache_run(Table, Key, Seconds, Run) ->
    case get(howdy_auth_cache_dirty) of
        true -> Run();
        _ -> cache_read(Table, Key, Seconds, Run)
    end.

cache_read(Table, Key, Seconds, Run) ->
    Generation = cache_generation(),
    Now = erlang:monotonic_time(millisecond),
    Cached = try ets:lookup(Table, Key) catch error:badarg -> unavailable end,
    case Cached of
        unavailable -> Run();
        [{Key, Generation, Until, Value}] when Until > Now -> {ok, Value};
        _ ->
            Result = Run(),
            case Result of
                {ok, Value} ->
                    %% Bound memory independently of the number of distinct
                    %% sessions/permissions an application asks about.
                    try
                        with_repo_lock({auth_cache, Table}, fun() ->
                            case ets:info(Table, size) >= 10000 of
                                true -> ets:delete_all_objects(Table);
                                false -> ok
                            end,
                            ets:insert(Table, {Key, Generation, Now + Seconds * 1000, Value})
                        end)
                    catch error:badarg -> ok end;
                _ -> ok
            end,
            Result
    end.


canonical_host(Host) ->
    Lower = string:lowercase(binary_to_list(Host)),
    case inet:parse_address(Lower) of
        {ok, Address} -> {ok, list_to_binary(inet:ntoa(Address))};
        {error, _} ->
            %% IDNs must be configured using their ASCII (punycode) spelling.
            %% Reject URI forms the browser would escape or interpret as IPv4.
            Allowed = Lower =/= [] andalso lists:all(fun(C) ->
                (C >= $a andalso C =< $z) orelse
                (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $-
            end, Lower),
            Labels = string:split(Lower, ".", all),
            Last = lists:last(Labels),
            NumericEnd = Last =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Last),
            case Allowed andalso not NumericEnd of
                true -> {ok, list_to_binary(Lower)};
                false -> {error, nil}
            end
    end.


cache_transaction(Run) ->
    Key = howdy_auth_cache_transaction_depth,
    Depth = case get(Key) of undefined -> 0; N -> N end,
    put(Key, Depth + 1),
    try Run()
    after
        case Depth of
            0 ->
                erase(Key),
                case erase(howdy_auth_cache_dirty) of
                    true -> cache_invalidate();
                    _ -> ok
                end;
            _ -> put(Key, Depth)
        end
    end.

cache_changing(Run) ->
    cache_transaction(fun() ->
        put(howdy_auth_cache_dirty, true),
        cache_invalidate(),
        Run()
    end).

%% The in-memory session store: one public ETS table of
%% {Digest, UserId, ExpiresAt, Record}, owned by the process that made it.
sessions_new() -> ets:new(howdy_auth_sessions, [public, set, {read_concurrency, true}]).

sessions_put(Table, Digest, UserId, ExpiresAt, Record) ->
    ets:insert(Table, {Digest, UserId, ExpiresAt, Record}),
    nil.

sessions_get(Table, Digest) ->
    case ets:lookup(Table, Digest) of
        [{_, _, _, Record}] -> {some, Record};
        [] -> none
    end.

sessions_list(Table, UserId) ->
    [Record || [Record] <- ets:match(Table, {'_', UserId, '_', '$1'})].

sessions_delete(Table, Digest, UserId) ->
    ets:match_delete(Table, {Digest, UserId, '_', '_'}),
    nil.

sessions_delete_user(Table, UserId, Keep) ->
    ets:select_delete(Table, [{{'$1', UserId, '_', '_'}, [{'=/=', '$1', {const, Keep}}], [true]}]),
    nil.

sessions_prune(Table, Now) ->
    ets:select_delete(Table, [{{'_', '_', '$1', '_'}, [{'=<', '$1', Now}], [true]}]),
    nil.
