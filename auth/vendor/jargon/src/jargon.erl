-module(jargon).

-author("Isaac Harris-Holt").

-export([hash/7, verify/2]).

-on_load init/0.

-define(APPNAME, jargon).
-define(LIBNAME, jargon).

init() ->
    SoName =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                case filelib:is_dir(
                         filename:join(["..", priv]))
                of
                    true ->
                        filename:join(["..", priv, ?LIBNAME]);
                    _ ->
                        filename:join([priv, ?LIBNAME])
                end;
            Dir ->
                filename:join(Dir, ?LIBNAME)
        end,
    erlang:load_nif(SoName, 0).

%% @doc 
%% Hash a password with Argon2.
%%
%% @param Password The password to hash.
%% @param Salt The salt to use for hashing. Must be at least 32 bytes (8 base64 characters).
%% @param Algorithm The Argon2 algorithm to use. Must be one of 'argon2d', 'argon2i', or 'argon2id'.
%% @param TimeCost The number of iterations to use.
%% @param MemoryCost The amount of memory to use.
%% @param Parallelism The number of threads to use.
%% @param HashLen The length of the hash to return.
%%
-spec hash(Password :: binary(), Salt :: binary(), Algorithm :: argon2d | argon2i | argon2id, TimeCost :: pos_integer(), MemoryCost :: pos_integer(), Parallelism :: pos_integer(), HashLen :: pos_integer()) -> {ok, RawHash :: binary(), EncodedHash :: binary()} | {error, Error :: atom()}.
hash(Password, Salt, Algorithm, TimeCost, MemoryCost, Parallelism, HashLen) ->
    AlgorithmInt =
        case Algorithm of
            argon2d ->
                0;
            argon2i ->
                1;
            argon2id ->
                2;
            _ ->
                3
        end,
    case AlgorithmInt of
        3 ->
            {error, invalid_algorithm};
        _ ->
            case hash_nif(Password, Salt, AlgorithmInt, TimeCost, MemoryCost, Parallelism, HashLen)
            of
                {ok, RawHash, EncodedHash} ->
                    {ok, RawHash, EncodedHash};
                {error, Error} ->
                    {error, hash_error_code_to_string(Error)}
            end
    end.

hash_error_code_to_string(Error) when is_integer(Error), Error =:= -1 ->
    output_pointer_is_null;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -2 ->
    output_too_short;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -3 ->
    output_too_long;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -4 ->
    password_too_short;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -5 ->
    password_too_long;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -6 ->
    salt_too_short;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -7 ->
    salt_too_long;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -8 ->
    associated_data_too_short;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -9 ->
    associated_data_too_long;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -10 ->
    secret_too_short;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -11 ->
    secret_too_long;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -12 ->
    time_cost_too_small;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -13 ->
    time_cost_too_large;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -14 ->
    memory_cost_too_small;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -15 ->
    memory_cost_too_large;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -16 ->
    too_few_lanes;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -17 ->
    too_many_lanes;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -18 ->
    password_pointer_mismatch;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -19 ->
    salt_pointer_mismatch;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -20 ->
    secret_pointer_mismatch;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -21 ->
    associated_data_pointer_mismatch;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -22 ->
    memory_allocation_error;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -23 ->
    free_memory_callback_null;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -24 ->
    allocate_memory_callback_null;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -25 ->
    incorrect_parameter;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -26 ->
    incorrect_type;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -27 ->
    output_pointer_mismatch;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -28 ->
    too_few_threads;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -29 ->
    too_many_threads;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -30 ->
    not_enough_memory;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -31 ->
    encoding_failed;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -32 ->
    decoding_failed;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -33 ->
    thread_failure;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -34 ->
    decoding_length_failure;
hash_error_code_to_string(Error) when is_integer(Error), Error =:= -35 ->
    verification_mismatch;
hash_error_code_to_string(_) ->
    unknown_error_code.

hash_nif(_Password, _Salt, _Algorithm, _TimeCost, _MemoryCost, _Parallelism, _HashLen) ->
    erlang:nif_error(nif_library_not_loaded).

%% @doc 
%% Verify an encoded hash against a password.
%%
-spec verify(EncodedHash :: binary(), Password :: binary()) -> {ok, true} | {ok, false} | {error, Error :: atom()}.
verify(EncodedHash, Password) ->
    AlgorithmInt =
        case EncodedHash of
            %% Starts with $argon2i$
            <<"$argon2d$", _/binary>> ->
                0;
            %% Starts with $argon2d$
            <<"$argon2i$", _/binary>> ->
                1;
            %% Starts with $argon2id$
            <<"$argon2id$", _/binary>> ->
                2;
            _ ->
                3
        end,
    case AlgorithmInt of
        3 ->
            {error, invalid_algorithm};
        _ ->
            case verify_nif(EncodedHash, Password, AlgorithmInt) of
                {ok, true} ->
                    {ok, true};
                {ok, false} ->
                    {ok, false};
                {error, Error} ->
                    {error, hash_error_code_to_string(Error)}
            end
    end.

verify_nif(_EncodedHash, _Password, _Algorithm) ->
    erlang:nif_error(nif_library_not_loaded).
