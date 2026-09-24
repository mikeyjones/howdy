-module(howdy_database_ffi).
-export([with_lock/2, around_runs/2, run_hooks/0, getenv/1, monotonic_ms/0]).

%% A fair mutex per key, normally a Repo. One small server hands each key's
%% lock to waiters in arrival order, so contention costs a message round trip
%% rather than the randomised sleeps of global:trans. Run executes in the
%% calling process, which keeps Gloo's transaction and the caller's mailbox
%% where they belong. The lock is reentrant within a process and is released
%% if its holder dies.
with_lock(Lock, Run) ->
    Key = {howdy_database_lock, Lock},
    case get(Key) of
        true ->
            Run();
        _ ->
            {Server, Ref} = acquire(Lock),
            put(Key, true),
            try
                Run()
            after
                erase(Key),
                Server ! {release, self(), Lock},
                erlang:demonitor(Ref, [flush])
            end
    end.

acquire(Lock) ->
    Server = server(),
    Ref = erlang:monitor(process, Server),
    Server ! {acquire, self(), Ref, Lock},
    receive
        {granted, Ref} -> {Server, Ref};
        %% The server died before granting; a fresh one holds no locks.
        {'DOWN', Ref, process, _, _} -> acquire(Lock)
    end.

server() ->
    case whereis(howdy_database_locks) of
        undefined ->
            %% Unlinked: the server must outlive whichever request started it.
            %% Losing the registration race just exits the spare process.
            Pid = spawn(fun() ->
                try register(howdy_database_locks, self()) of
                    true -> serve(#{})
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
    case whereis(howdy_database_locks) of
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

%% Locks maps Lock => {Holder, HolderMonitor, Waiters}, where Waiters is a
%% queue of {Pid, GrantRef, Monitor}.
serve(Locks) ->
    receive
        {acquire, Pid, Ref, Lock} ->
            Monitor = erlang:monitor(process, Pid),
            case Locks of
                #{Lock := {Holder, HolderMonitor, Waiters}} ->
                    Waiting = queue:in({Pid, Ref, Monitor}, Waiters),
                    serve(Locks#{Lock := {Holder, HolderMonitor, Waiting}});
                _ ->
                    Pid ! {granted, Ref},
                    serve(Locks#{Lock => {Pid, Monitor, queue:new()}})
            end;
        {release, Pid, Lock} ->
            case Locks of
                #{Lock := {Pid, Monitor, Waiters}} ->
                    erlang:demonitor(Monitor, [flush]),
                    serve(grant_next(Lock, Waiters, Locks));
                _ ->
                    serve(Locks)
            end;
        {'DOWN', Monitor, process, Pid, _} ->
            serve(maps:fold(
                fun(Lock, {Holder, HolderMonitor, Waiters}, Acc) ->
                    case HolderMonitor of
                        Monitor ->
                            grant_next(Lock, Waiters, Acc);
                        _ ->
                            Alive = queue:filter(
                                fun({P, _, M}) -> not (P =:= Pid andalso M =:= Monitor) end,
                                Waiters
                            ),
                            Acc#{Lock := {Holder, HolderMonitor, Alive}}
                    end
                end,
                Locks,
                Locks
            ));
        _ ->
            serve(Locks)
    end.

grant_next(Lock, Waiters, Locks) ->
    case queue:out(Waiters) of
        {{value, {Pid, Ref, Monitor}}, Rest} ->
            Pid ! {granted, Ref},
            Locks#{Lock := {Pid, Monitor, Rest}};
        {empty, _} ->
            maps:remove(Lock, Locks)
    end.

%% Hooks bracketing migration runs on this node, in name order. Registration
%% is rare and idempotent, so persistent_term's update cost is not paid twice.
around_runs(Name, Hook) ->
    with_lock(howdy_database_run_hooks, fun() ->
        case persistent_term:get(howdy_database_run_hooks, #{}) of
            #{Name := Hook} -> nil;
            Hooks -> persistent_term:put(howdy_database_run_hooks, Hooks#{Name => Hook}), nil
        end
    end).

run_hooks() ->
    [Hook || {_, Hook} <- lists:sort(maps:to_list(persistent_term:get(howdy_database_run_hooks, #{})))].

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).
