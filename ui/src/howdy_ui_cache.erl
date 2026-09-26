-module(howdy_ui_cache).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Own the table independently of renderers. All normal cache access remains
%% direct ETS access; the server only participates in startup and supervision.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(howdy_ui_classes, [set, public, named_table, {read_concurrency, true}]),
    {ok, nil}.

handle_call(ready, _From, State) ->
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
