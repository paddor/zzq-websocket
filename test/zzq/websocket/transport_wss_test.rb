# frozen_string_literal: true

require "test_helper"
require "localhost"

describe "wss:// transport" do
  AUTHORITY  = Localhost::Authority.fetch
  SERVER_CTX = AUTHORITY.server_context
  CLIENT_CTX = AUTHORITY.client_context


  it "round-trips publish/subscribe over wss" do
    Async do
      broker = ZZQ::Broker.new
      broker.bind("wss://localhost:0", tls_context: SERVER_CTX)

      sub = ZZQ::Client.new(client_id: "wss-sub", keep_alive: 0)
      sub.connect(broker.last_endpoint, tls_context: CLIENT_CTX)
      queue = sub.subscribe("wss/+")

      pub = ZZQ::Client.new(client_id: "wss-pub", keep_alive: 0)
      pub.connect(broker.last_endpoint, tls_context: CLIENT_CTX)
      pub.publish("wss/world", "encrypted")

      msg = Async::Task.current.with_timeout(2) { queue.pop }
      assert_equal "encrypted".b, msg.payload

      pub.close; sub.close; broker.close
    end
  end


  it "requires tls_context: on bind" do
    Async do
      broker = ZZQ::Broker.new
      assert_raises(ZZQ::Error) { broker.bind("wss://localhost:0") }
      broker.close
    end
  end
end
