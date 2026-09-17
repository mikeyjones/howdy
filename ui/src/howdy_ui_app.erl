-module(howdy_ui_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, howdy_ui_supervisor}, ?MODULE, []).

stop(_State) -> ok.

init([]) ->
    Owner = #{id => howdy_ui_cache,
              start => {howdy_ui_cache, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [howdy_ui_cache]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Owner]}}.
