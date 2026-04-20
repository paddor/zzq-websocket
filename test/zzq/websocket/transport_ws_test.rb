# frozen_string_literal: true

require "test_helper"

describe "ws:// transport" do
  it "round-trips publish/subscribe over ws" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind("ws://127.0.0.1:0")

      sub = ZZQ::Client.new(client_id: "ws-sub", keep_alive: 0)
      sub.connect(broker.last_endpoint)
      queue = sub.subscribe("ws/+")

      pub = ZZQ::Client.new(client_id: "ws-pub", keep_alive: 0)
      pub.connect(broker.last_endpoint)
      pub.publish("ws/hello", "hi")

      msg = Async::Task.current.with_timeout(2) { queue.pop }
      assert_equal "hi".b, msg.payload

      pub.close; sub.close; broker.close
    end
  end


  it "carries packets larger than a single TCP read" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind("ws://127.0.0.1:0")

      sub = ZZQ::Client.new(client_id: "big-sub", keep_alive: 0)
      sub.connect(broker.last_endpoint)
      queue = sub.subscribe("big/#")

      pub = ZZQ::Client.new(client_id: "big-pub", keep_alive: 0)
      pub.connect(broker.last_endpoint)

      payload = "x" * (128 * 1024)
      pub.publish("big/one", payload)

      msg = Async::Task.current.with_timeout(2) { queue.pop }
      assert_equal payload.bytesize, msg.payload.bytesize
      assert_equal payload.b, msg.payload

      pub.close; sub.close; broker.close
    end
  end


  it "rejects WS upgrades on a path other than the configured one" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind("ws://127.0.0.1:0/mqtt")
      actual = broker.last_endpoint

      bad = actual.sub("/mqtt", "/wrong")
      client = ZZQ::Client.new(client_id: "path-bad", keep_alive: 0)
      assert_raises(StandardError) do
        Async::Task.current.with_timeout(1) { client.connect(bad) }
      end

      broker.close
    end
  end


  it "isolates per-connection teardown" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind("ws://127.0.0.1:0")

      sub = ZZQ::Client.new(client_id: "iso-sub", keep_alive: 0)
      sub.connect(broker.last_endpoint)
      queue = sub.subscribe("iso/+")

      pub1 = ZZQ::Client.new(client_id: "iso-pub1", keep_alive: 0)
      pub1.connect(broker.last_endpoint)
      pub2 = ZZQ::Client.new(client_id: "iso-pub2", keep_alive: 0)
      pub2.connect(broker.last_endpoint)

      pub1.close  # tears down only pub1

      pub2.publish("iso/after", "still-here")
      msg = Async::Task.current.with_timeout(2) { queue.pop }
      assert_equal "still-here".b, msg.payload

      pub2.close; sub.close; broker.close
    end
  end
end
