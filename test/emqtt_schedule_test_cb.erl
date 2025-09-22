%%--------------------------------------------------------------------
%% Test helper for schedule publish callbacks
%%--------------------------------------------------------------------

-module(emqtt_schedule_test_cb).

-include("emqtt.hrl").

-export([init/2, cleanup/1, next/1]).

-spec init(reference(), binary()) -> ok.
init(Ref, Topic) when is_reference(Ref), is_binary(Topic) ->
    persistent_term:put({?MODULE, Ref}, {0, Topic}),
    ok.

-spec cleanup(reference()) -> ok.
cleanup(Ref) when is_reference(Ref) ->
    persistent_term:erase({?MODULE, Ref}),
    ok.

-spec next(reference()) -> skip | #mqtt_msg{} | {binary(), binary()} |
                             {binary(), map(), iodata(), [term()]}.
next(Ref) when is_reference(Ref) ->
    case persistent_term:get({?MODULE, Ref}, undefined) of
        undefined ->
            skip;
        {N, Topic} ->
            Value = case N of
                        0 -> skip;
                        1 -> {Topic, <<"tuple_payload">>};
                        2 -> {Topic, #{}, <<"props_payload">>, [{qos, ?QOS_0}]};
                        3 -> #mqtt_msg{topic = Topic,
                                       qos = ?QOS_0,
                                       payload = <<"msg_payload">>};
                        _ -> skip
                    end,
            persistent_term:put({?MODULE, Ref}, {N + 1, Topic}),
            Value
    end.
