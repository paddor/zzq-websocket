# frozen_string_literal: true

require "test_helper"
require "async/websocket/client"
require "async/http/endpoint"
require "protocol/mqtt"

# Integration tests: drive a ZZQ::Broker with a bare Async::WebSocket::Client
# — no ZZQ::Client on the dial side. Proves the broker speaks OASIS-compliant
# MQTT-over-WebSocket to any standards-only peer (Paho.js, MQTT.js, HiveMQ
# dashboards), not just to itself.
describe "Async::WebSocket::Client ↔ ZZQ::Broker" do
  def ws_endpoint(broker)
    Async::HTTP::Endpoint.parse(broker.last_endpoint)
  end


  def read_packet(ws, version: 3)
    msg = ws.read or return nil
    Protocol::MQTT::Packet.decode(msg.buffer, version: version).first
  end


  it "drives CONNECT/SUBSCRIBE/PUBLISH against the broker" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind "ws://127.0.0.1:0"

      Async::WebSocket::Client.connect(ws_endpoint(broker), protocols: %w[mqtt]) do |ws|
        ws.send_binary Protocol::MQTT::Packet::Connect.new(
          client_id: "bare-ws", clean_start: true, keep_alive: 0,
        ).encode(version: 3)
        ws.flush
        connack = read_packet(ws)
        assert_kind_of Protocol::MQTT::Packet::Connack, connack
        assert_equal 0, connack.reason_code

        ws.send_binary Protocol::MQTT::Packet::Subscribe.new(
          packet_id: 1, filters: [{ filter: "bare/#", qos: 0 }],
        ).encode(version: 3)
        ws.flush
        suback = read_packet(ws)
        assert_kind_of Protocol::MQTT::Packet::Suback, suback
        assert_equal 1, suback.packet_id

        pub = ZZQ::Client.new(client_id: "zzq-pub", keep_alive: 0)
        pub.connect broker.last_endpoint
        pub.publish "bare/hello", "from-zzq"

        publish = read_packet(ws)
        assert_kind_of Protocol::MQTT::Packet::Publish, publish
        assert_equal "bare/hello", publish.topic
        assert_equal "from-zzq".b, publish.payload

        ws.send_binary Protocol::MQTT::Packet::Disconnect.new.encode(version: 3)
        ws.flush
        pub.close
      end

      broker.close
    end
  end


  it "negotiates an MQTT subprotocol over the wire" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind "ws://127.0.0.1:0"

      Async::WebSocket::Client.connect(ws_endpoint(broker), protocols: %w[mqtt]) do |ws|
        assert_equal "mqtt", ws.protocol
      end

      # Legacy clients that only know "mqttv3.1" still negotiate — our
      # listener advertises both so Paho-era browser clients keep working.
      Async::WebSocket::Client.connect(ws_endpoint(broker), protocols: %w[mqttv3.1]) do |ws|
        assert_equal "mqttv3.1", ws.protocol
      end

      broker.close
    end
  end


  it "accepts multiple MQTT packets bundled into one WS binary frame" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind "ws://127.0.0.1:0"

      Async::WebSocket::Client.connect(ws_endpoint(broker), protocols: %w[mqtt]) do |ws|
        bundled = Protocol::MQTT::Packet::Connect.new(
          client_id: "bundle", clean_start: true, keep_alive: 0,
        ).encode(version: 3) + Protocol::MQTT::Packet::Subscribe.new(
          packet_id: 42, filters: [{ filter: "b/#", qos: 0 }],
        ).encode(version: 3)

        ws.send_binary bundled
        ws.flush

        assert_kind_of Protocol::MQTT::Packet::Connack, read_packet(ws)
        suback = read_packet(ws)
        assert_kind_of Protocol::MQTT::Packet::Suback, suback
        assert_equal 42, suback.packet_id
      end

      broker.close
    end
  end
end
