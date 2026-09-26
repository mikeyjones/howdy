-module(howdy_telemetry_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

%% The OpenTelemetry SDK is an application, so it starts at boot with its
%% defaults, before any app code runs, and those defaults export to
%% localhost:4318. Until `telemetry.start` configures it, stop that provider
%% so adding the package records and sends nothing by itself.
start(_Type, _Args) ->
    howdy_telemetry_ffi:idle(),
    supervisor:start_link(?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    {ok, {#{strategy => one_for_one}, []}}.
