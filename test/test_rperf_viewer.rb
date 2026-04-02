require_relative "test_helper"
require "rperf/viewer"
require "json"

class TestRperfViewer < Test::Unit::TestCase
  include RperfTestHelper

  def setup
    @inner_app = proc { |_env| [200, { "content-type" => "text/plain" }, ["ok"]] }
    @viewer = Rperf::Viewer.new(@inner_app, path: "/rperf", max_snapshots: 3)
  end

  # -- Routing --

  def test_pass_through_non_viewer_path
    env = rack_env("/other")
    status, _headers, body = @viewer.call(env)
    assert_equal 200, status
    assert_equal ["ok"], body
  end

  def test_redirect_without_trailing_slash
    env = rack_env("/rperf")
    status, headers, _body = @viewer.call(env)
    assert_equal 301, status
    assert_equal "/rperf/", headers["location"]
  end

  def test_serve_html
    env = rack_env("/rperf/")
    status, headers, body = @viewer.call(env)
    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    assert_match(/<!DOCTYPE html>/, body[0])
  end

  def test_snapshots_list_empty
    env = rack_env("/rperf/snapshots")
    status, headers, body = @viewer.call(env)
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    assert_equal [], JSON.parse(body[0])
  end

  def test_snapshot_not_found
    env = rack_env("/rperf/snapshots/999")
    status, _headers, _body = @viewer.call(env)
    assert_equal 404, status
  end

  def test_unknown_sub_path_returns_404
    env = rack_env("/rperf/unknown")
    status, _headers, _body = @viewer.call(env)
    assert_equal 404, status
  end

  # -- Snapshot management --

  def test_add_and_retrieve_snapshot
    data = make_snapshot_data
    @viewer.add_snapshot(data)

    # List
    list = json_get("/rperf/snapshots")
    assert_equal 1, list.size
    id = list[0]["id"]

    # Detail
    detail = json_get("/rperf/snapshots/#{id}")
    assert_equal id, detail["id"]
    assert_kind_of Array, detail["samples"]
    assert_kind_of Array, detail["label_sets"]
  end

  def test_max_snapshots_eviction
    4.times { @viewer.add_snapshot(make_snapshot_data) }

    list = json_get("/rperf/snapshots")
    assert_equal 3, list.size, "Should keep at most max_snapshots entries"
  end

  def test_take_snapshot_when_not_running
    result = @viewer.take_snapshot!
    assert_nil result
  end

  # -- Security headers --

  def test_html_security_headers
    env = rack_env("/rperf/")
    _status, headers, _body = @viewer.call(env)

    assert_equal "DENY", headers["x-frame-options"]
    assert_equal "nosniff", headers["x-content-type-options"]
    assert_match(/default-src 'none'/, headers["content-security-policy"])
    assert_match(/frame-ancestors 'none'/, headers["content-security-policy"])
  end

  def test_json_security_headers
    @viewer.add_snapshot(make_snapshot_data)
    env = rack_env("/rperf/snapshots")
    _status, headers, _body = @viewer.call(env)

    assert_equal "nosniff", headers["x-content-type-options"]
  end

  # -- SRI integrity attributes --

  def test_cdn_resources_have_integrity
    env = rack_env("/rperf/")
    _status, _headers, body = @viewer.call(env)
    html = body[0]

    assert_match(/integrity="sha384-[A-Za-z0-9+\/=]+"/, html, "CDN resources should have SRI hashes")
    assert_match(/crossorigin="anonymous"/, html)
  end

  # -- Custom path --

  def test_custom_path
    viewer = Rperf::Viewer.new(@inner_app, path: "/profiler")
    env = rack_env("/profiler/")
    status, _headers, _body = viewer.call(env)
    assert_equal 200, status

    env = rack_env("/rperf/")
    status, _headers, body = viewer.call(env)
    assert_equal 200, status
    assert_equal ["ok"], body  # falls through to inner app
  end

  # -- Instance tracking --

  def test_instance_tracking
    assert_equal @viewer, Rperf::Viewer.instance
  end

  private

  def rack_env(path, method: "GET")
    { "REQUEST_METHOD" => method, "PATH_INFO" => path }
  end

  def json_get(path)
    env = rack_env(path)
    _status, _headers, body = @viewer.call(env)
    JSON.parse(body[0])
  end

  def make_snapshot_data
    {
      mode: :wall,
      frequency: 1000,
      duration_ns: 1_000_000_000,
      sampling_count: 10,
      trigger_count: 10,
      sampling_time_ns: 50_000,
      aggregated_samples: [
        [[["/test.rb", "Object#test"]], 500_000_000, 1, 0],
        [[["/test.rb", "Object#work"]], 500_000_000, 1, 0],
      ],
      label_sets: [{}],
    }
  end
end
