# Changelog

## v0.1.0

- Initial release: adds `ws://` and `wss://` transports to ZZQ via
  `async-websocket`. Both schemes register on `require "zzq/websocket"`;
  no changes to zzq core required.
- `Stream` adapts a `Protocol::WebSocket::Connection` to an
  `IO::Stream::Generic` so zzq's MQTT parser sees the byte stream it
  expects — handles multi-packet-per-frame and split-packet-across-frames
  transparently (OASIS MQTT-over-WebSocket).
- Clean teardown via `Async::Barrier`: listener runs as a transient
  child of the socket-scoped barrier, so `broker.close` cancels the HTTP
  server without draining; per-connection teardown closes only the
  offending WS connection.
- Optional path matching (`ws://host:port/mqtt`) with 404 fallback.
