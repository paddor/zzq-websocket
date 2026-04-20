# frozen_string_literal: true

require "async/http/endpoint"
require "async/http/server"
require "async/http/protocol/http1"
require "async/websocket/client"
require "async/websocket/adapters/http"
require "protocol/http/response"

require "zzq"

module ZZQ
  module WebSocket
    # Shared MQTT-over-WebSocket transport for `ws://` and `wss://`.
    # Registered on both schemes at require time. The only difference
    # between the two is whether the parsed endpoint carries an
    # `ssl_context:` — supplied via the `tls_context:` kwarg on `bind`
    # and `connect`, matching the `mqtts://` transport convention.
    module Transport
      Engine.transports["ws"]  = self
      Engine.transports["wss"] = self

      # Advertised by the client by default — "mqtt" is the modern
      # MQTT v3.1.1 + v5 subprotocol name; "mqttv3.1" is the legacy
      # name still used by some clients. "mqttv3.1.1" is an older
      # convention that occasionally shows up in the wild. "mqtt" is
      # listed first so brokers pick it over the legacy aliases.
      DEFAULT_SUBPROTOCOLS = %w[mqtt mqttv3.1.1 mqttv3.1].freeze


      class << self
        def bind(endpoint, engine, tls_context: nil, subprotocols: DEFAULT_SUBPROTOCOLS, path: nil, **)
          scheme = endpoint[/\A([a-z]+):\/\//, 1]
          raise Error, "wss:// bind requires tls_context:" if scheme == "wss" && tls_context.nil?

          http_endpoint = parse_http_endpoint(endpoint, tls_context)
          bound         = http_endpoint.bound
          port          = bound.sockets.first.to_io.local_address.ip_port
          host          = http_endpoint.hostname
          host_part     = host.include?(":") ? "[#{host}]" : host
          url_path      = http_endpoint.url.path
          match_path    = path || (url_path.empty? ? nil : url_path)
          shown         = "#{scheme}://#{host_part}:#{port}#{match_path}"

          Listener.new(
            shown_endpoint: shown,
            bound:          bound,
            http_endpoint:  http_endpoint,
            subprotocols:   subprotocols,
            match_path:     match_path,
          )
        end


        def connect(endpoint, engine, tls_context: nil, subprotocols: %w[mqtt], headers: nil, **)
          http_endpoint = parse_http_endpoint(endpoint, tls_context)
          client_conn   = Async::WebSocket::Client.connect(
            http_endpoint,
            protocols: subprotocols,
            headers:   headers,
          )
          stream = Stream.wrap(client_conn)
          engine.handle_connected(stream, endpoint: endpoint)
        end


        def parse_http_endpoint(endpoint, tls_context)
          if tls_context
            Async::HTTP::Endpoint.parse(endpoint, ssl_context: tls_context)
          else
            Async::HTTP::Endpoint.parse(endpoint)
          end
        end
      end


      class Listener
        attr_reader :endpoint


        def initialize(shown_endpoint:, bound:, http_endpoint:, subprotocols:, match_path:)
          @endpoint       = shown_endpoint
          @bound          = bound
          @http_endpoint  = http_endpoint
          @subprotocols   = subprotocols
          @match_path     = match_path
          @task           = nil
        end


        # Spawned transient on the socket-scoped barrier so +Engine#close+
        # (which stops that barrier) cancels the HTTP server without
        # waiting on it to drain.
        def start_accept_loop(parent_task, &on_accepted)
          @task = parent_task.async(transient: true, annotation: "zzq ws accept #{@endpoint}") do |task|
            server = Async::HTTP::Server.new(
              ->(request) { handle_request(request, on_accepted) },
              @bound,
              protocol: Async::HTTP::Protocol::HTTP1,
              scheme:   @http_endpoint.secure? ? "https" : "http",
            )
            @bound.accept(&server.method(:accept))
            # accept fires-and-forgets per-socket accept fibers — wait
            # for them so the ensure (which closes @bound) doesn't
            # yank the socket out from under a live accept.
            task.children.each(&:wait)
          rescue Async::Stop
            # socket barrier stopped → clean cancel
          ensure
            @bound.close rescue nil
          end
        end


        def stop
          @task&.stop
          @bound.close rescue nil
        end


        private


        def handle_request(request, on_accepted)
          return not_found if @match_path && request.path != @match_path

          Async::WebSocket::Adapters::HTTP.open(request, protocols: @subprotocols) do |ws_conn|
            stream = Stream.wrap(ws_conn)
            on_accepted.call(stream)
            stream.wait_for_close
          end or not_found  # non-WS upgrade request
        end


        def not_found
          ::Protocol::HTTP::Response[404, {}, []]
        end
      end
    end
  end
end
