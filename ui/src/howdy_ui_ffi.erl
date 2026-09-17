-module(howdy_ui_ffi).
-export([known/1, register/2, all_css/0, css_for/1,
         scope_begin/0, scope_end/0, note/1]).

-define(TABLE, howdy_ui_classes).
-define(SCOPE, howdy_ui_scope).

%% Classes live in a public ETS table so every process can look them up
%% without going through a shared process. Reads are concurrent; the only
%% writes happen the first time a class is seen.

known(Name) ->
    ensure_table(),
    ets:member(?TABLE, Name).

register(Name, Css) ->
    ensure_table(),
    Seq = erlang:unique_integer([monotonic]),
    ets:insert_new(?TABLE, {Name, Seq, Css}),
    nil.

all_css() ->
    ensure_table(),
    join(lists:keysort(2, ets:tab2list(?TABLE))).

%% The CSS for just these classes, in the order they were first seen.
css_for(Names) ->
    ensure_table(),
    Rows = lists:flatmap(fun(Name) -> ets:lookup(?TABLE, Name) end,
                         lists:usort(Names)),
    join(lists:keysort(2, Rows)).

join(Rows) ->
    iolist_to_binary(lists:join(<<"\n\n">>, [Css || {_, _, Css} <- Rows])).

%% -- Render scopes -----------------------------------------------------------
%%
%% A scope records which classes a view used, so a live component can ship
%% exactly the CSS it needs. Scopes are per process and nest.

scope_begin() ->
    Stack = case get(?SCOPE) of undefined -> []; S -> S end,
    put(?SCOPE, [[] | Stack]),
    nil.

scope_end() ->
    case get(?SCOPE) of
        [Names | Rest] ->
            put(?SCOPE, Rest),
            lists:reverse(Names);
        _ ->
            []
    end.

note(Name) ->
    case get(?SCOPE) of
        [Names | Rest] -> put(?SCOPE, [[Name | Names] | Rest]);
        _ -> ok
    end,
    nil.

%% -- Table ownership ---------------------------------------------------------
%%
%% Normal Gleam startup starts the howdy_ui application and its supervised
%% table owner before rendering. Preserve lazy use from a raw Erlang caller
%% by delegating startup to OTP, which serializes concurrent starts and
%% reports failures. There is no detached owner or unbounded acknowledgement.
ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            case application:ensure_all_started(howdy_ui) of
                {ok, _} -> gen_server:call(howdy_ui_cache, ready, 5000);
                {error, Reason} -> erlang:error({howdy_ui_start_failed, Reason})
            end;
        _ ->
            ok
    end.
