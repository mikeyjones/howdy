-module(howdy_auth_test_ffi).
-export([totp_code/2, count_verifications/1, backend/0, delete_file/1]).
backend() ->
    case os:getenv("HOWDY_AUTH_TEST_BACKEND") of
        false -> <<"sqlite">>;
        Value -> list_to_binary(Value)
    end.

delete_file(Path) -> ok = file:delete(Path), nil.


%% Count calls, not elapsed time. Test-only tracing never prints arguments.
count_verifications(Run) ->
    Parent = self(),
    Tracer = spawn(fun() -> verification_traces(Parent, 0, undefined) end),
    erlang:trace_pattern({argus, verify, 2}, true, [local]),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    try
        Result = Run(),
        erlang:trace(self(), false, [call]),
        Tracer ! finish,
        receive {verification_count, Tracer, Count} -> {Result, Count}
        after 5000 -> error(trace_timeout) end
    after
        erlang:trace(self(), false, [call]),
        erlang:trace_pattern({argus, verify, 2}, false, [local]),
        exit(Tracer, kill)
    end.

verification_traces(Parent, Count, Ref) ->
    receive
        {trace, Parent, call, {argus, verify, _}} -> verification_traces(Parent, Count + 1, Ref);
        finish -> verification_traces(Parent, Count, erlang:trace_delivered(Parent));
        {trace_delivered, Parent, Ref} -> Parent ! {verification_count, self(), Count}
    end.

%% Independent test authenticator, using RFC 4226 dynamic truncation.
totp_code(Seed, Seconds) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    Values = [begin {I,1} = binary:match(Alphabet, <<C>>), I end || <<C>> <= Seed],
    Key = << <<V:5>> || V <- Values >>,
    H = crypto:mac(hmac, sha, Key, <<(Seconds div 30):64>>),
    O = binary:last(H) band 15,
    <<_:O/binary, N:32, _/binary>> = H,
    list_to_binary(io_lib:format("~6..0B", [(N band 16#7fffffff) rem 1000000])).
