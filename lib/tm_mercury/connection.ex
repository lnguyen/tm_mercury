defmodule TM.Mercury.Connection do
  require Logger

  use Connection

  alias TM.Mercury.Message

  @flush_bytes String.duplicate(<<0xFF>>, 64)

  @gen2_singulation_option [
    select_disabled:         0x00,
    select_on_epc:           0x01,
    select_on_tid:           0x02,
    select_on_user_mem:      0x03,
    select_on_addressed_epc: 0x04,
    use_password:            0x05,
    inverse_select_bit:      0x08,
    flag_metadata:           0x10,
    extended_data_length:    0x20,
    secure_read_data:        0x40
  ]

  @tag_id_option [
    none:   0x00,
    rewind: 0x01
  ]

  @model_hardware_id [
    m5e:         0x00,
    m5e_compact: 0x01,
    m5e_i:       0x02,
    m4e:         0x03,
    m6e:         0x18,
    m6e_prc:     0x19,
    micro:       0x20,
    m6e_nano:    0x30,
    unknown:     0xFF,
  ]

  @defaults [
    active: false,
    timeout: 5000,
    mode: :sync,
    framing: {TM.Mercury.Message.Framing, []},
    rx_framing_timeout: 500
  ]

  def send_data(conn, data, opts \\ []) do
    opts = defaults(opts)
    timeout = opts[:timeout]

    case Connection.call(conn, {:send, data}) do
      :ok ->
        case Connection.call(conn, {:recv, timeout}) do
          :ok ->                     :ok
          {:ok, %Message{} = msg} -> {:ok, msg.data}
          {:error, error} ->         {:error, error}
        end
      {:error, error} -> {:error, error}
    end
  end

  def start_async(conn, callback \\ nil) do
    callback = callback || self()
    Connection.call(conn, {:start_async, callback})
  end

  def stop_async(conn) do
    Connection.call(conn, :stop_async)
  end

  @doc """
  Change the baud rate on the underlying UART connection.
  Note: this might not be supported by Nerves.UART yet, but it still accepts the call.
  """
  def set_speed(conn, speed) do
    Connection.call(conn, {:set_speed, speed})
  end

  def close(conn, wait_for_reopen? \\ false) do
    Connection.call(conn, {:close, wait_for_reopen?})
  end

  # Connection API

  def init({device, opts}) do
    s = %{
      device: device,
      opts: opts,
      uart: nil,
      status: :sync,
      callback: nil
    }
    {:connect, :init, s}
  end

  def connect(info, %{uart: pid, device: device, opts: opts} = s) do
    Logger.debug "Connecting to RFID reader at #{device}"

    uart_pid = if is_nil(pid) do
      {:ok, new_pid} = Nerves.UART.start_link
      new_pid
    else
      pid
    end

    new_state = %{s | uart: uart_pid}

    handle_reply = case info do
      {:reconnect, from} ->
        fn(msg) -> Connection.reply(from, msg) end
      _ ->
        fn _ -> :noop end
    end

    case Nerves.UART.open(uart_pid, device, defaults(opts)) do
      :ok ->
        handle_reply.(:ok)
        {:ok, new_state}
      {:error, _} = error->
        handle_reply.(error)
        {:backoff, 1000, new_state}
    end
  end

  def disconnect(info, %{uart: pid, device: device} = s) do
    Logger.debug "Disconnecting from RFID reader at #{inspect device}"

    _ = Nerves.UART.drain(pid)
    :ok = Nerves.UART.close(pid)

    case info do
      {{:close, true}, from} ->
        # Wait until reconnected to send a reply
        {:connect, {:reconnect, from}, s}
      {{:close, false}, from} ->
        # Send a reply immediately without waiting for reconnecting
        Connection.reply(from, :ok)
        {:connect, :reconnect, s}
      {:error, :closed} ->
        Logger.error("RFID UART connection closed")
        {:connect, :reconnect, s}
      {:error, reason} ->
        Logger.error("RFID UART error: #{inspect reason}")
        {:connect, :reconnect, s}
    end

  end

  def handle_call(_, _, %{uart: nil} = s) do
    {:reply, {:error, :closed}, s}
  end

  def handle_call(:stop_async, _, %{uart: pid} = s) do
    :ok = Nerves.UART.configure pid, active: false
    {:reply, :ok, %{s | status: :sync, callback: nil}}
  end

  def handle_call({:set_speed, speed}, _, %{uart: pid, opts: opts} = s) do
    :ok = Nerves.UART.configure pid, speed: speed
    new_state = %{s | opts: Keyword.put(opts, :speed, speed)}
    {:reply, :ok, new_state}
  end

  def handle_call({:start_async, callback}, _, %{uart: pid} = s) do
    :ok = Nerves.UART.configure pid, active: true
    {:reply, :ok, %{s | status: :async, callback: callback}}
  end

  def handle_call({:send, data}, _, %{uart: pid} = s) do
    case Nerves.UART.write(pid, data) do
      :ok ->
        {:reply, :ok, s}
      {:error, _} = error ->
        {:disconnect, error, error, s}
    end
  end

  def handle_call({:recv, timeout}, _, %{uart: pid} = s) do
    recv(Nerves.UART.read(pid, timeout), s)
  end

  def handle_call({:close, wait}, from, s) do
    {:disconnect, {{:close, wait}, from}, s}
  end

  def handle_info({:nerves_uart, _, data}, %{status: :async} = s) do
    s =
      case recv({:ok, data}, s) do
        {:reply, {:error, :no_tags_found}, s} ->
          s
        {:reply, _msg, s} ->
          send s.callback, {:tm_mercury, :message, data}
          s
        {:disconnect, error, s} ->
          send s.callback, {:tm_mercury, :error, error}
          s
      end

    {:noreply, s}
  end

  def handle_info(data, %{status: :sync} = s) do
    IO.puts "Handle Info: :sync"
    IO.inspect data
    {:noreply, s}
  end

  defp defaults(opts) do
    Keyword.merge(@defaults, opts)
  end

  defp recv({:ok, %{status: 0, length: 0}}, s) do
    {:reply, :ok, s}
  end

  defp recv({:ok, %{status: 0} = msg}, s) do
      {:reply, {:ok, Message.decode(msg)}, s}
  end

  defp recv({:ok, %{status: status}}, s) do
    reason =
      case TM.Mercury.Error.decode(status) do
        {:ok, reason} -> reason
        _ -> status
      end
    {:reply, {:error, reason}, s}
  end

  defp recv({:error, :timeout} = timeout, s) do
    {:reply, timeout, s}
  end

  defp recv({:error, _} = error, s) do
    {:disconnect, error, error, s}
  end

end
