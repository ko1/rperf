require_relative "test_helper"
require "rperf/rack"

class TestRperfRackMiddleware < Test::Unit::TestCase
  include RperfTestHelper

  def setup
    @inner_app = proc { |_env| [200, { "content-type" => "text/plain" }, ["ok"]] }
  end

  def test_default_label
    mw = Rperf::RackMiddleware.new(@inner_app)
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/users" }
    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    mw = Rperf::RackMiddleware.new(app)
    mw.call(env)

    assert_equal "GET /users", labels_inside[:endpoint]
  end

  def test_default_label_normalizes_numeric_ids
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    mw = Rperf::RackMiddleware.new(app)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/users/12345/posts/678" }
    mw.call(env)

    assert_equal "GET /users/:id/posts/:id", labels_inside[:endpoint]
  end

  def test_default_label_normalizes_uuids
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    mw = Rperf::RackMiddleware.new(app)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/items/550e8400-e29b-41d4-a716-446655440000" }
    mw.call(env)

    assert_equal "GET /items/:uuid", labels_inside[:endpoint]
  end

  def test_raw_label_skips_normalization
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    mw = Rperf::RackMiddleware.new(app, label: :raw)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/users/12345" }
    mw.call(env)

    assert_equal "GET /users/12345", labels_inside[:endpoint]
  end

  def test_custom_label_key
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    mw = Rperf::RackMiddleware.new(app, label_key: :http_endpoint)
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/api" }
    mw.call(env)

    assert_nil labels_inside[:endpoint]
    assert_equal "POST /api", labels_inside[:http_endpoint]
  end

  def test_custom_label_proc
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    labels_inside = nil
    app = proc { |_e| labels_inside = Rperf.labels; [200, {}, [""]] }
    normalizer = ->(env) { "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"].gsub(%r{/\d+}, "/:id")}" }
    mw = Rperf::RackMiddleware.new(app, label: normalizer)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/users/12345/posts/678" }
    mw.call(env)

    assert_equal "GET /users/:id/posts/:id", labels_inside[:endpoint]
  end

  def test_returns_inner_app_response
    mw = Rperf::RackMiddleware.new(@inner_app)
    Rperf.start(frequency: 1000, mode: :cpu, defer: true)

    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/" }
    status, headers, body = mw.call(env)

    assert_equal 200, status
    assert_equal "text/plain", headers["content-type"]
    assert_equal ["ok"], body
  end
end
