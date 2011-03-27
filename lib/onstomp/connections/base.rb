# -*- encoding: utf-8 -*-

class OnStomp::Connections::Base
  include OnStomp::Interfaces::ConnectionEvents
  attr_reader :version, :socket, :client
  attr_reader :last_transmitted_at, :last_received_at
  
  MAX_BYTES_PER_WRITE = 1024 * 8
  MAX_BYTES_PER_READ = 1024 * 4
  
  def initialize io, client
    @socket = io
    @write_mutex = Mutex.new
    @closing = false
    @write_buffer = []
    @read_buffer = []
    @client = client
  end
  
  def configure connected, con_cbs
    @version = connected.header?(:version) ? connected[:version] : '1.0'
    install_bindings_from_client con_cbs
  end
  
  def connected?
    !socket.closed?
  end
  
  def close blocking=false
    @write_mutex.synchronize { @closing = true }
    if blocking
      io_process_write until @write_buffer.empty?
      socket.close
    end
  end
  
  def connect client, *headers
    write_frame_nonblock connect_frame(*headers)
    client_con = nil
    until client_con
      io_process_write { |f| client_con ||= f }
    end
    broker_con = nil
    until broker_con
      io_process_read { |f| broker_con ||= f }
    end
    raise OnStomp::ConnectFailedError if broker_con.command != 'CONNECTED'
    vers = broker_con.header?(:version) ? broker_con[:version] : '1.0'
    raise OnStomp::UnsupportedProtocolVersionError, vers unless client.versions.include?(vers)
    [ vers, broker_con ]
  end
  
  def method_missing meth, *args, &block
    if meth.to_s =~ /^(.*)_frame$/
      raise OnStomp::UnsupportedCommandError, $1.upcase
    else
      super
    end
  end
  
  def io_process &cb
    io_process_write &cb
    io_process_read &cb
  end
  
  def write_frame_nonblock frame
    ser = serializer.frame_to_bytes frame
    push_write_buffer ser, frame
  end
  
  def push_write_buffer data, frame
    @write_mutex.synchronize {
      @write_buffer << [data, frame] unless @closing
    }
  end
  def shift_write_buffer
    @write_mutex.synchronize { @write_buffer.shift }
  end
  def unshift_write_buffer data, frame
    @write_mutex.synchronize { @write_buffer.unshift [data, frame] }
  end
  
  def io_process_write
    if @write_buffer.length > 0 && IO.select(nil, [socket], nil, 0.1)
      to_shift = @write_buffer.length / 3
      written = 0
      while written < MAX_BYTES_PER_WRITE
        data, frame = shift_write_buffer
        break unless data && alive?
        begin
          w = socket.write_nonblock(data)
          written += w
          @last_transmitted_at = Time.now
          if w < data.length
            unshift_write_buffer data[w..-1], frame
          else
            yield frame if block_given?
            client.dispatch_transmitted frame
          end
        rescue Errno::EINTR, Errno::EAGAIN, Errno::EWOULDBLOCK
          # writing will either block, or cannot otherwise be completed,
          # put data back and try again some other day
          unshift_write_buffer data, frame
          break
        rescue EOFError, SystemCallError, IOError
          socket.close
          raise
        rescue Exception
          # Give some thought to how this will get handled.
          raise
        end
      end
    end
    if @write_buffer.empty? && @closing
      socket.close
    end
  end
  
  def io_process_read
    if alive? && IO.select([socket], nil, nil, 0.1)
      begin
        data = socket.read_nonblock(MAX_BYTES_PER_READ)
        @read_buffer << data
        @last_received_at = Time.now
        serializer.bytes_to_frame(@read_buffer) do |frame|
          yield frame if block_given?
          client.dispatch_received frame
        end
      rescue Errno::EINTR, Errno::EAGAIN, Errno::EWOULDBLOCK
        # do not
      rescue EOFError
        socket.close
      rescue SystemCallError, IOError
        socket.close
        raise
      rescue Exception
        # Give some thought to how this will get handled.
        raise
      end
    end
  end
end
