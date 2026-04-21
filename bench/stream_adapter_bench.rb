# frozen_string_literal: true

# Compares two adapter strategies that bridge Protocol::WebSocket's
# message-framed connection to the byte-stream IO that
# Protocol::MQTT::Connection wants:
#
#   A. IO::Stream::Generic subclass — the current implementation
#      (lib/zzq/websocket/stream.rb). Inherits io-stream's read buffer;
#      sysread(size, buf) just stuffs whole WS messages into +buf+.
#
#   B. Hand-rolled StringIO-backed stream — implements #read/#write/
#      #flush/#close directly, keeps a StringIO as the read buffer,
#      refills from the WS connection on demand.
#
# Runs the same workloads through Protocol::MQTT::Connection wrapped
# around each adapter: (1) many 1 KiB packets, one per WS frame,
# (2) 256 KiB packets split across four WS frames, (3) eight small
# packets bundled into one WS frame. Reports throughput (ips) and
# allocations per iteration.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "zzq/websocket"
require "protocol/mqtt"
require "benchmark/ips"
require "stringio"


# -- Adapter A: the shipped implementation ------------------------------------
ShippedStream = ZZQ::WebSocket::Stream


# -- Adapter B: StringIO-backed ----------------------------------------------
class StringIOStream
  def initialize(ws)
    @ws     = ws
    @buf    = StringIO.new("".b)
    @closed = false
  end


  def read(n)
    while remaining_in_buffer < n && !@closed
      refill
    end
    return nil if @closed && @buf.eof?
    @buf.read(n)
  end


  def write(data)
    @ws.send_binary(data)
    data.bytesize
  end


  def flush = @ws.flush


  def close
    return if @closed
    @closed = true
    @ws.close rescue nil
  end


  private def remaining_in_buffer
    @buf.size - @buf.pos
  end


  private def refill
    msg = @ws.read
    if msg.nil?
      @closed = true
      return
    end
    bytes = msg.buffer
    bytes = bytes.b if bytes.encoding != Encoding::BINARY
    tail = remaining_in_buffer.positive? ? @buf.read : "".b
    @buf = StringIO.new(tail + bytes)
  end
end


# -- Fake WS delivering a pre-computed sequence of messages ------------------
FakeMessage = Struct.new(:buffer)

class ReplayWS
  def initialize(messages)
    @messages = messages
    @pos = 0
  end

  def read
    msg = @messages[@pos]
    @pos += 1
    msg
  end

  def send_binary(_); end
  def flush; end
  def close; end
end


# -- Workload builders: produce a fresh ReplayWS per iteration ----------------
def encode_publish(topic, payload)
  Protocol::MQTT::Packet::Publish.new(
    topic: topic, payload: payload, qos: 0, retain: false,
  ).encode(version: 3)
end


def workload_one_per_frame(count:, payload_size:)
  payload = "x" * payload_size
  bytes   = encode_publish("bench/topic", payload)
  Array.new(count) { FakeMessage.new(bytes) }
end


def workload_split_packet(parts:, payload_size:)
  payload = "x" * payload_size
  bytes   = encode_publish("bench/big", payload)
  chunk   = (bytes.bytesize.to_f / parts).ceil
  (0...parts).map { |i| FakeMessage.new(bytes.byteslice(i * chunk, chunk)) }
end


def workload_multi_per_frame(packets_per_frame:, frames:)
  small = encode_publish("b/s", "x" * 32)
  bundled = small * packets_per_frame
  Array.new(frames) { FakeMessage.new(bundled) }
end


# -- Drive N MQTT packets through a stream, count allocations ----------------
def drain(stream_factory, workload, expected_packets)
  ws     = ReplayWS.new(workload)
  stream = stream_factory.call(ws)
  mqtt   = Protocol::MQTT::Connection.new(stream, version: 3)
  n = 0
  while (pkt = mqtt.read_packet)
    n += 1
  end
  raise "expected #{expected_packets} packets, got #{n}" unless n == expected_packets
end


def allocations_per_run(stream_factory, workload_builder, expected)
  # Warm up + GC compact so we're measuring steady-state.
  3.times { drain(stream_factory, workload_builder.call, expected) }
  GC.start(full_mark: true, immediate_sweep: true)

  before = GC.stat(:total_allocated_objects)
  drain(stream_factory, workload_builder.call, expected)
  GC.stat(:total_allocated_objects) - before
end


# -- Cases --------------------------------------------------------------------
cases = [
  { name: "1 KiB × 500, one packet per frame",
    workload: -> { workload_one_per_frame(count: 500, payload_size: 1024) },
    expected: 500 },
  { name: "256 KiB × 20, one packet split across 4 frames",
    workload: -> { workload_split_packet(parts: 4, payload_size: 256 * 1024) },
    expected: 1,
    repeat:   20 },   # 20 instances bundled later
  { name: "8 small packets × 50 frames",
    workload: -> { workload_multi_per_frame(packets_per_frame: 8, frames: 50) },
    expected: 400 },
]


adapters = {
  "IO::Stream::Generic (shipped)" => ->(ws) { ShippedStream.wrap(ws) },
  "StringIO-backed"               => ->(ws) { StringIOStream.new(ws) },
}


puts
puts "=== Throughput (higher is better) ==="
cases.each do |c|
  puts
  puts "-- #{c[:name]} --"
  Benchmark.ips do |x|
    x.config(time: 2, warmup: 1)
    adapters.each do |label, factory|
      x.report(label) { drain(factory, c[:workload].call, c[:expected]) }
    end
    x.compare!
  end
end


puts
puts "=== Allocations per run (fewer is better) ==="
cases.each do |c|
  puts
  puts "-- #{c[:name]} --"
  adapters.each do |label, factory|
    count = allocations_per_run(factory, c[:workload], c[:expected])
    printf "  %-32s %10d objects/iter\n", label, count
  end
end
