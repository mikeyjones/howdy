-module(howdy_database_test_ffi).
-export([lock_serializes/0, lock_reentrant/0, lock_holder_exit/0]).

lock_serializes() ->
    Lock = make_ref(),
    Parent = self(),
    Counter = atomics:new(1, []),
    Workers = [spawn_monitor(fun() ->
        lists:foreach(fun(_) ->
            howdy_database_ffi:with_lock(Lock, fun() ->
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
    Lock = make_ref(),
    howdy_database_ffi:with_lock(Lock, fun() ->
        howdy_database_ffi:with_lock(Lock, fun() -> true end)
    end).

lock_holder_exit() ->
    Lock = make_ref(),
    Parent = self(),
    {Holder, Monitor} = spawn_monitor(fun() ->
        howdy_database_ffi:with_lock(Lock, fun() ->
            Parent ! {holding, self()},
            receive stop -> ok end
        end)
    end),
    receive {holding, Holder} -> ok after 1000 -> error(lock_timeout) end,
    exit(Holder, kill),
    receive {'DOWN', Monitor, process, Holder, killed} -> ok
    after 1000 -> error(holder_did_not_exit) end,
    howdy_database_ffi:with_lock(Lock, fun() -> true end).
