-module(howdy_auth_test_ffi).
-export([count_verifications/1, backend/0, delete_file/1, lock_serializes/0, lock_reentrant/0, lock_holder_exit/0]).
backend() ->
    case os:getenv("HOWDY_AUTH_TEST_BACKEND") of
        false -> <<"sqlite">>;
        Value -> list_to_binary(Value)
    end.

delete_file(Path) -> ok = file:delete(Path), nil.


lock_serializes() ->
    Repo = make_ref(),
    Parent = self(),
    Counter = atomics:new(1, []),
    Workers = [spawn_monitor(fun() ->
        lists:foreach(fun(_) ->
            howdy_auth_ffi:with_repo_lock(Repo, fun() ->
                1 = atomics:add_get(Counter, 1, 1),
                timer:sleep(1),
                0 = atomics:sub_get(Counter, 1, 1)
            end)
        end, lists:seq(1, 10)),
        Parent ! {done, self()}
    end) || _ <- lists:seq(1, 8)],
    lists:foreach(fun({Pid, Monitor}) ->
        receive {done, Pid} -> ok after 5000 -> error(lock_timeout) end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 1000 -> error(worker_failed) end
    end, Workers),
    atomics:get(Counter, 1) =:= 0.

lock_reentrant() ->
    Repo = make_ref(),
    howdy_auth_ffi:with_repo_lock(Repo, fun() ->
        howdy_auth_ffi:with_repo_lock(Repo, fun() -> true end)
    end).

lock_holder_exit() ->
    Repo = make_ref(),
    Parent = self(),
    {Holder, Monitor} = spawn_monitor(fun() ->
        howdy_auth_ffi:with_repo_lock(Repo, fun() ->
            Parent ! {holding, self()},
            receive stop -> ok end
        end)
    end),
    receive {holding, Holder} -> ok after 1000 -> error(lock_timeout) end,
    exit(Holder, kill),
    receive {'DOWN', Monitor, process, Holder, killed} -> ok
    after 1000 -> error(holder_did_not_exit) end,
    howdy_auth_ffi:with_repo_lock(Repo, fun() -> true end).


%% Count calls, not elapsed time. Test-only tracing never prints arguments.
count_verifications(Run) ->
    Parent = self(),
    Tracer = spawn(fun() -> verification_traces(Parent, 0, undefined) end),
    erlang:trace_pattern({argus, verify, 2}, true, [local]),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    try
        Result = Run(),
        erlang:trace(self(), false, [call]),
        Tracer ! finish,
        receive {verification_count, Tracer, Count} -> {Result, Count}
        after 5000 -> error(trace_timeout) end
    after
        erlang:trace(self(), false, [call]),
        erlang:trace_pattern({argus, verify, 2}, false, [local]),
        exit(Tracer, kill)
    end.

verification_traces(Parent, Count, Ref) ->
    receive
        {trace, Parent, call, {argus, verify, _}} -> verification_traces(Parent, Count + 1, Ref);
        finish -> verification_traces(Parent, Count, erlang:trace_delivered(Parent));
        {trace_delivered, Parent, Ref} -> Parent ! {verification_count, self(), Count}
    end.
