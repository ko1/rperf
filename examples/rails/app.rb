# Minimal single-file Rails app with rperf profiling
#
# WARNING: This is a development example only. It disables host checking,
# exposes the profiler viewer without authentication, and binds to all
# interfaces. Do NOT deploy this configuration in production or on shared
# networks — profiling data reveals internal code structure and timing.
#
# Usage:
#   cd examples/rails
#   bundle install
#   bundle exec ruby app.rb
#
# Then visit:
#   http://localhost:3000/        - endpoint index
#   http://localhost:3000/rperf/  - profiler viewer

require "rails"
require "action_controller/railtie"
require_relative "../../lib/rperf"
require_relative "../../lib/rperf/viewer"
require_relative "../../lib/rperf/rack"

class RperfExampleApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "rperf-example-secret-key-base-for-development-only"
  config.hosts.clear
  config.logger = Logger.new($stdout, level: :warn)

  # Mount rperf middlewares
  config.middleware.use Rperf::Viewer, max_snapshots: 50
  config.middleware.use Rperf::RackMiddleware
end

# --- Controllers ---

class WorkController < ActionController::Base
  # CPU-bound: fibonacci
  def cpu
    n = (params[:n] || 35).to_i
    result = fib(n)
    render plain: "fib(#{n}) = #{result}"
  end

  # String/Regex processing
  def string
    text = "Hello World! " * 100_000
    result = text.gsub(/[aeiou]/i, "*")
    words = result.split(/\s+/)
    render plain: "Processed #{words.size} words"
  end

  # GC-heavy: object allocation churn
  def gc
    10.times do
      Array.new(50_000) { { key: rand.to_s, value: [1, 2, 3].dup } }
    end
    render plain: "GC work done (#{GC.stat[:total_allocated_objects]} total allocs)"
  end

  # Simulated DB/network latency
  def slow
    # Simulate 3 sequential "queries"
    3.times do
      sleep 0.03
      sum = 0
      100_000.times { |i| sum += i }
    end
    render plain: "3 queries done"
  end

  # Mixed workload
  def mixed
    fib(30)
    sleep 0.02
    5.times { Array.new(20_000) { rand.to_s } }
    render plain: "mixed done"
  end

  # JSON API endpoint
  def data
    items = 1000.times.map do |i|
      { id: i, name: "Item #{i}", score: rand(100), tags: %w[ruby rails rperf].sample(2) }
    end
    sorted = items.sort_by { |item| -item[:score] }
    render json: { items: sorted.first(20), total: items.size }
  end

  # Take a profiler snapshot
  def snapshot
    entry = Rperf::Viewer.instance&.take_snapshot!
    if entry
      render plain: "Snapshot ##{entry[:id]} (#{entry[:data][:sampling_count]} samples)"
    else
      render plain: "Profiler not running"
    end
  end

  # Index page
  def index
    render plain: <<~TEXT
      rperf Rails Example
      ====================
      GET /cpu        - Fibonacci (CPU-bound)
      GET /cpu?n=38   - Fibonacci with custom N
      GET /string     - String/regex processing
      GET /gc         - GC-heavy object churn
      GET /slow       - Simulated slow queries
      GET /mixed      - Mixed workload
      GET /data       - JSON API endpoint
      GET /snapshot   - Take profiler snapshot
      GET /rperf/     - Profiler viewer UI
    TEXT
  end

  private

  def fib(n)
    return n if n <= 1
    fib(n - 1) + fib(n - 2)
  end
end

# --- Routes ---

RperfExampleApp.initialize!

Rails.application.routes.draw do
  get "/" => "work#index"
  get "/cpu" => "work#cpu"
  get "/string" => "work#string"
  get "/gc" => "work#gc"
  get "/slow" => "work#slow"
  get "/mixed" => "work#mixed"
  get "/data" => "work#data"
  get "/snapshot" => "work#snapshot"
end

# --- Start profiling ---

Rperf.start(mode: :wall, frequency: 999, defer: true)

# --- Auto-load after boot ---

Thread.new do
  require "net/http"
  sleep 2  # Wait for Puma to start

  base = URI("http://127.0.0.1:3000")
  endpoints = %w[/cpu /string /gc /slow /mixed /data]

  $stderr.puts "[rperf] Generating traffic..."

  3.times do |round|
    threads = 4.times.map do
      Thread.new do
        endpoints.each do |ep|
          Net::HTTP.get(URI("#{base}#{ep}"))
        end
      end
    end
    threads.each(&:join)
    Net::HTTP.get(URI("#{base}/snapshot"))
    $stderr.puts "[rperf] snapshot ##{round + 1} taken"
  end

  $stderr.puts "[rperf] Ready! Visit http://127.0.0.1:3000/rperf/"
end

# --- Run with Puma ---

require "puma"
require "puma/configuration"
require "puma/launcher"

conf = Puma::Configuration.new do |c|
  c.bind "tcp://127.0.0.1:3000"
  c.app RperfExampleApp
end
Puma::Launcher.new(conf).run
