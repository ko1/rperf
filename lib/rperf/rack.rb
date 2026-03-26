require "rperf"

class Rperf::RackMiddleware
  def initialize(app, label_key: :endpoint)
    @app = app
    @label_key = label_key
  end

  def call(env)
    endpoint = "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
    Rperf.profile(@label_key => endpoint) do
      @app.call(env)
    end
  end
end
