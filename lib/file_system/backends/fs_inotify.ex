require Logger

defmodule FileSystem.Backends.FSInotify do
  @moduledoc """
  File system backend for GNU/Linux, FreeBSD, DragonFly and OpenBSD.

  This file is a fork from https://github.com/synrc/fs.

  ## Backend Options

    * `:recursive` (bool, default: true), monitor directories and their contents recursively.
    * `:events` (list, default: [:modify, :create, :delete, :attrib]),

  ## Executable File Path

  Useful when running `:file_system` with escript.

  The default listener executable file is found through finding `inotifywait` from
  `$PATH`.

  Two ways to customize the executable file path:

    * Module config with `config.exs`:

      ```elixir
      config :file_system, :fs_inotify,
        executable_file: "YOUR_EXECUTABLE_FILE_PATH"`
      ```

    * System environment variable:

      ```
      export FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE="YOUR_EXECUTABLE_FILE_PATH"`
      ```
  """

  use GenServer
  @behaviour FileSystem.Backend
  @sep_char <<1>>
  @default_events [:modify, :create, :delete, :attrib]

  def bootstrap do
    exec_file = executable_path()

    if is_nil(exec_file) do
      Logger.error(
        "`inotify-tools` is needed to run `file_system` for your system, check https://github.com/rvoicilas/inotify-tools/wiki for more information about how to install it. If it's already installed but not be found, appoint executable file with `config.exs` or `FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE` env."
      )

      {:error, :fs_inotify_bootstrap_error}
    else
      :ok
    end
  end

  def supported_systems do
    [{:unix, :linux}, {:unix, :freebsd}, {:unix, :dragonfly}, {:unix, :openbsd}]
  end

  def known_events do
    [:created, :deleted, :closed, :modified, :isdir, :attribute, :undefined]
  end

  defp executable_path do
    executable_path(:system_env) || executable_path(:config) || executable_path(:system_path)
  end

  defp executable_path(:config) do
    Application.get_env(:file_system, :fs_inotify)[:executable_file]
  end

  defp executable_path(:system_env) do
    System.get_env("FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE")
  end

  defp executable_path(:system_path) do
    System.find_executable("inotifywait")
  end

  def parse_options(options) do
    case Keyword.pop(options, :dirs) do
      {nil, _} ->
        Logger.error("required argument `dirs` is missing")
        {:error, :missing_dirs_argument}

      {dirs, rest} ->
        format = ["%w", "%e", "%f"] |> Enum.join(@sep_char) |> to_charlist

        {events, rest} = Keyword.pop(rest, :events, @default_events)

        convert_events(events)
        ++
        [
          ~c"--format",
          format,
          ~c"--quiet",
          ~c"-m"
        ]
        ++
        parse_options(rest, [])
        ++
        (dirs |> Enum.map(&Path.absname/1) |> Enum.map(&to_charlist/1))

    end
  end

  # defp parse_options([], result), do: {:ok, result}
  defp parse_options([], result), do: result

  defp parse_options([{:recursive, false} | t], result) do
    parse_options(t, result)
  end

  defp parse_options([{:recursive, true} | t], result) do
    parse_options(t, result ++ [~c"-r"])
  end

  defp parse_options([{:recursive, value} | t], result) do
    Logger.error("unknown value `#{inspect(value)}` for recursive, ignore")
    parse_options(t, result)
  end

  defp parse_options([{:exclude_pattern, pattern} | t], result) do
    parse_options(t, result ++ [~c"--exclude", String.to_charlist(pattern)])
  end

  defp parse_options([h | t], result) do
    Logger.error("unknown option `#{inspect(h)}`, ignore")
    parse_options(t, result)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init(args) do
    {worker_pid, rest} = Keyword.pop(args, :worker_pid)

    case parse_options(rest) do
      port_args when is_list(port_args) ->
        bash_args = [
          ~c"-c",
          ~c"#{executable_path()} \"$0\" \"$@\" & PID=$!; read a; kill -KILL $PID"
        ]

        all_args =
          case :os.type() do
            {:unix, :freebsd} ->
              bash_args ++ [~c"--"] ++ port_args

            {:unix, :dragonfly} ->
              bash_args ++ [~c"--"] ++ port_args

            _ ->
              bash_args ++ port_args
          end

        port =
          Port.open(
            {:spawn_executable, ~c"/bin/sh"},
            [
              :binary,
              :stream,
              :exit_status,
              {:line, 16384},
              {:args, all_args}
            ]
          )

        Process.link(port)
        Process.flag(:trap_exit, true)

        {:ok, %{port: port, worker_pid: worker_pid}}

      {:error, _} ->
        :ignore
    end
  end

  @doc false
  def handle_call(:status, _, state) do
    {:reply, state, state}
  end

  @doc false
  def handle_call(:stop, _, state) do
    {:reply, Port.close(state.port), state}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {file_path, events} = line |> parse_line
    send(state.worker_pid, {:backend_file_event, self(), {file_path, events}})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) do
    send(state.worker_pid, {:backend_file_event, self(), :stop})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    send(state.worker_pid, {:backend_file_event, self(), :stop})
    {:stop, :normal, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def parse_line(line) do
    {path, flags} =
      case String.split(line, @sep_char, trim: true) do
        [dir, flags, file] -> {Path.join(dir, file), flags}
        [path, flags] -> {path, flags}
      end

    {path, flags |> String.split(",") |> Enum.map(&convert_flag/1)}
  end

  defp convert_flag("CREATE"), do: :created
  defp convert_flag("MOVED_TO"), do: :moved_to
  defp convert_flag("DELETE"), do: :deleted
  defp convert_flag("MOVED_FROM"), do: :moved_from
  defp convert_flag("ISDIR"), do: :isdir
  defp convert_flag("MODIFY"), do: :modified
  defp convert_flag("CLOSE_WRITE"), do: :modified
  defp convert_flag("CLOSE"), do: :closed
  defp convert_flag("ATTRIB"), do: :attribute
  defp convert_flag(_), do: :undefined

  defp convert_events([]), do: []
  defp convert_events([event | events]) do
    convert_event(event) ++ convert_events(events)
  end

  defp convert_event(:modify), do: [~c"-e", ~c"modify", ~c"-e", ~c"close_write"]
  defp convert_event(:create), do: [~c"-e", ~c"create", ~c"-e", ~c"moved_from"]
  defp convert_event(:delete), do: [~c"-e", ~c"delete", ~c"-e", ~c"moved_to"]
  defp convert_event(:attrib), do: [~c"-e", ~c"attrib"]
  defp convert_event(_), do: []
end
