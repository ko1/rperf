require_relative "../rperf"

class Rperf::RackMiddleware
  # Options:
  #   label_key: - Symbol key for the endpoint label (default: :endpoint)
  #   label:     - Proc(env) -> String to customize the label value.
  #               Default: "METHOD /path" from REQUEST_METHOD and PATH_INFO.
  #
  # Note: The default uses PATH_INFO as-is. If your routes contain dynamic
  # segments (e.g. /users/:id), each unique path creates a separate label set
  # that persists in memory for the profiling session. In production with high-
  # cardinality paths, provide a custom label proc that normalizes IDs:
  #
  #   use Rperf::RackMiddleware, label: ->(env) {
  #     "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"].gsub(%r{/\d+}, '/:id')}"
  #   }
  #
  def initialize(app, label_key: :endpoint, label: nil)
    @app = app
    @label_key = label_key
    @label_proc = label
  end

  def call(env)
    endpoint = if @label_proc
      @label_proc.call(env)
    else
      "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
    end
    Rperf.profile(@label_key => endpoint) do
      @app.call(env)
    end
  end
end
