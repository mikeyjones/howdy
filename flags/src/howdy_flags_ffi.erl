-module(howdy_flags_ffi).
-export([publish/2, current/1, withdraw/1, arguments/0, halt/1, getenv/1]).

%% Each running Flags keeps its settings in persistent_term: every check reads
%% them without copying, and they change only when someone changes a flag, so
%% the global scan a replacement costs is rare. The key holds a reference, so
%% separate instances, such as in tests, never share settings.
publish(Key, Snapshot) ->
    persistent_term:put(Key, Snapshot),
    nil.

current(Key) -> persistent_term:get(Key).

withdraw(Key) ->
    persistent_term:erase(Key),
    nil.

%% The command's arguments: what `gleam run -m tasks/flags ...` passes, or
%% what follows `-extra` on an `erl` command line.
arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

halt(Code) -> erlang:halt(Code).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
