# EMQTT Telemetry Integration

This document describes the telemetry events emitted by the EMQTT client library and how to use them for monitoring, metrics collection, and observability.

## Overview

EMQTT integrates with the [Telemetry](https://github.com/beam-telemetry/telemetry) library to emit events at key points in the MQTT client lifecycle. These events can be used to:

- Monitor data transfer rates and volumes
- Track connection health and performance
- Implement custom metrics and alerting
- Debug network issues
- Analyze client behavior patterns

## Enabling Telemetry

Telemetry emission is disabled by default. Enable it explicitly when starting the client by passing the `telemetry` option:

```erlang
{ok, ClientPid} = emqtt:start_link([
    {host, "localhost"},
    {telemetry, true}
]).
```

Passing `{telemetry, false}` keeps telemetry disabled.

## Available Events

### 1. WebSocket Data Reception

**Event Name:** `[emqtt, websocket, recv_data]`

Emitted when data is received over a WebSocket connection.

**Measurements:**
- `data_size` (integer) - Size of received data in bytes

**Metadata:**
- `client_id` (binary) - MQTT client identifier
- `socket_type` (atom) - Always `websocket` for this event
- `connection_module` (atom) - Connection module used
- `protocol_version` (integer) - MQTT protocol version
- `pid` (pid) - Process ID of the client
- `data`  (binary) - Data received, as binary

### 2. Socket Data Reception

**Event Name:** `[emqtt, socket, recv_data]`

Emitted when data is received over TCP or SSL connections.

**Measurements:**
- `data_size` (integer) - Size of received data in bytes

**Metadata:**
- `client_id` (binary) - MQTT client identifier
- `socket_type` (atom) - `tcp`, `ssl`, or `quic`
- `connection_module` (atom) - Connection module used
- `protocol_version` (integer) - MQTT protocol version
- `pid` (pid) - Process ID of the client
- `data`  (binary) - Data received, as binary

### 3. Data Send Success

**Event Name:** `[emqtt, socket, send_data]`

Emitted when data is successfully sent to the server.

**Measurements:**
- `data_size` (integer) - Size of sent data in bytes

**Metadata:**
- `client_id` (binary) - MQTT client identifier
- `socket_type` (atom) - `tcp`, `ssl`, `quic`, or `websocket`
- `connection_module` (atom) - Connection module used
- `protocol_version` (integer) - MQTT protocol version
- `pid` (pid) - Process ID of the client
- `data`  (packet tuple) - Data sent, as a parsed MQTT packet tuple

### 4. Data Send Failure

**Event Name:** `[emqtt, socket, send_data_failed]`

Emitted when data fails to be sent to the server.

**Measurements:**
- `data_size` (integer) - Size of data that failed to send in bytes

**Metadata:**
- `client_id` (binary) - MQTT client identifier
- `socket_type` (atom) - `tcp`, `ssl`, `quic`, or `websocket`
- `connection_module` (atom) - Connection module used
- `protocol_version` (integer) - MQTT protocol version
- `pid` (pid) - Process ID of the client
- `reason` (term) - Reason for the send failure


## Usage Examples

### Basic Event Handler

```erlang
-module(emqtt_telemetry_handler).

-include_lib("kernel/include/logger.hrl").

%% Simple logging handler
handle_event([emqtt, websocket, recv_data], Measurements, Metadata, _Config) ->
    ?LOG_INFO("WebSocket received ~p bytes from client ~s", 
              [maps:get(data_size, Measurements), maps:get(client_id, Metadata)]);

handle_event([emqtt, socket, recv_data], Measurements, Metadata, _Config) ->
    ?LOG_INFO("Socket (~s) received ~p bytes from client ~s", 
              [maps:get(socket_type, Metadata), 
               maps:get(data_size, Measurements), 
               maps:get(client_id, Metadata)]);

handle_event([emqtt, socket, send_data], Measurements, Metadata, _Config) ->
    ?LOG_INFO("Successfully sent ~p bytes from client ~s", 
              [maps:get(data_size, Measurements), maps:get(client_id, Metadata)]);

handle_event([emqtt, socket, send_data_failed], Measurements, Metadata, _Config) ->
    ?LOG_WARNING("Failed to send ~p bytes from client ~s: ~p", 
                 [maps:get(data_size, Measurements), 
                  maps:get(client_id, Metadata),
                  maps:get(reason, Metadata)]);

handle_event(_Event, _Measurements, _Metadata, _Config) ->
    ok.
```

### Attaching the Handler

```erlang
%% Attach handler to all EMQTT telemetry events
ok = telemetry:attach_many(
    "emqtt-telemetry-handler",
    [
        [emqtt, websocket, recv_data],
        [emqtt, socket, recv_data],
        [emqtt, socket, send_data],
        [emqtt, socket, send_data_failed]
    ],
    fun emqtt_telemetry_handler:handle_event/4,
    []
).
```

### Metrics Collection Example

```erlang
-module(emqtt_metrics_collector).

%% Metrics collection using counters
handle_event([emqtt, _, recv_data], #{data_size := Size}, #{client_id := ClientId}, _Config) ->
    counters:add(get_counter(ClientId, bytes_received), 1, Size),
    counters:add(get_counter(ClientId, packets_received), 1, 1);

handle_event([emqtt, socket, send_data], #{data_size := Size}, #{client_id := ClientId}, _Config) ->
    counters:add(get_counter(ClientId, bytes_sent), 1, Size),
    counters:add(get_counter(ClientId, packets_sent), 1, 1);

handle_event([emqtt, socket, send_data_failed], _Measurements, #{client_id := ClientId}, _Config) ->
    counters:add(get_counter(ClientId, send_failures), 1, 1);

handle_event(_Event, _Measurements, _Metadata, _Config) ->
    ok.

get_counter(ClientId, Metric) ->
    %% Implementation depends on your metrics storage
    persistent_term:get({emqtt_metrics, ClientId, Metric}).
```

### Prometheus Integration Example

```erlang
-module(emqtt_prometheus_handler).

handle_event([emqtt, _, recv_data], #{data_size := Size}, Metadata, _Config) ->
    prometheus_counter:inc(emqtt_bytes_received_total, 
                          [maps:get(client_id, Metadata), 
                           maps:get(socket_type, Metadata)], Size);

handle_event([emqtt, socket, send_data], #{data_size := Size}, Metadata, _Config) ->
    prometheus_counter:inc(emqtt_bytes_sent_total, 
                          [maps:get(client_id, Metadata), 
                           maps:get(socket_type, Metadata)], Size);

handle_event([emqtt, socket, send_data_failed], _Measurements, Metadata, _Config) ->
    prometheus_counter:inc(emqtt_send_failures_total, 
                          [maps:get(client_id, Metadata), 
                           maps:get(reason, Metadata)]);

handle_event(_Event, _Measurements, _Metadata, _Config) ->
    ok.
```

## Performance Considerations

1. **Handler Performance**: Telemetry handlers are executed synchronously. Keep handlers lightweight to avoid impacting client performance.

2. **Error Handling**: The EMQTT telemetry integration includes error handling to prevent telemetry failures from affecting the main client functionality.

3. **Memory Usage**: Be mindful of memory usage when storing metrics, especially for long-running clients with high message volumes.

4. **Selective Attachment**: Only attach handlers for events you actually need to minimize overhead.

## Best Practices

1. **Use Appropriate Data Types**: Store metrics in efficient data structures like ETS tables or counters.

2. **Batch Operations**: For high-volume scenarios, consider batching telemetry data before processing.

3. **Monitor Handler Performance**: Use telemetry to monitor your telemetry handlers if needed.

4. **Graceful Degradation**: Ensure your application continues to work even if telemetry handlers fail.

## Integration with Monitoring Systems

The telemetry events can be easily integrated with various monitoring and observability systems:

- **Prometheus**: Use prometheus.erl for metrics collection
- **StatsD**: Send metrics to StatsD-compatible systems
- **Custom Dashboards**: Build custom monitoring dashboards
- **Alerting**: Set up alerts based on send failures or unusual traffic patterns

## Troubleshooting

If telemetry events are not being emitted:

1. Verify that the telemetry dependency is properly included
2. Check that handlers are correctly attached
3. Ensure handler functions don't crash (use try-catch blocks)
4. Verify event names match exactly

For debugging, you can use a simple handler that logs all events:

```erlang
telemetry:attach("debug-handler", [emqtt, '_', '_'], 
                fun(Event, Measurements, Metadata, _) ->
                    io:format("Event: ~p~nMeasurements: ~p~nMetadata: ~p~n", 
                             [Event, Measurements, Metadata])
                end, []).
```
