require "rperf"

class Rperf::SidekiqMiddleware
  def call(_worker, job, _queue)
    Rperf.profile(job: job["class"]) do
      yield
    end
  end
end
