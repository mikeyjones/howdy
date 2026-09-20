-module(howdy_auth_oidc_ffi).
-export([verify/2, protect/1, keys_new/0, keys_read/1, keys_write/3]).
-include_lib("public_key/include/public_key.hrl").

%% Fixed Google RS256 compact-JWS verifier using OTP's public_key primitive.
%% Keys come only from Google's pinned JWKS endpoint. No algorithm negotiation,
%% header-supplied keys/URLs, detached payloads, or critical extensions.
verify(Signed, Keys) when byte_size(Signed) =< 32768, byte_size(Keys) =< 1048576 ->
    try
        [Protected, Payload, Signature] = binary:split(Signed, <<".">>, [global]),
        Header = json:decode(unbase64(Protected)),
        #{<<"alg">> := <<"RS256">>, <<"kid">> := Kid} = Header,
        true = is_binary(Kid) andalso byte_size(Kid) > 0,
        false = maps:is_key(<<"crit">>, Header),
        false = maps:is_key(<<"b64">>, Header),
        #{<<"keys">> := Candidates} = json:decode(Keys),
        [Key] = [K || K = #{<<"kid">> := Id, <<"kty">> := <<"RSA">>} <- Candidates,
                      Id =:= Kid, maps:get(<<"use">>, K, <<"sig">>) =:= <<"sig">>,
                      maps:get(<<"alg">>, K, <<"RS256">>) =:= <<"RS256">>],
        N = unbase64(maps:get(<<"n">>, Key)),
        E = unbase64(maps:get(<<"e">>, Key)),
        true = byte_size(N) >= 256 andalso byte_size(N) =< 1024,
        true = byte_size(E) > 0 andalso byte_size(E) =< 8,
        Public = #'RSAPublicKey'{modulus = binary:decode_unsigned(N),
                                 publicExponent = binary:decode_unsigned(E)},
        true = public_key:verify(<<Protected/binary, ".", Payload/binary>>,
                                 sha256, unbase64(Signature), Public),
        {ok, unbase64(Payload)}
    catch _:_ -> {error, nil} end;
verify(_, _) -> {error, nil}.

unbase64(Value) -> base64:decode(Value, #{mode => url, padding => false}).

protect(Run) ->
    try Run()
    catch _:_ -> {error, {internal, <<"Google request failed">>}} end.

%% The startup process owns this bounded cache. If it has exited, requests
%% continue without caching rather than crashing or trusting stale keys.
keys_new() -> ets:new(howdy_auth_google_keys, [public, set]).
keys_read(Table) ->
    try case ets:lookup(Table, keys) of
        [{keys, Body, Until}] -> {some, {Body, Until}};
        [] -> none
    end catch error:badarg -> none end.
keys_write(Table, Body, Until) ->
    try ets:insert(Table, {keys, Body, Until}) catch error:badarg -> ok end,
    nil.
