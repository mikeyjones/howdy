-module(howdy_auth_example_ffi).
-export([google_credentials/0]).

google_credentials() ->
    case {os:getenv("GOOGLE_CLIENT_ID"), os:getenv("GOOGLE_CLIENT_SECRET")} of
        {false, false} -> none;
        {Id, Secret} -> {some, {value(Id), value(Secret)}}
    end.

value(false) -> <<>>;
value(Value) -> unicode:characters_to_binary(Value).
