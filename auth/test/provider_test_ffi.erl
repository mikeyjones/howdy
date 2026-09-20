-module(provider_test_ffi).
-export([sign/2, jwks/0]).
-include_lib("public_key/include/public_key.hrl").

key() ->
    case persistent_term:get({?MODULE, key}, undefined) of
        undefined ->
            Key = public_key:generate_key({rsa, 2048, 65537}),
            persistent_term:put({?MODULE, key}, Key), Key;
        Key -> Key
    end.

b64(Value) -> base64:encode(Value, #{mode => url, padding => false}).
sign(Payload, Header) ->
    Message = <<(b64(Header))/binary, ".", (b64(Payload))/binary>>,
    Signature = public_key:sign(Message, sha256, key()),
    <<Message/binary, ".", (b64(Signature))/binary>>.

jwks() ->
    #'RSAPrivateKey'{modulus=N, publicExponent=E} = key(),
    iolist_to_binary(json:encode(#{<<"keys">> => [#{<<"kty">> => <<"RSA">>,
      <<"kid">> => <<"test-key">>, <<"alg">> => <<"RS256">>, <<"use">> => <<"sig">>,
      <<"n">> => b64(binary:encode_unsigned(N)), <<"e">> => b64(binary:encode_unsigned(E))}]})).
