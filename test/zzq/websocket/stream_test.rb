# frozen_string_literal: true

require "test_helper"

# Fake Protocol::WebSocket::Connection-shaped object driving the
# Stream shim. The shim only uses #read, #send_binary, #flush, #close.
class FakeWS
  attr_reader :outbound


  def initialize(messages)
    @messages = messages.dup
    @outbound = []
    @closed   = false
  end


  def read
    @messages.shift  # nil when exhausted → EOF
  end


  def send_binary(bytes)
    @outbound << bytes.b
  end


  def flush; end


  def close
    @closed = true
  end


  def closed? = @closed
end


# Minimal message shape: Protocol::WebSocket::Message exposes #buffer.
FakeMessage = Struct.new(:buffer)


describe ZZQ::WebSocket::Stream do
  def msg(bytes) = FakeMessage.new(bytes.b)


  it "reads a whole WS message as a byte stream" do
    ws     = FakeWS.new([msg("hello")])
    stream = ZZQ::WebSocket::Stream.wrap(ws)
    assert_equal "hello".b, stream.read_exactly(5)
  end


  it "delivers multiple MQTT packets carried in one WS frame" do
    ws     = FakeWS.new([msg("AB" + "CDE")])
    stream = ZZQ::WebSocket::Stream.wrap(ws)
    assert_equal "AB".b,  stream.read_exactly(2)
    assert_equal "CDE".b, stream.read_exactly(3)
  end


  it "reassembles a single MQTT packet split across multiple WS frames" do
    ws     = FakeWS.new([msg("ABC"), msg("DEFG")])
    stream = ZZQ::WebSocket::Stream.wrap(ws)
    assert_equal "ABCDEFG".b, stream.read_exactly(7)
  end


  it "signals clean EOF when no more WS messages arrive" do
    ws     = FakeWS.new([])
    stream = ZZQ::WebSocket::Stream.wrap(ws)
    assert_raises(EOFError) { stream.read_exactly(1) }
  end


  it "writes each flushed buffer as one WS binary frame" do
    ws     = FakeWS.new([])
    stream = ZZQ::WebSocket::Stream.wrap(ws)
    stream.write("first"); stream.flush
    stream.write("second"); stream.flush
    assert_equal ["first".b, "second".b], ws.outbound
  end


  it "#close is idempotent and signals #wait_for_close" do
    ws     = FakeWS.new([])
    stream = ZZQ::WebSocket::Stream.wrap(ws)

    Async do |task|
      waiter = task.async { stream.wait_for_close }
      stream.close
      stream.close  # idempotent
      task.with_timeout(1) { waiter.wait }
    end

    assert ws.closed?
  end
end
