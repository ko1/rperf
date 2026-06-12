require_relative "../rperf"

class Rperf::RackMiddleware
  # Options:
  #   label_key: - Symbol key for the endpoint label (default: :endpoint)
  #   label:     - Proc(env) -> String to customize the label value.
  #               Default: "METHOD /path" with dynamic segments normalized
  #               (numeric IDs → :id, UUIDs → :uuid) to keep label cardinality low.
  #               Set label: :raw to use PATH_INFO as-is (not recommended for
  #               routes with dynamic segments — each unique path persists in
  #               memory for the profiling session).
  #
  def initialize(app, label_key: :endpoint, label: nil)
    @app = app
    @label_key = label_key
    @label_proc = label
  end

  UUID_RE = %r{/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=/|\z)}i
  NUMERIC_RE = %r{/\d+(?=/|\z)}

  def call(env)
    # No-op when the profiler is not running (Rperf.profile would raise):
    # the app may boot without Rperf.start, stop mid-run, or run in a forked
    # worker where the atfork handler silently stopped profiling.
    return @app.call(env) unless Rperf.running?

    endpoint = if @label_proc == :raw
      "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
    elsif @label_proc
      @label_proc.call(env)
    else
      path = env["PATH_INFO"]
        .gsub(UUID_RE, "/:uuid")
        .gsub(NUMERIC_RE, "/:id")
      "#{env["REQUEST_METHOD"]} #{path}"
    end
    Rperf.profile(@label_key => endpoint) do
      @app.call(env)
    end
  end
end
