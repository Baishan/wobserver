defmodule Wobserver.Util.Application do
  require Logger
  @moduledoc ~S"""
  Application listing and process hierachy.
  """

  alias Wobserver.Util.Process

  import Wobserver.Util.Helper, only: [parallel_map: 2]

  @doc ~S"""
  Lists all running applications.

  The application information is given as a tuple containing: `{name, description, version}`.
  The `name` is an atom, while both the description and version are Strings.
  """
  @spec list :: list({atom, String.t, String.t})
  def list do
    :application_controller.which_applications
    |> Enum.filter(&alive?/1)
    |> Enum.map(&structure_application/1)
  end

  @doc ~S"""
  Retreives information about the application.

  The given `app` atom is used to find the started application.

  Containing:
    - `pid`, the process id or port id.
    - `name`, the registered name or pid/port.
    - `meta`,  the meta information of a process. (See: `Wobserver.Util.Process.meta/1`.)
    - `children`, the children of the process.
  """
  @spec info(app :: atom) :: map
  def info(app) do
    app_pid =
      app
      |> :application_controller.get_master

    {:ok, pid_map} = Agent.start(fn  -> MapSet.new end)

    response = %{
      pid: app_pid,
      children: app_pid |> :application_master.get_child |> structure_pid(pid_map),
      name: name(app_pid),
      meta: Process.meta(app_pid),
    }

    Agent.stop(pid_map)
    response
  end

  # Helpers

  defp alive?({app, _, _}) do
    app
    |> :application_controller.get_master
    |> is_pid
  catch
    _, _ -> false
  end

  defp structure_application({name, description, version}) do
    %{
      name: name,
      description: to_string(description),
      version: to_string(version),
    }
  end

  defp structure_pid({pid, name}, pid_map) do
    Agent.update(pid_map, &MapSet.put(&1, pid))
    child = structure_pid({name, pid, :supervisor, []}, pid_map)

    {_, dictionary} = :erlang.process_info pid, :dictionary

    case Keyword.get(dictionary, :"$ancestors") do
      [parent] ->
        [%{
          pid: parent,
          children: [child],
          name: name(parent),
          meta: Process.meta(parent),
        }]
      _ ->
        [child]
    end
  end

  defp structure_pid({_, :undefined, _, _}, _), do: nil

  defp structure_pid({_, pid, :supervisor, _}, pid_map) do
    Agent.update(pid_map, &MapSet.put(&1, pid))
    {:links, links} = :erlang.process_info(pid, :links)

    children =
      case Enum.count(links) do
        1 ->
          []
        _ ->
          pid
          |> :supervisor.which_children
          |> Kernel.++(Enum.filter(links, fn link -> is_port(link) end))
          |> Enum.map(&structure_pid(&1, pid_map))
          |> Enum.filter(&(&1 != nil))
      end

    %{
      pid: pid,
      children: children,
      name: name(pid),
      meta: Process.meta(pid),
    }
  end

  defp structure_pid({_, pid, :worker, _}, pid_map) do
    Agent.update(pid_map, &MapSet.put(&1, pid))
    {:links, links} = :erlang.process_info(pid, :links)
    Logger.warn inspect(links)

    children =
      case Enum.count(links) do
        1 ->
          []
        _ ->
          links
          |> Enum.map(&structure_link_pid(&1, pid_map))
          |> Enum.filter(&(&1 != nil))
      end


    %{
      pid: pid,
      children: children,
      name: name(pid),
      meta: Process.meta(pid),
    }
  end


  defp structure_link_pid(port, pid_map) when is_port(port), do: structure_pid(port, pid_map)
  defp structure_pid(port, _) when is_port(port) do
    %{
      pid: port,
      children: [],
      name: port,
      meta: %{
        status: :port,
        init: "",
        current: "",
        class: :port,
      }
    }
  end

  defp structure_link_pid(pid, pid_map) when is_pid(pid) do
    Logger.warn "Child structure #{inspect name(pid)}, with map #{inspect Agent.get(pid_map, fn m -> m end)}"
    if Agent.get(pid_map, &MapSet.member?(&1, pid)) do
      Logger.warn "Found in map ignoring"
      nil
    else
    Agent.update(pid_map, &MapSet.put(&1, pid))
    {:links, links} = :erlang.process_info(pid, :links)

    children = 
      case Enum.count(links) do
        1 ->
          []
        _ ->
          Logger.warn inspect(links)
          links
          |> Enum.filter(fn p ->
                {_, dictionary} = :erlang.process_info p, :dictionary
                Logger.warn "Your dict #{inspect dictionary}"
                has_it = Keyword.get(dictionary, :"$ancestors", [])
                         |> Enum.map(fn
                           p when is_pid(p) -> p
                           p -> Elixir.Process.whereis(p)
                         end)
                |> Enum.member?(pid)

                Logger.warn "#{inspect name(p)} has #{inspect name(pid)} as ance: #{inspect has_it}"
                has_it
          end)
          |> Enum.map(&structure_link_pid(&1, pid_map))
          |> Enum.filter(&(&1 != nil))
      end

    %{
      pid: pid,
      children: children,
      name: name(pid),
      meta: Process.meta(pid),
    }
    end
  end


  defp structure_pid(_, _), do: nil

  defp name(pid) do
    case :erlang.process_info(pid, :registered_name) do
      {_, registered_name} -> to_string(registered_name)
      _ -> pid |> inspect |> String.trim_leading("#PID")
    end
  end
end
