-module(provider_test_ffi).
-export([sign/2, jwks/0, certificate/0, saml_sign/2, saml_sign_other/2, inflate/1, instant/1]).
-include_lib("xmerl/include/xmerl.hrl").
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

%% --- SAML: the same key, behind a self-signed certificate -------------------

certificate() ->
    case persistent_term:get({?MODULE, certificate}, undefined) of
        undefined ->
            Path = filename:join("/tmp", "howdy-saml-" ++ integer_to_list(erlang:unique_integer([positive]))),
            ok = file:write_file(Path ++ ".key",
                public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', key())])),
            _ = os:cmd("openssl req -x509 -new -key " ++ Path ++ ".key -subj /CN=idp.test -days 30 -out " ++ Path ++ ".pem"),
            {ok, Pem} = file:read_file(Path ++ ".pem"),
            file:delete(Path ++ ".key"), file:delete(Path ++ ".pem"),
            persistent_term:put({?MODULE, certificate}, Pem), Pem;
        Pem -> Pem
    end.

%% Sign the element with this ID inside Xml, enveloped, RSA-SHA256, exclusive
%% canonicalisation: what Okta, Entra and Google produce. Returns the XML.
saml_sign(Xml, Id) -> saml_sign(Xml, Id, key()).
saml_sign(Xml, Id, Key) ->
    {Root, _} = xmerl_scan:string(binary_to_list(Xml), [{namespace_conformant, true}]),
    Target = find(Root, binary_to_list(Id)),
    Digest = base64:encode(crypto:hash(sha256, canonical(Target))),
    Info = iolist_to_binary(
        [<<"<ds:SignedInfo xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">">>,
         <<"<ds:CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"/>">>,
         <<"<ds:SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha256\"/>">>,
         <<"<ds:Reference URI=\"#">>, Id, <<"\"><ds:Transforms>">>,
         <<"<ds:Transform Algorithm=\"http://www.w3.org/2000/09/xmldsig#enveloped-signature\"/>">>,
         <<"<ds:Transform Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"/></ds:Transforms>">>,
         <<"<ds:DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha256\"/>">>,
         <<"<ds:DigestValue>">>, Digest, <<"</ds:DigestValue></ds:Reference></ds:SignedInfo>">>]),
    {InfoElement, _} = xmerl_scan:string(binary_to_list(Info), [{namespace_conformant, true}]),
    Proof = base64:encode(public_key:sign(canonical(InfoElement), sha256, Key)),
    Signature = iolist_to_binary(
        [<<"<ds:Signature xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">">>,
         binary:replace(Info, <<" xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\"">>, <<>>),
         <<"<ds:SignatureValue>">>, Proof, <<"</ds:SignatureValue></ds:Signature>">>]),
    %% The signature goes straight after the target's Issuer, as the schema asks.
    Marker = <<"<!--sign:", Id/binary, "-->">>,
    [Before, After] = binary:split(Xml, Marker),
    <<Before/binary, Signature/binary, After/binary>>.

other_key() ->
    case persistent_term:get({?MODULE, other}, undefined) of
        undefined ->
            Key = public_key:generate_key({rsa, 2048, 65537}),
            persistent_term:put({?MODULE, other}, Key), Key;
        Key -> Key
    end.
saml_sign_other(Xml, Id) -> saml_sign(Xml, Id, other_key()).

canonical(Element) ->
    unicode:characters_to_binary(howdy_auth_c14n:c14n(Element, false, []), unicode, utf8).

find(#xmlElement{attributes = Attributes, content = Content} = Element, Id) ->
    case [V || #xmlAttribute{name = 'ID', value = V} <- Attributes] of
        [Id] -> Element;
        _ -> first([find(E, Id) || E = #xmlElement{} <- Content])
    end.
first([]) -> undefined;
first([undefined | Rest]) -> first(Rest);
first([Found | _]) -> Found.

inflate(Encoded) -> zlib:unzip(base64:decode(Encoded)).

instant(Seconds) ->
    list_to_binary(calendar:system_time_to_rfc3339(Seconds, [{offset, "Z"}])).
