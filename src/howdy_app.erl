%% The howdy application: a supervisor for the processes the framework
%% keeps for the whole node, today the `pg` scope behind WebSocket channels.
%% It starts at boot with the application, and lazily from the first channel
%% call when the node was not booted through the application controller,
%% as in `gleam test`.
-module(howdy_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, ensure_started/0]).

-define(SCOPE, howdy_websocket_channels).

start(_Type, _Args) ->
    supervisor:start_link({local, howdy_supervisor}, ?MODULE, []).

stop(_State) -> ok.

init([]) ->
    Scope = #{id => channel_scope,
              start => {pg, start_link, [?SCOPE]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [pg]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Scope]}}.

%% Make sure the scope is running, whichever way the node was started.
ensure_started() ->
    case whereis(?SCOPE) of
        undefined ->
            case application:ensure_all_started(howdy) of
                {ok, _} -> await_scope(50);
                {error, Reason} -> error({howdy_start_failed, Reason})
            end;
        _ ->
            ok
    end.

%% The supervisor restarts the scope if it dies; a caller that raced the
%% restart waits briefly for it.
await_scope(0) -> error({howdy_start_failed, channel_scope_missing});
await_scope(N) ->
    case whereis(?SCOPE) of
        undefined -> timer:sleep(10), await_scope(N - 1);
        _ -> ok
    end.
