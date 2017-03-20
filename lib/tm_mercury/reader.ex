defmodule TM.Mercury.Reader do
  use GenServer
  require Logger

  @default_opts power_mode: :full, region: :na, antennas: 1,
                tag_protocol: :gen2, read_timeout: 500
  @ts_opt_keys [:device, :speed, :timeout, :framing]

  alias __MODULE__
  alias TM.Mercury.{Transport, ReadPlan}
  alias TM.Mercury.Protocol.Command

  defstruct [:model, :power_mode, :region, :tag_protocol, :antennas]

  # Client API

  @doc """
  Disconnect the reader.  The connection will be restarted.
  """
  @spec reconnect(pid) :: :ok | {:error, term}
  def reconnect(pid) do
    GenServer.call(pid, :reconnect)
  end

  @doc """
  Execute the reader's bootloader.
  """
  @spec boot_bootloader(pid) :: :ok | {:error, term}
  def boot_bootloader(pid) do
    GenServer.call(pid, :boot_bootloader)
  end

  @doc """
  Execute the reader's firmware from the bootloader.
  """
  @spec boot_firmware(pid) :: :ok | {:error, term}
  def boot_firmware(pid) do
    GenServer.call(pid, :boot_firmware)
  end

  @doc """
  Reboot the reader.
  """
  @spec reboot(pid) :: :ok | {:error, term}
  def reboot(pid) do
    GenServer.call(pid, :reboot)
  end

  @doc """
  Return hardware, firmware, and bootloader version details.
  """
  @spec get_version(pid) :: {:ok, map}
  def get_version(pid) do
    GenServer.call(pid, :version)
  end

  @doc """
  Return the identity of the program currently running on the device.
  """
  @spec get_current_program(pid) ::
    {:ok, :bootloader} | {:ok, :application} | {:error, term}
  def get_current_program(pid) do
    GenServer.call(pid, :get_current_program)
  end

  @doc """
  Set the reader's serial baud rate.
  The host's baud rate must be changed separately.
  """
  @spec set_baud_rate(pid, pos_integer) :: :ok | {:error, term}
  def set_baud_rate(pid, rate) do
    GenServer.call(pid, [:set_baud_rate, rate])
  end

  @doc """
  TODO: Docs
  """
  @spec get_tag_id_buffer(pid, list) :: {:ok, term} | {:error, term}
  def get_tag_id_buffer(pid, metadata_flags) do
    GenServer.call(pid, [:get_tag_id_buffer, metadata_flags])
  end

  @doc """
  Clear the tag buffer.
  """
  @spec clear_tag_id_buffer(pid) :: :ok | {:error, term}
  def clear_tag_id_buffer(pid) do
    GenServer.call(pid, :clear_tag_id_buffer)
  end

  @doc """
  Set the RF regulatory environment that the reader will operate within.
  """
  def set_region(pid, region) do
    GenServer.call(pid, [:set_region, region])
  end

  @doc """
  Return the RF regulatory environment that the reader will operate within.
  """
  def get_region(pid) do
    GenServer.call(pid, :get_region)
  end

  @doc """
  Return the power-consumption mode of the reader as a whole
  """
  def set_power_mode(pid, mode) do
    GenServer.call(pid, [:set_power_mode, mode])
  end

  @doc """
  TODO
  Set the power-consumption mode of the reader as a whole
  """
  def get_power_mode(pid) do
    GenServer.call(pid, :get_power_mode)
  end

  @doc """
  Set the tag protocol used by the reader
  """
  def set_tag_protocol(pid, protocol) do
    GenServer.call(pid, [:set_tag_protocol, protocol])
  end

  @doc """
  Return the tag protocol used by the reader
  """
  def get_tag_protocol(pid) do
    GenServer.call(pid, :get_tag_protocol)
  end

  @doc """
  Return the antenna port configuration used by the reader
  """
  def get_antenna_port(pid) do
    GenServer.call(pid, :get_antenna_port)
  end

  @doc """
  Set the antenna port configuration used by the reader
  """
  def set_antenna_port(pid, ports) do
    GenServer.call(pid, [:set_antenna_port, ports])
  end

  @doc """
  TODO
  """
  def get_reader_stats(pid, option, flags) do
    # TODO: Implement decoding.
    # See: https://www.pivotaltracker.com/story/show/141738711
    GenServer.call(pid, [:get_reader_stats, option, flags])
  end

  @doc """
  TODO
  """
  def reset_reader_stats(pid, flags) do
    GenServer.call(pid, [:get_reader_stats, :reset, flags])
  end

  @doc """
  TODO
  """
  @spec get_param(pid, atom) :: {:ok, term} | {:error, term}
  def get_param(pid, key) do
    GenServer.call(pid, [:get_reader_optional_params, key])
  end

  @doc """
  TODO
  """
  @spec set_param(pid, atom, any) :: {:ok, term} | {:error, term}
  def set_param(pid, key, value) do
    GenServer.call(pid, [:set_reader_optional_params, key, value])
  end

  @doc """
  Read tags synchronously using the current reader configuration
  """
  @spec read_sync(pid) :: {:ok, term} | {:error, term}
  def read_sync(pid) do
    GenServer.call(pid, :read_sync)
  end

  @doc """
  Read tags synchronously using a custom read plan
  """
  @spec read_sync(pid, ReadPlan.t) :: {:ok, term} | {:error, term}
  def read_sync(pid, %ReadPlan{} = rp) do
    GenServer.call(pid, [:read_sync, rp])
  end

  @doc """
  Start reading tags asynchronously using the current reader configuration
  Tags will be sent to the process provided as the callback until `stop_read_async` is called.
  """
  @spec read_async_start(pid :: pid, callback :: pid) ::
    {:ok, term} | {:error, term}
  def read_async_start(pid, callback) do
    GenServer.call(pid, [:read_async_start, callback])
  end

  @doc """
  Start reading tags asynchronously using a custom read plan
  Tags will be sent to the process provided as the callback until `stop_read_async` is called.
  """
  @spec read_async_start(pid :: pid, rp :: ReadPlan.t, callback :: pid) ::
    {:ok, term} | {:error, term}
  def read_async_start(pid, %ReadPlan{} = rp, callback) do
    GenServer.call(pid, [:read_async_start, rp, callback])
  end

  @doc """
  Stop reading tags asynchronously
  """
  def read_async_stop(pid) do
    GenServer.call(pid, :read_async_stop)
  end

  @doc """
  Change the read timeout used for synchronous tag reading.
  """
  def set_read_timeout(pid, timeout) do
    GenServer.call(pid, [:set_read_timeout, timeout])
  end

  # Server API

  @doc """
  Start a process and open a connection
  with the reader over UART connected via TTL / USB

  Keyword List Parameters
  * `device` - The device file for the reader serial connection (required)
  * `speed` - The port speed, e.g.: `speed: 115200` (default)
  * `region` - The regulatory RF environment used by the reader
    * `:none` - Unspecified region (default)
    * `:na` - North America
    * `:eu` - European Union
    * `:kr` - Korea
    * `:in` - India
    * `:jp` - Japan
    * `:prc` - People's Republic of China
    * `:eu2` - European Union 2
    * `:eu3` - European Union 3
    * `:kr2` - Korea 2
    * `:prc2` - People's Republic of China (840 MHz)
    * `:au` - Australia
    * `:nz` - New Zealand (Experimental)
    * `:na2` - Reduced FCC region
    * `:na3` - 5 MHz FCC band
    * `:open` - Open
  * `power_mode` - The power-consumption mode of the reader as a whole
    * `:full` (default)
    * `:min_save`
    * `:med_save`
    * `:max_save`
    * `:sleep`
  * `antennas` - The antenna port configuration.  default: 1
  * `tag_protocol` - The tag protocol used by the reader. default: :gen2
  * `read_timeout` - The duration used by `read_sync` when reading tags. default: 500
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(opts) do
    device = opts[:device]
    name = Path.basename(device) |> String.to_atom
    GenServer.start_link(__MODULE__, {device, opts}, name: name)
  end

  def init({device, opts}) do
    Logger.debug "Starting RFID reader process for #{device} with pid #{inspect self()}"

    opts = Keyword.merge(@default_opts, opts)
    ts_opts = Keyword.take(opts, @ts_opt_keys)

    case Connection.start_link(Transport, {self(), ts_opts}) do
      {:ok, ts} ->
        new_reader = struct(%Reader{}, opts)

        state =
          Map.new(opts)
          |> Map.take([:speed, :read_timeout])
          |> Map.put(:init, new_reader)
          |> Map.put(:reader, new_reader)
          |> Map.put(:transport, ts)

        {:ok, state}
      error ->
        Logger.warn "Failed to open connection to RFID device at #{device}: #{inspect error}"
        error
    end
  end

  def handle_info(:connected, state) do
    case initialize_reader(state) do
      {:ok, rdr} -> {:noreply, Map.put(state, :reader, rdr)}
      _ -> {:noreply, state}
    end
  end

  def handle_call(:reboot, _from, state) do
    with :ok <- reboot_reader(state),
      do: {:reply, :ok, state}
  end

  def handle_call(:reconnect, _from, %{transport: ts} = s) do
    resp = Transport.reopen(ts)
    {:reply, resp, s}
  end

  def handle_call(:boot_bootloader, _from, %{transport: ts, reader: rdr} = s) do
    resp = boot_bootloader(ts, rdr)
    {:reply, resp, s}
  end

  def handle_call([:set_region|[region]] = cmd, _from, %{transport: ts, reader: rdr} = s) do
    exec_command_bind_reader_state(ts, rdr, cmd, s, fn r ->
      %{r | region: region}
    end)
  end

  def handle_call([:set_power_mode|[mode]] = cmd, _from, %{transport: ts, reader: rdr} = s) do
    # Handle set_power_mode separately so we can track the state change.
    exec_command_bind_reader_state(ts, rdr, cmd, s, fn r ->
      %{r | power_mode: mode}
    end)
  end

  def handle_call([:set_tag_protocol|[protocol]] = cmd, _from, %{transport: ts, reader: rdr} = s) do
    # Handle set_tag_protocol separately so we can track the state change.
    exec_command_bind_reader_state(ts, rdr, cmd, s, fn r ->
      %{r | tag_protocol: protocol}
    end)
  end

  def handle_call([:set_antenna_port|[ports]] = cmd, _from, %{transport: ts, reader: rdr} = s) do
    # Handle set_antenna_port seperately so we can track the state change.
    exec_command_bind_reader_state(ts, rdr, cmd, s, fn r ->
      %{r | antennas: ports}
    end)
  end


  def handle_call([:read_sync, %ReadPlan{} = rp], _from, %{transport: ts, reader: rdr} = s) do
    case read_sync(ts, rdr, rp, s.read_timeout) do
      {:ok, tags, new_reader} ->
        {:reply, {:ok, tags}, %{s | reader: new_reader}}
      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(:read_sync, _from, %{transport: ts, reader: rdr} = s) do
    # Create and use a read plan based on the current reader settings
    rp = %ReadPlan{tag_protocol: rdr.tag_protocol, antennas: rdr.antennas}
    case read_sync(ts, rdr, rp, s.read_timeout) do
      {:ok, tags, _} ->
        {:reply, {:ok, tags}, s}
      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call([:read_async_start, %ReadPlan{} = rp, cb], _from, %{transport: ts, reader: rdr} = s) do
    # Pseudo-async until we implement true continuous reading
    case read_async_start(ts, rdr, rp, s.read_timeout, cb) do
      {:ok, async_pid, new_reader} ->
        new_state = Map.put(s, :reader, new_reader) |> Map.put(:async_pid, async_pid)
        {:reply, :ok, new_state}
      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call([:read_async_start, cb], _from, %{transport: ts, reader: rdr} = s) do
    # Create and use a read plan based on the current reader settings
    rp = %ReadPlan{tag_protocol: rdr.tag_protocol, antennas: rdr.antennas}
    case read_async_start(ts, rdr, rp, s.read_timeout, cb) do
      {:ok, async_pid, new_reader} ->
        new_state = Map.put(s, :reader, new_reader) |> Map.put(:async_pid, async_pid)
        {:reply, :ok, new_state}
      {:error, _reason} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(:read_async_stop, _from, s) do
    case Map.fetch(s, :async_pid) do
      {:ok, task_pid} when not is_nil(task_pid) ->
        stop = Task.async(fn ->
          send(task_pid, {:stop, self()})
          receive do
            {:ok, :stopped} -> :ok
          after 1000 ->
            Process.unlink(task_pid)
            Process.exit(task_pid, :kill)
            {:error, :timeout}
          end
        end) |> Task.await
        {:reply, stop, %{s | async_pid: nil}}
      _ ->
        {:reply, {:error, :not_started}, s}
    end
  end

  def handle_call([:set_read_timeout, timeout], _from, state) do
    {:reply, :ok, %{state | read_timeout: timeout}}
  end

  @doc """
  Catch-all handlers for op commands that don't require any state binding or special handling
  """
  def handle_call(cmd, _from, %{transport: ts, reader: rdr} = s) when is_list(cmd) do
    resp = execute(ts, rdr, cmd)
    {:reply, resp, s}
  end
  def handle_call(cmd, _from, %{transport: ts, reader: rdr} = s) when is_atom(cmd) do
    resp = execute(ts, rdr, [cmd])
    {:reply, resp, s}
  end

  defp initialize_reader(%{transport: ts, init: rdr}) do
    with {:ok, version} <- execute(ts, rdr, :version),
         # Pick up the model first for any downstream encoding/decoding that needs it
         reader = Map.put(rdr, :model, version.model),
         :ok <- execute(ts, reader, [:set_region, reader.region]),
         :ok <- execute(ts, reader, [:set_power_mode, reader.power_mode]),
         :ok <- execute(ts, reader, [:set_tag_protocol, reader.tag_protocol]),
         :ok <- execute(ts, reader, [:set_antenna_port, reader.antennas]),
      do: {:ok, reader}
  end

  defp reboot_reader(%{transport: ts, reader: rdr, speed: speed}) do
    # This should silently fail with {:error, :invalid_opcode} if we're not actually in async mode.
    _ = read_async_stop(ts)

    with :ok <- change_baud_rate(ts, rdr, 9600),
         :ok <- boot_bootloader(ts, rdr),
         :ok <- Transport.reopen(ts),
         # Reconnected at this point
         {:ok, :bootloader} <- execute(ts, rdr, :get_current_program),
         {:ok, _version} <- execute(ts, rdr, :boot_firmware),
         {:ok, :application} <- execute(ts, rdr, :get_current_program),
         :ok <- change_baud_rate(ts, rdr, speed),
      do: :ok
  end

  defp change_baud_rate(ts, reader, rate) do
    # Change the baud rate on both the reader and the host.
    with :ok <- execute(ts, reader, [:set_baud_rate, rate]),
         :ok <- Transport.set_speed(ts, rate),
      do: :ok
  end

  defp boot_bootloader(ts, reader) do
    case execute(ts, reader, :boot_bootloader) do
      :ok ->
        # Give the reader time to gather its wits
        Process.sleep(200)
        :ok
      {:error, :invalid_opcode} ->
        # Already in bootloader, ignore
        :ok
    end
  end

  defp read_sync(ts, rdr, %ReadPlan{} = rp, timeout) do
    # Validate the read plan
    case ReadPlan.validate(rp) do
      [errors: []] ->
        {:ok, new_reader} = prepare_read(ts, rdr, rp)
        {:ok, tags} = execute_read_sync(ts, new_reader, timeout)
        # Return the reader in case any settings changed during prepare
        {:ok, tags, new_reader}
      [errors: errors] ->
        {:error, errors}
    end
  end

  defp read_async_start(ts, rdr, %ReadPlan{} = rp, timeout, callback) do
    # Validate the read plan
    case ReadPlan.validate(rp) do
      [errors: []] ->
        {:ok, new_reader} = prepare_read(ts, rdr, rp)
        {:ok, task_pid} = Task.start_link(fn ->
          pseudo_read_async_loop(ts, new_reader, callback, timeout)
        end)
        # Return the reader in case any settings changed during prepare
        {:ok, task_pid, new_reader}
      [errors: errors] ->
        {:error, errors}
    end
  end

  defp pseudo_read_async_loop(ts, rdr, cb, timeout) do
    receive do
      {:stop, from} ->
        send(from, {:ok, :stopped})
        {:shutdown, :stopped}
      after 100 ->
        case execute_read_sync(ts, rdr, timeout) do
          {:error, :no_tags_found} -> :noop
          {:ok, tags} ->
            send(cb, {:tm_mercury, :tags, tags})
            :ok = execute(ts, rdr, :clear_tag_id_buffer)
        end
        pseudo_read_async_loop(ts, rdr, cb, timeout)
    end
  end

  defp prepare_read(ts, rdr, %ReadPlan{} = rp) do
    # First verify the protocol
    rdr = if rp.tag_protocol != rdr.tag_protocol do
      Logger.debug "Read plan's tag protocol differs from reader, reconfiguring reader"
      :ok = execute(ts, rdr, [:set_tag_protocol, rp.tag_protocol])
      %{rdr | tag_protocol: rp.tag_protocol}
    else
      rdr
    end

    # Next check the antennas
    rdr = if rp.antennas != rdr.antennas do
      Logger.debug "Read plan's antenna settings differ from reader, reconfiguring reader"
      :ok = execute(ts, rdr, [:set_antenna_port, rp.antennas])
      %{rdr | antennas: rp.antennas}
    else
      rdr
    end

    # Clear the tag buffer
    :ok = execute(ts, rdr, :clear_tag_id_buffer)

    # Reset statistics
    {:ok, _} = execute(ts, rdr, [:get_reader_stats, :reset, :rf_on_time])

    {:ok, rdr}
  end

  defp execute_read_sync(ts, rdr, timeout) do
    search_flags = [:configured_list, :large_tag_population_support]
    op = [:read_tag_id_multiple, search_flags, timeout]

    {:ok, cmd} = Command.build(rdr, op)

    case Transport.send_data(ts, cmd) do
      {:ok, _count} ->
        flags = TM.Mercury.Tag.MetadataFlag.all
        execute(ts, rdr, [:get_tag_id_buffer, flags])
      {:error, _reason} = err ->
        err
    end
  end

  ## Helpers

  defp exec_command_bind_reader_state(ts, rdr, cmd, state, reader_state_func) do
    case execute(ts, rdr, cmd) do
      :ok ->
        new_reader = reader_state_func.(rdr)
        {:reply, :ok, %{state | reader: new_reader}}
      error ->
        {:reply, error, state}
    end
  end

  defp execute(ts, %Reader{} = rdr, cmd) when is_atom(cmd),
    do: execute(ts, rdr, [cmd])
  defp execute(ts, %Reader{} = rdr, [_key|_args] = cmd) do
    Command.build(rdr, cmd)
    |> send_command(ts)
  end

  defp send_command(:error, _ts),
    do: {:error, :command_error}
  defp send_command({:error, _reason} = error, _ts),
    do: error
  defp send_command({:ok, cmd}, ts),
    do: send_command(cmd, ts)
  defp send_command(cmd, ts),
    do: Transport.send_data(ts, cmd)

end
