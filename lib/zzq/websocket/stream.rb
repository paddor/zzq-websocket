# frozen_string_literal: true

require "io/stream"
require "async/notification"

module ZZQ
  module WebSocket
    # Byte-stream adapter over +Protocol::WebSocket::Connection+ (or the
    # +ClientCloseDecorator+ returned by +Async::WebSocket::Client.connect+).
    #
    # Per the MQTT-over-WebSocket OASIS spec, a single WS binary frame
    # may contain multiple MQTT Control Packets and a single MQTT packet
    # may span multiple WS frames. +IO::Stream::Generic+'s read buffer
    # already re-assembles byte streams across +#sysread+ boundaries, so
    # we just feed it whole WS messages and let
    # +Protocol::MQTT::Connection+ read framed packets out the far side
    # as if it were talking to a TCP socket.
    #
    # +#wait_for_close+ + +Async::Notification+ let the transport block
    # the WS adapter fiber until either side tears down the connection.
    class Stream < IO::Stream::Generic
      def self.wrap(ws)
        new(ws)
      end


      def initialize(ws)
        super()
        @ws                  = ws
        @closed              = false
        @closed_notification = Async::Notification.new
      end


      def closed?
        @closed
      end


      # Block the caller until #close runs (either side).
      def wait_for_close
        @closed_notification.wait unless @closed
      end


      protected


      # Read a whole WS binary message. +size+ is a hint — returning a
      # larger buffer is fine; +IO::Stream::Readable+ stores the
      # remainder and slices it on subsequent reads.
      def sysread(_size, buffer)
        message = @ws.read or return nil
        bytes   = message.buffer
        bytes   = bytes.b if bytes.encoding != Encoding::BINARY
        buffer.replace(bytes)
      rescue EOFError, IOError
        nil
      end


      # One MQTT packet per flush → one WS binary frame.
      def syswrite(data)
        @ws.send_binary(data)
        @ws.flush
        data.bytesize
      end


      def sysclose
        return if @closed
        @closed = true
        @ws.close rescue nil
        @closed_notification.signal
      end
    end
  end
end
