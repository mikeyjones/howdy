-module(howdy_admin_test_ffi).
-export([getenv/1, links/0]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% The processes linked to this one, to pick out one just spawned.
links() ->
    {links, Links} = process_info(self(), links),
    [Pid || Pid <- Links, is_pid(Pid)].
