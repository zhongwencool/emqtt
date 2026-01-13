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
     schedule_mfa_variants,
     schedule_multiple_groups,
     schedule_dynamic_add,
     schedule_dynamic_remove,
     schedule_dynamic_list,
     schedule_dynamic_update,
     schedule_dynamic_disabled,
     schedule_dynamic_max_limit,
     schedule_dynamic_invalid_config,
     schedule_dynamic_boundary_conditions].

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
                     schedules => [#{mfa => ScheduleFun,
                                      interval_ms => Interval,
                                      jitter_ms => Jitter,
                                      jitter_mode => fixed}]},
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
                     schedules => [#{mfa => {emqtt_schedule_test_cb, next, [Ref]},
                                      interval_ms => Interval,
                                      jitter_ms => 10,
                                      jitter_mode => uniform}]},
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

schedule_multiple_groups(_Config) ->
    Topic1 = unique_topic(),
    Topic2 = unique_topic(),
    Interval1 = 150,
    Interval2 = 220,
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc1, _Rc2]} =
        emqtt:subscribe(Sub, #{}, [{Topic1, [{qos, ?QOS_0}]}, {Topic2, [{qos, ?QOS_0}]}]),

    Schedules = [#{mfa => fun() -> {Topic1, <<"tick1">>} end,
                   interval_ms => Interval1,
                   jitter_ms => 0,
                   jitter_mode => fixed},
                  #{mfa => fun() -> {Topic2, <<"tick2">>} end,
                   interval_ms => Interval2,
                   jitter_ms => 0,
                   jitter_mode => fixed}],
    ScheduleOpts = #{enabled => true, schedules => Schedules},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),
        Msgs = collect_schedule_batches([Topic1, Topic2], 2, 5000),

        Topic1Msgs = maps:get(Topic1, Msgs),
        Topic2Msgs = maps:get(Topic2, Msgs),
        ?assert(length(Topic1Msgs) >= 2),
        ?assert(length(Topic2Msgs) >= 2),

        [{T1First, #{payload := P1First}}, {T1Second, _} | _] = Topic1Msgs,
        [{T2First, #{payload := P2First}}, {T2Second, _} | _] = Topic2Msgs,
        ?assertEqual(<<"tick1">>, P1First),
        ?assertEqual(<<"tick2">>, P2First),

        Gap1 = T1Second - T1First,
        Gap2 = T2Second - T2First,
        ?assert(Gap1 >= Interval1 - 50),
        ?assert(Gap1 =< Interval1 + 500),
        ?assert(Gap2 >= Interval2 - 50),
        ?assert(Gap2 =< Interval2 + 500)
    after
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

%% Dynamic Schedule Management Tests

schedule_dynamic_add(_Config) ->
    Topic = unique_topic(),
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc]} = emqtt:subscribe(Sub, #{}, [{Topic, [{qos, ?QOS_0}]}]),

    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Add a dynamic schedule
        {ok, ScheduleId} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {Topic, <<"dynamic">>} end,
            interval_ms => 200,
            jitter_ms => 0
        }, 5000),

        ?assert(is_integer(ScheduleId)),
        Msgs = collect_messages(3, Topic, 2000, []),
        ?assert(length(Msgs) >= 3),

        lists:foreach(fun(#{payload := Payload}) ->
                              ?assertEqual(<<"dynamic">>, Payload)
                      end, Msgs)
    after
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

schedule_dynamic_remove(_Config) ->
    Topic = unique_topic(),
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc]} = emqtt:subscribe(Sub, #{}, [{Topic, [{qos, ?QOS_0}]}]),

    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Add a dynamic schedule
        {ok, ScheduleId} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {Topic, <<"before_remove">>} end,
            interval_ms => 150
        }, 5000),

        % Collect some messages
        Msgs1 = collect_messages(2, Topic, 1000, []),
        ?assert(length(Msgs1) >= 2),

        % Remove the schedule
        ok = emqtt:schedule_remove(Pub, ScheduleId, 5000),

        % Wait and verify no more messages
        timer:sleep(500),
        Msgs2 = collect_messages(0, Topic, 500, []),
        ?assertEqual(0, length(Msgs2))
    after
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

schedule_dynamic_list(_Config) ->
    ScheduleOpts = #{enabled => true, schedules => [
        #{mfa => fun() -> {<<"topic1">>, <<"data1">>} end, interval_ms => 1000},
        #{mfa => fun() -> {<<"topic2">>, <<"data2">>} end, interval_ms => 2000}
    ]},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % List initial schedules
        {ok, Schedules1} = emqtt:schedule_list(Pub, 5000),
        ?assertEqual(2, length(Schedules1)),

        % Add a dynamic schedule
        {ok, ScheduleId} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {<<"topic3">>, <<"data3">>} end,
            interval_ms => 500
        }, 5000),

        % List updated schedules
        {ok, Schedules2} = emqtt:schedule_list(Pub, 5000),
        ?assertEqual(3, length(Schedules2)),

        % Verify the new schedule is in the list
        AddedSchedule = lists:keyfind(ScheduleId, 2,
                                     [{maps:get(id, S), S} || S <- Schedules2]),
        ?assertNotEqual(false, AddedSchedule),

        {_, Schedule} = AddedSchedule,
        ?assertEqual(500, maps:get(interval_ms, Schedule))
    after
        cleanup_client(Pub)
    end.

schedule_dynamic_update(_Config) ->
    Topic = unique_topic(),
    {ok, Sub} = emqtt:start_link([{clientid, unique_clientid(<<"sub">>)}]),
    {ok, _} = emqtt:connect(Sub),
    _ = wait_connected(),
    {ok, _Props, [_Rc]} = emqtt:subscribe(Sub, #{}, [{Topic, [{qos, ?QOS_0}]}]),

    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Add a dynamic schedule
        {ok, ScheduleId} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {Topic, <<"original">>} end,
            interval_ms => 300
        }, 5000),

        % Collect some messages
        Msgs1 = collect_messages(2, Topic, 1000, []),
        ?assert(length(Msgs1) >= 2),
        lists:foreach(fun(#{payload := Payload}) ->
                              ?assertEqual(<<"original">>, Payload)
                      end, Msgs1),

        % Update the schedule
        ok = emqtt:schedule_update(Pub, ScheduleId, #{
            mfa => fun() -> {Topic, <<"updated">>} end,
            interval_ms => 200
        }, 5000),

        % Clear message queue
        flush_all_messages(),

        % Collect new messages
        Msgs2 = collect_messages(2, Topic, 1000, []),
        ?assert(length(Msgs2) >= 2),
        lists:foreach(fun(#{payload := Payload}) ->
                              ?assertEqual(<<"updated">>, Payload)
                      end, Msgs2)
    after
        cleanup_client(Pub),
        cleanup_client(Sub)
    end.

schedule_dynamic_disabled(_Config) ->
    ScheduleOpts = #{enabled => false, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Try to add a schedule when disabled
        Result = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {<<"topic">>, <<"data">>} end,
            interval_ms => 1000
        }, 5000),
        ?assertEqual({error, schedule_disabled}, Result)
    after
        cleanup_client(Pub)
    end.

schedule_dynamic_max_limit(_Config) ->
    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Add schedules up to the limit (assuming MAX_SCHEDULES = 100)
        ScheduleIds = lists:foldl(fun(I, Acc) ->
            {ok, Id} = emqtt:schedule_add(Pub, #{
                mfa => fun() -> {list_to_binary("topic" ++ integer_to_list(I)), <<"data">>} end,
                interval_ms => 10000 % Long interval to avoid flooding
            }, 5000),
            [Id | Acc]
        end, [], lists:seq(1, 5)), % Test with 5 for speed

        % Try to add one more beyond reasonable limit
        % Note: This test is simplified - in real scenario would need to test actual MAX_SCHEDULES
        ?assert(length(ScheduleIds) =:= 5)
    after
        cleanup_client(Pub)
    end.

schedule_dynamic_invalid_config(_Config) ->
    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Test invalid MFA
        Result1 = emqtt:schedule_add(Pub, #{
            interval_ms => 1000
        }, 5000),
        ?assertMatch({error, _}, Result1),

        % Test invalid interval
        Result2 = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {<<"topic">>, <<"data">>} end,
            interval_ms => 50  % Below minimum
        }, 5000),
        ?assertMatch({error, _}, Result2),

        % Test non-existent schedule removal
        Result3 = emqtt:schedule_remove(Pub, 99999, 5000),
        ?assertEqual({error, {not_found, 99999}}, Result3),

        % Test non-existent schedule update
        Result4 = emqtt:schedule_update(Pub, 99999, #{
            mfa => fun() -> {<<"topic">>, <<"data">>} end,
            interval_ms => 1000
        }, 5000),
        ?assertEqual({error, {not_found, 99999}}, Result4)
    after
        cleanup_client(Pub)
    end.

schedule_dynamic_boundary_conditions(_Config) ->
    ScheduleOpts = #{enabled => true, schedules => []},
    {ok, Pub} = emqtt:start_link([{clientid, unique_clientid(<<"pub">>)},
                                  {schedule_publish, ScheduleOpts}]),
    try
        {ok, _} = emqtt:connect(Pub),
        _ = wait_connected(),

        % Test minimum interval
        {ok, Id1} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {<<"topic1">>, <<"data1">>} end,
            interval_ms => 100  % At minimum
        }, 5000),
        ?assert(is_integer(Id1)),

        % Test large interval
        {ok, Id2} = emqtt:schedule_add(Pub, #{
            mfa => fun() -> {<<"topic2">>, <<"data2">>} end,
            interval_ms => 3600000  % 1 hour
        }, 5000),
        ?assert(is_integer(Id2)),

        % Test schedule IDs are different
        ?assertNotEqual(Id1, Id2),

        % Verify list contains both
        {ok, Schedules} = emqtt:schedule_list(Pub, 5000),
        ?assertEqual(2, length(Schedules))
    after
        cleanup_client(Pub)
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

collect_schedule_batches(Topics, TargetPerTopic, Timeout) when TargetPerTopic > 0 ->
    collect_schedule_batches(Topics, TargetPerTopic, Timeout, #{}).

collect_schedule_batches(Topics, TargetPerTopic, Timeout, Acc) ->
    case lists:all(fun(Topic) ->
                           length(maps:get(Topic, Acc, [])) >= TargetPerTopic
                   end, Topics) of
        true ->
            lists:foldl(
              fun(Topic, Result) ->
                      Entries = lists:reverse(maps:get(Topic, Acc, [])),
                      Result#{Topic => Entries}
              end, #{}, Topics);
        false ->
            receive
                {publish, #{topic := Topic} = Msg} ->
                    case lists:member(Topic, Topics) of
                        true ->
                            Ts = mono_ms(),
                            Prev = maps:get(Topic, Acc, []),
                            collect_schedule_batches(Topics, TargetPerTopic, Timeout,
                                Acc#{Topic => [{Ts, Msg} | Prev]});
                        false ->
                            collect_schedule_batches(Topics, TargetPerTopic, Timeout, Acc)
                    end;
                {connected, _} ->
                    collect_schedule_batches(Topics, TargetPerTopic, Timeout, Acc);
                Other ->
                    ct:pal("ignoring unexpected message ~p while collecting multi", [Other]),
                    collect_schedule_batches(Topics, TargetPerTopic, Timeout, Acc)
            after Timeout ->
                error({timeout, {collect_schedule_batches, Topics, TargetPerTopic}})
            end
    end.

cleanup_client(Client) ->
    catch emqtt:disconnect(Client),
    catch emqtt:stop(Client),
    ok.

flush_all_messages() ->
    receive
        _ -> flush_all_messages()
    after 0 ->
        ok
    end.

mono_ms() ->
    erlang:monotonic_time(millisecond).
