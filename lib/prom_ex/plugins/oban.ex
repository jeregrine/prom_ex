if Code.ensure_loaded?(Oban) do
  defmodule PromEx.Plugins.Oban do
    @moduledoc """
    This plugin captures metrics emitted by Oban. Specifically, it captures metrics from job events, producer events,
    and also from internal polling jobs to monitor queue sizes

    This plugin supports the following options:
    - `oban_supervisors`: This is an OPTIONAL option and it allows you to specify what Oban instances should have their events
      tracked. By default the only Oban instance will have its events tracked is the defualt `Oban` instance. As a result, by
      default this option has a value of `[Oban]`. If you would like to track other named Oban instances, or perhaps your default
      and only Oban instance has a different name, you can pass in your own list of Oban instances (e.g. `[Oban, Oban.PrivateJobs]`).

    - `poll_rate`: This is option is OPTIONAL and is the rate at which poll metrics are refreshed (default is 5 seconds).

    This plugin exposes the following metric groups:
    - `:oban_init_event_metrics`
    - `:oban_job_event_metrics`
    - `:oban_producer_event_metrics`
    - `:oban_circuit_event_metrics`
    - `:oban_queue_poll_metrics`

    To use plugin in your application, add the following to your PromEx module:
    ```
    defmodule WebApp.PromEx do
      use PromEx, otp_app: :web_app

      @impl true
      def plugins do
        [
          ...
          {PromEx.Plugins.Oban, queues: [:default, :media, :events], poll_rate: 10_000}
        ]
      end

      @impl true
      def dashboards do
        [
          ...
          {:prom_ex, "oban.json"}
        ]
      end
    end
    ```
    """

    use PromEx.Plugin

    import Ecto.Query, only: [group_by: 3, select: 3]

    @init_event [:oban, :supervisor, :init]
    @init_event_queue_limit_proxy [:prom_ex, :oban, :queue, :limit, :proxy]

    @impl true
    def event_metrics(opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      metric_prefix = PromEx.metric_prefix(otp_app, :oban)

      oban_supervisors = get_oban_supervisors(opts)
      keep_function_filter = keep_oban_instance_metrics(oban_supervisors)

      # Set up event proxies
      set_up_init_proxy_event(metric_prefix)

      [
        oban_supervisor_init_event_metrics(metric_prefix, keep_function_filter)
        # oban_job_event_metrics(metric_prefix)
      ]
    end

    @impl true
    def polling_metrics(opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      metric_prefix = PromEx.metric_prefix(otp_app, :oban)
      poll_rate = Keyword.get(opts, :poll_rate, 5_000)

      oban_supervisors = get_oban_supervisors(opts)

      # Queue length details
      Polling.build(
        :oban_queue_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_queue_metrics, [oban_supervisors]},
        [
          last_value(
            metric_prefix ++ [:queue, :length, :count],
            event_name: [:prom_ex, :plugin, :oban, :queue, :length, :count],
            description: "The total number jobs that are in the queue in the designated state",
            measurement: :count,
            tags: [:name, :queue, :state]
          )
        ]
      )
    end

    @doc false
    def execute_queue_metrics(oban_supervisors) do
      oban_supervisors
      |> Enum.each(fn oban_supervisor ->
        oban_supervisor
        |> Oban.Registry.whereis()
        |> case do
          oban_pid when is_pid(oban_pid) ->
            config = Oban.Registry.config(oban_supervisor)
            handle_oban_queue_polling_metrics(oban_supervisor, config)

          _ ->
            :skip
        end
      end)
    end

    defp handle_oban_queue_polling_metrics(oban_supervisor, config) do
      query =
        Oban.Job
        |> group_by([j], [j.queue, j.state])
        |> select([j], {j.queue, j.state, count(j.id)})

      config
      |> Oban.Repo.all(query)
      |> Enum.each(fn {queue, state, count} ->
        measurements = %{count: count}
        metadata = %{name: normalize_module_name(oban_supervisor), queue: queue, state: state}

        :telemetry.execute([:prom_ex, :plugin, :oban, :queue, :length, :count], measurements, metadata)
      end)
    end

    defp get_oban_supervisors(opts) do
      opts
      |> Keyword.get(:oban_supervisors, [Oban])
      |> case do
        supervisors when is_list(supervisors) ->
          MapSet.new(supervisors)

        _ ->
          raise "Invalid :oban_supervisors option value."
      end
    end

    defp oban_supervisor_init_event_metrics(metric_prefix, keep_function_filter) do
      Event.build(
        :oban_init_event_metrics,
        [
          last_value(
            metric_prefix ++ [:init, :status, :info],
            event_name: @init_event,
            description: "Information regarding the initialized oban supervisor.",
            measurement: fn _measurements -> 1 end,
            tags: [:name, :node, :plugins, :prefix, :queues, :repo, :timezone],
            tag_values: &oban_init_tag_values/1,
            keep: keep_function_filter
          ),
          last_value(
            metric_prefix ++ [:init, :circuit, :backoff, :milliseconds],
            event_name: @init_event,
            description: "The Oban supervisor's circuit backoff value.",
            measurement: fn _measurements, %{config: config} ->
              config.circuit_backoff
            end,
            tags: [:name],
            tag_values: &oban_init_tag_values/1,
            keep: keep_function_filter
          ),
          last_value(
            metric_prefix ++ [:init, :shutdown, :grace, :period, :milliseconds],
            event_name: @init_event,
            description: "The Oban supervisor's shutdown grace period value.",
            measurement: fn _measurements, %{config: config} ->
              config.shutdown_grace_period
            end,
            tags: [:name],
            tag_values: &oban_init_tag_values/1,
            keep: keep_function_filter
          ),
          last_value(
            metric_prefix ++ [:init, :poll, :interval, :milliseconds],
            event_name: @init_event,
            description: "The Oban supervisor's poll interval value.",
            measurement: fn _measurements, %{config: config} ->
              config.poll_interval
            end,
            tags: [:name],
            tag_values: &oban_init_tag_values/1,
            keep: keep_function_filter
          ),
          last_value(
            metric_prefix ++ [:init, :dispatch, :cooldown, :milliseconds],
            event_name: @init_event,
            description: "The Oban supervisor's dispatch cooldown value.",
            measurement: fn _measurements, %{config: config} ->
              config.dispatch_cooldown
            end,
            tags: [:name],
            tag_values: &oban_init_tag_values/1,
            keep: keep_function_filter
          ),
          last_value(
            metric_prefix ++ [:init, :queue, :concurrency, :limit],
            event_name: @init_event_queue_limit_proxy,
            description: "The concurrency limits of each of the Oban queue.",
            measurement: :limit,
            tags: [:name, :queue],
            tag_values: &oban_init_queues_tag_values/1,
            keep: keep_function_filter
          )
        ]
      )
    end

    defp keep_oban_instance_metrics(oban_supervisors) do
      fn
        %{config: %{name: name}} ->
          MapSet.member?(oban_supervisors, name)

        %{name: name} ->
          MapSet.member?(oban_supervisors, name)

        _ ->
          false
      end
    end

    defp oban_init_tag_values(%{config: config}) do
      plugins_string_list =
        config.plugins
        |> Enum.map(fn plugin ->
          normalize_module_name(plugin)
        end)
        |> Enum.join(", ")

      queues_string_list =
        config.queues
        |> Enum.map(fn {queue, _queue_opts} ->
          Atom.to_string(queue)
        end)
        |> Enum.join(", ")

      %{
        name: normalize_module_name(config.name),
        node: config.node,
        plugins: plugins_string_list,
        prefix: config.prefix,
        queues: queues_string_list,
        repo: config.repo,
        timezone: config.timezone
      }
    end

    defp oban_init_queues_tag_values(%{name: name, queue: queue}) do
      %{
        name: normalize_module_name(name),
        queue: queue
      }
    end

    defp set_up_init_proxy_event(prefix) do
      :telemetry.attach(
        [:prom_ex, :oban, :proxy] ++ prefix,
        @init_event,
        fn _event_name, _event_measurement, event_metadata, _config ->
          Enum.each(event_metadata.config.queues, fn {queue, queue_opts} ->
            limit = Keyword.get(queue_opts, :limit, 0)

            metadata = %{
              queue: queue,
              name: event_metadata.config.name
            }

            :telemetry.execute(@init_event_queue_limit_proxy, %{limit: limit}, metadata)
          end)
        end,
        %{}
      )
    end

    defp normalize_module_name(name) when is_atom(name) do
      name
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")
    end

    defp normalize_module_name(name), do: name
  end
else
  defmodule PromEx.Plugins.Oban do
    @moduledoc false
    use PromEx.Plugin

    @impl true
    def event_metrics(_opts) do
      PromEx.Plugin.no_dep_raise(__MODULE__, "Oban")
    end
  end
end
