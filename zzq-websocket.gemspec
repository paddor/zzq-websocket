# frozen_string_literal: true

require_relative "lib/zzq/websocket/version"

Gem::Specification.new do |s|
  s.name     = "zzq-websocket"
  s.version  = ZZQ::WebSocket::VERSION
  s.authors  = ["Patrik Wenger"]
  s.email    = ["paddor@gmail.com"]
  s.summary  = "MQTT-over-WebSocket transport for ZZQ (ws:// and wss://)"
  s.description = "Adds ws:// and wss:// transports to zzq, built on " \
                  "async-websocket. Registers both schemes on require; " \
                  "no zzq core changes required."
  s.homepage = "https://github.com/paddor/zzq-websocket"
  s.license  = "ISC"

  s.required_ruby_version = ">= 4.0"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]

  s.add_dependency "zzq",             "~> 0.1"
  s.add_dependency "async",           "~> 2.38"
  s.add_dependency "async-http",      "~> 0.94"
  s.add_dependency "async-websocket", "~> 0.30"
  s.add_dependency "io-stream",       "~> 0.11"
  s.add_dependency "protocol-mqtt",   ">= 0.1.0"
end
