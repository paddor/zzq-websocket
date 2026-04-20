# zzq-websocket — MQTT-over-WebSocket transport for ZZQ

[![CI](https://github.com/paddor/zzq-websocket/actions/workflows/ci.yml/badge.svg)](https://github.com/paddor/zzq-websocket/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/zzq-websocket?color=e9573f)](https://rubygems.org/gems/zzq-websocket)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

Adds `ws://` and `wss://` transports to [zzq](https://github.com/paddor/zzq),
built on [async-websocket](https://github.com/socketry/async-websocket).
Both schemes register at require time — no zzq core changes needed.

## Install

```ruby
# Gemfile
gem "zzq"
gem "zzq-websocket"
```

```ruby
require "zzq"
require "zzq/websocket"   # registers ws:// and wss:// on ZZQ::Engine.transports
```

## Usage

```ruby
require "zzq"
require "zzq/websocket"
require "async"

# Broker — plain WebSocket
Async do
  broker = ZZQ::Broker.new
  broker.bind("ws://0.0.0.0:8080/mqtt")
end

# Broker — TLS (wss). Pass an OpenSSL::SSL::SSLContext via tls_context:.
Async do
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.cert = OpenSSL::X509::Certificate.new(File.read("server.crt"))
  ctx.key  = OpenSSL::PKey.read(File.read("server.key"))

  broker = ZZQ::Broker.new
  broker.bind("wss://0.0.0.0:8443/mqtt", tls_context: ctx)
end

# Client
Async do
  client = ZZQ::Client.new(client_id: "browser-42")
  client.connect("wss://broker.example:8443/mqtt", tls_context: ctx)
  client.publish("hello", "world")
end
```

### Path matching

If the bind URL carries a path (`ws://…/mqtt`), the listener accepts only
WebSocket upgrade requests on that exact path and returns 404 for
anything else. A bind URL without a path matches every request path.

Override explicitly with `path:`:

```ruby
broker.bind("ws://0.0.0.0:8080", path: "/mqtt")   # match /mqtt only
broker.bind("ws://0.0.0.0:8080/ignored", path: nil)   # match any path
```

### Subprotocols

The listener advertises `mqtt`, `mqttv3.1.1`, `mqttv3.1` (in that order)
so modern clients negotiate `mqtt` while legacy clients still get a
match. Client dials request `mqtt` by default. Override with
`subprotocols:` on either side.

## How it works

MQTT-over-WebSocket (OASIS) allows a single WS binary frame to carry
multiple MQTT Control Packets *and* a single MQTT packet to span
multiple WS frames. The gem's `Stream` adapter sits between the
message-framed `Protocol::WebSocket::Connection` and zzq's byte-level
MQTT parser: it feeds whole WS messages into an `IO::Stream::Generic`
read buffer, which re-assembles the byte stream transparently.

Teardown follows zzq's two-level `Async::Barrier` model — the HTTP
server task is a transient child of the socket-scoped barrier, and each
WS connection's read/write fibers live under the connection's
lifecycle barrier. `broker.close` cascades cleanly; a single
misbehaving client tears down only its own connection.

## License

ISC. See [LICENSE](LICENSE).
