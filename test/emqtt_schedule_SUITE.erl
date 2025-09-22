%%--------------------------------------------------------------------
%% Common Test suite for scheduled publish support
%%--------------------------------------------------------------------

-module(emqtt_schedule_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("emqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [schedule_fixed_jitter,
     schedule_mfa_variants].

suite() ->
    [{timetrap, {seconds, 60}}].

init_per_suite(Config) ->
    ok = emqtt_test_lib:start_emqx(),
    Config.

end_per_suite(_Config) ->
    emqtt_test_lib:stop_emqx().

init_per_testcase(_TC, Config) ->
    ok = emqtt_test_lib:ensure_quic_listener(mqtt, 14567),
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

schedule_fixed_jitter(_Config) ->
    Topic = unique_topic(),
    Interval = 200,
    Jitter = 400,
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc]} = emqtt:subscribe(Sub, #{}, [{Topic, [{qos, ?QOS_0}]}]),

    ScheduleFun = fun() -> #mqtt_msg{topic = Topic,
                                     qos = ?QOS_0,
                                     payload = <<"tick">>} end,
    ScheduleOpts = #{enabled => true,
                     mfa => ScheduleFun,
                     interval_ms => Interval,
                     jitter_ms => Jitter,
                     jitter_mode => fixed},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        ConnectedTs = wait_connected(),
        {FirstTs, _FirstMsg} = wait_publish(Topic, 5000),
        Delay = FirstTs - ConnectedTs,
        ?assert(Delay >= Jitter - 60),
        ?assert(Delay =< Jitter + 1000),
        {SecondTs, _SecondMsg} = wait_publish(Topic, 5000),
        Gap = SecondTs - FirstTs,
        ?assert(Gap >= Interval - 50),
        ?assert(Gap =< Interval + 500)
    after
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

schedule_mfa_variants(_Config) ->
    Topic = unique_topic(),
    Interval = 150,
    Ref = make_ref(),
    ok = emqtt_schedule_test_cb:init(Ref, Topic),
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc]} = emqtt:subscribe(Sub, #{}, [{Topic, [{qos, ?QOS_0}]}]),

    ScheduleOpts = #{enabled => true,
                     mfa => {emqtt_schedule_test_cb, next, [Ref]},
                     interval_ms => Interval,
                     jitter_ms => 10,
                     jitter_mode => uniform},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),
        Messages = collect_messages(3, Topic, 5000, []),
        Payloads = [maps:get(payload, Msg) || {_Ts, Msg} <- Messages],
        ?assertEqual([<<"tuple_payload">>,
                      <<"props_payload">>,
                      <<"msg_payload">>], Payloads)
    after
        ok = emqtt_schedule_test_cb:cleanup(Ref),
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

unique_topic() ->
    Unique = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    <<"schedule/", Unique/binary>>.

unique_clientid(Prefix) when is_binary(Prefix) ->
    Unique = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    <<Prefix/binary, "-", Unique/binary>>.

wait_connected() ->
    wait_connected(5000).

wait_connected(Timeout) ->
    receive
        {connected, _Props} -> mono_ms();
        Other ->
            ct:pal("ignoring unexpected message ~p while waiting for connected", [Other]),
            wait_connected(Timeout)
    after Timeout ->
        error({timeout, waiting_connected})
    end.

wait_publish(Topic, Timeout) ->
    receive
        {publish, #{topic := Topic} = Msg} ->
            {mono_ms(), Msg};
        {publish, _Other} ->
            wait_publish(Topic, Timeout);
        {connected, _} ->
            wait_publish(Topic, Timeout);
        Other ->
            ct:pal("ignoring unexpected message ~p while waiting for publish", [Other]),
            wait_publish(Topic, Timeout)
    after Timeout ->
        error({timeout, waiting_publish})
    end.

collect_messages(0, _Topic, _Timeout, Acc) ->
    lists:reverse(Acc);
collect_messages(N, Topic, Timeout, Acc) ->
    receive
        {publish, #{topic := Topic} = Msg} ->
            collect_messages(N - 1, Topic, Timeout, [{mono_ms(), Msg} | Acc]);
        {publish, _Other} ->
            collect_messages(N, Topic, Timeout, Acc);
        {connected, _} ->
            collect_messages(N, Topic, Timeout, Acc);
        Other ->
            ct:pal("ignoring unexpected message ~p while collecting", [Other]),
            collect_messages(N, Topic, Timeout, Acc)
    after Timeout ->
        error({timeout, {collect_messages, N}})
    end.

cleanup_client(Client) ->
    catch emqtt:disconnect(Client),
    catch emqtt:stop(Client),
    ok.

mono_ms() ->
    erlang:monotonic_time(millisecond).
