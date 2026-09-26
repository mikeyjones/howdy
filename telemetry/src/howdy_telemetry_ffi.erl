-module(howdy_telemetry_ffi).
-export([idle/0, start/5, flush/0, getenv/1]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(HANDLER, howdy_telemetry).
%% How opentelemetry_api caches tracers in persistent_term.
-define(TRACER_KEY(Name), {opentelemetry, ?GLOBAL_TRACER_PROVIDER_NAME, tracer, Name}).

%% Stop the tracer provider the SDK started at boot, or the one `start`
%% made, and fall back to the API's no-op tracer, exactly as if no SDK were
%% installed: nothing is recorded or sent, and a trace arriving from
%% another service passes through untouched rather than being marked as
%% not sampled.
idle() ->
    _ = logger:remove_handler(?HANDLER),
    stop_providers(),
    persistent_term:put(?TRACER_KEY('$__default_tracer'), {otel_tracer_noop, []}),
    forget_tracers(),
    nil.

%% Exporters arrive as the Gleam constructors of `howdy/telemetry.Exporter`:
%% `{otlp, Endpoint, Headers}` and `{record, Recorder}`. Ratio is an option.
start(Service, Attributes, Exporters, Ratio, JsonLogs) ->
    case os:getenv("OTEL_SDK_DISABLED") of
        "true" ->
            idle(),
            {ok, nil};
        _ ->
            Resource = resource(Service, Attributes),
            Processors = [processor(Exporter, Resource) || Exporter <- Exporters],
            application:set_env(opentelemetry, processors, Processors),
            application:set_env(opentelemetry, sampler, sampler(Ratio)),
            Recorders = [Recorder || {record, Recorder} <- Exporters],
            case replace_provider(Resource) of
                ok ->
                    logs(Recorders),
                    json_logs(JsonLogs),
                    {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(io_lib:format("~0tp", [Reason]))}
            end
    end.

processor({otlp, Endpoint, Headers}, Resource) ->
    Config0 = #{protocol => http_protobuf},
    Config1 = case Endpoint of
        {some, Url} -> Config0#{endpoints => [binary_to_list(Url)]};
        none -> Config0
    end,
    Config = case Headers of
        [] -> Config1;
        _ -> Config1#{headers => [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers]}
    end,
    %% The batch processor sends its own copy of the resource, and without
    %% one it uses what the SDK detected at boot, which has no service name.
    {otel_batch_processor, #{exporter => {opentelemetry_exporter, Config},
                             resource => Resource}};
processor({record, Recorder}, _Resource) ->
    {howdy_telemetry_recorder, #{recorder => Recorder}}.

%% Parent based, so a request that arrives already sampled, or not, by the
%% service that called it keeps that decision.
sampler(none) ->
    {parent_based, #{root => always_on}};
sampler({some, Ratio}) ->
    {parent_based, #{root => {trace_id_ratio_based, Ratio}}}.

%% OTEL_SERVICE_NAME, when set, wins over the name given in code, so one
%% build can report under different names in different places.
resource(Service, Attributes) ->
    Detected = otel_resource_detector:get_resource(),
    Named = case os:getenv("OTEL_SERVICE_NAME") of
        false -> [{'service.name', Service}];
        _ -> []
    end,
    Ours = otel_resource:create(Named ++ [{binary_to_atom(K), V} || {K, V} <- Attributes]),
    otel_resource:merge(Ours, Detected).

%% Swap the global tracer provider for one built from the current app env.
%% Restarting the whole SDK application would also work, but it logs an
%% exit report and drops spans while its exporter comes back up.
replace_provider(Resource) ->
    Config = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    case whereis(otel_tracer_provider_sup) of
        undefined ->
            {error, opentelemetry_not_started};
        _ ->
            stop_providers(),
            otel_span_limits:set(Config),
            %% The new provider makes itself the default tracer as it starts.
            case otel_tracer_provider_sup:start(?GLOBAL_TRACER_PROVIDER_NAME, Resource, Config) of
                {ok, _} ->
                    forget_tracers(),
                    opentelemetry:create_application_tracers(application:loaded_applications()),
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

stop_providers() ->
    case whereis(otel_tracer_provider_sup) of
        undefined ->
            ok;
        _ ->
            [supervisor:terminate_child(otel_tracer_provider_sup, Pid)
             || {_, Pid, _, _} <- supervisor:which_children(otel_tracer_provider_sup),
                is_pid(Pid)],
            ok
    end.

%% Tracers hold their provider's sampler and processors, and the API caches
%% one per application, so drop the cached ones when the provider changes.
forget_tracers() ->
    [persistent_term:erase(Key)
     || {Key = ?TRACER_KEY(Name), _} <- persistent_term:get(),
        Name =/= '$__default_tracer'],
    ok.

logs(Recorders) ->
    _ = logger:remove_handler(?HANDLER),
    ok = logger:add_handler(?HANDLER, howdy_telemetry_logs,
                            #{level => all,
                              config => #{recorders => Recorders}}).

json_logs(false) ->
    ok;
json_logs(true) ->
    _ = logger:update_handler_config(default, formatter, {howdy_telemetry_json, #{}}),
    ok.

flush() ->
    _ = otel_tracer_provider:force_flush(),
    nil.

%% An empty variable counts as unset, as the OpenTelemetry spec asks.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
