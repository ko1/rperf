require_relative "test_helper"

class TestRperfOutput < Test::Unit::TestCase
  include RperfTestHelper

  # --- PProf ---

  def test_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      content = File.binread(path)
      decompressed = Zlib::GzipReader.new(StringIO.new(content)).read
      assert_equal 0x0a, decompressed.getbyte(0),
        "First field should be sample_type (field 1, length-delimited)"
    end
  end

  def test_pprof_encode_invalid_utf8
    # Frame label with invalid UTF-8 bytes should not crash the encoder
    invalid_label = "M\xFFthod".dup.force_encoding("ASCII-8BIT")
    data = {
      aggregated_samples: [
        [[["/a.rb", invalid_label]], 1000],
      ],
      frequency: 100,
      mode: :cpu,
      total_weight: 1000,
    }
    result = Rperf::PProf.encode(data)
    assert_operator result.bytesize, :>, 0
    # First byte should be field 1, length-delimited (sample_type)
    assert_equal 0x0a, result.getbyte(0)
  end

  # --- Text ---

  def test_text_encode
    data = {
      aggregated_samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1_000_000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2_000_000],
        [[["/c.rb", "C#baz"]], 500_000],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Rperf::Text.encode(data)

    assert_include result, "Total: 3.5ms (cpu)"
    assert_include result, "Samples: 3"
    assert_include result, "Frequency: 100Hz"
    assert_include result, "Flat:"
    assert_include result, "Cumulative:"
    assert_include result, "A#foo"
    assert_include result, "B#bar"
    assert_include result, "C#baz"
  end

  def test_text_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "profile.txt")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.read(path)

      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
      assert_match(/[\d,]+\.\d+ ms\s+\d+\.\d+%/, content)
    end
  end

  def test_save_text
    Dir.mktmpdir do |dir|
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "report.dat")
      Rperf.save(path, data, format: :text)

      content = File.read(path)
      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
    end
  end

  def test_text_encode_empty
    data = { aggregated_samples: [], frequency: 100, mode: :cpu }
    result = Rperf::Text.encode(data)
    assert_equal "No samples recorded.\n", result
  end

  # --- Collapsed ---

  def test_collapsed_encode_empty
    data = { aggregated_samples: [], frequency: 100, mode: :cpu }
    assert_equal "", Rperf::Collapsed.encode(data)

    data_nil = { frequency: 100, mode: :cpu }
    assert_equal "", Rperf::Collapsed.encode(data_nil)
  end

  def test_collapsed_encode
    data = {
      aggregated_samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2000],
        [[["/c.rb", "C#baz"]], 500],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Rperf::Collapsed.encode(data)
    lines = result.strip.split("\n")

    assert_equal 2, lines.size

    merged = {}
    lines.each do |line|
      stack, weight = line.rpartition(" ").then { |s, _, w| [s, w] }
      merged[stack] = weight.to_i
    end

    assert_equal 3000, merged["B#bar;A#foo"]
    assert_equal 500, merged["C#baz"]
  end

  def test_collapsed_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.collapsed")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.read(path)

      refute_equal "\x1f\x8b".b, content.b[0, 2], "Should not be gzip format"

      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0, "Should have at least one line"

      lines.each do |line|
        stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        assert_not_nil stack, "Line should have a stack"
        assert_not_nil weight_str, "Line should have a weight"
        weight = weight_str.to_i
        assert_operator weight, :>, 0, "Weight should be positive: #{line}"
      end
    end
  end

  def test_save_collapsed
    Dir.mktmpdir do |dir|
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "test.txt")
      Rperf.save(path, data, format: :collapsed)

      content = File.read(path)
      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0

      lines.each do |line|
        _stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        weight = weight_str.to_i
        assert_operator weight, :>, 0, "Weight should be positive"
      end
    end
  end

  # --- JSON (rperf native format) ---

  def test_json_save_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      data = Rperf.start(frequency: 500, mode: :wall) do
        5_000_000.times { 1 + 1 }
      end

      Rperf.save(path, data)
      loaded = Rperf.load(path)

      assert_equal data[:mode].to_s, loaded[:mode].to_s
      assert_equal data[:frequency], loaded[:frequency]
      assert_equal data[:aggregated_samples].size, loaded[:aggregated_samples].size
    end
  end

  def test_json_format_detection
    fmt = Rperf.send(:detect_format, "profile.json.gz", nil)
    assert_equal :json, fmt

    fmt2 = Rperf.send(:detect_format, "profile.json", nil)
    assert_equal :json, fmt2
  end

  def test_json_version_embedded
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      data = Rperf.start(frequency: 500) { 1_000_000.times { 1 + 1 } }
      Rperf.save(path, data)

      raw = Zlib::GzipReader.new(StringIO.new(File.binread(path))).read
      require "json"
      raw_data = JSON.parse(raw)
      assert_equal Rperf::VERSION, raw_data["rperf_version"]
    end
  end

  def test_json_output_via_start
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path)
      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"

      loaded = Rperf.load(path)
      assert_equal "cpu", loaded[:mode].to_s
      assert_operator loaded[:aggregated_samples].size, :>, 0
    end
  end

  def test_json_version_mismatch_warning
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      require "json"
      fake_data = { mode: "cpu", frequency: 100, aggregated_samples: [], rperf_version: "0.0.0" }
      io = StringIO.new
      io.set_encoding("ASCII-8BIT")
      gz = Zlib::GzipWriter.new(io)
      gz.write(JSON.generate(fake_data))
      gz.close
      File.binwrite(path, io.string)

      old_stderr = $stderr
      $stderr = StringIO.new
      loaded = Rperf.load(path)
      warning = $stderr.string
      $stderr = old_stderr

      assert_include warning, "rperf 0.0.0"
      assert_include warning, "current: #{Rperf::VERSION}"
      assert_equal "cpu", loaded[:mode].to_s
    end
  end

  def test_json_no_version_warning
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      require "json"
      fake_data = { mode: "cpu", frequency: 100, aggregated_samples: [] }
      io = StringIO.new
      io.set_encoding("ASCII-8BIT")
      gz = Zlib::GzipWriter.new(io)
      gz.write(JSON.generate(fake_data))
      gz.close
      File.binwrite(path, io.string)

      old_stderr = $stderr
      $stderr = StringIO.new
      Rperf.load(path)
      warning = $stderr.string
      $stderr = old_stderr

      assert_include warning, "no version info"
    end
  end

  # --- Load error paths ---

  def test_load_nonexistent_file
    assert_raise(Errno::ENOENT) do
      Rperf.load("/nonexistent/path/to/profile.json.gz")
    end
  end

  def test_load_invalid_gzip
    Dir.mktmpdir do |dir|
      # Data starting with gzip magic bytes (1f 8b) but not valid gzip
      path = File.join(dir, "bad.json.gz")
      File.binwrite(path, "\x1f\x8b this is not gzip data")
      assert_raise(Zlib::GzipFile::Error) do
        Rperf.load(path)
      end

      # Plain non-JSON text (not gzip) → treated as plain JSON → parse error
      path2 = File.join(dir, "bad2.json.gz")
      File.binwrite(path2, "this is not json")
      assert_raise(JSON::ParserError) do
        Rperf.load(path2)
      end
    end
  end

  def test_load_invalid_json
    require "json"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json.gz")
      io = StringIO.new
      io.set_encoding("ASCII-8BIT")
      gz = Zlib::GzipWriter.new(io)
      gz.write("not valid json {{{")
      gz.close
      File.binwrite(path, io.string)
      assert_raise(JSON::ParserError) do
        Rperf.load(path)
      end
    end
  end

  # --- Format override ---

  def test_format_override
    assert_equal :pprof, Rperf.send(:detect_format, "anything", :pprof)
    assert_equal :json, Rperf.send(:detect_format, "anything", :json)
    assert_equal :collapsed, Rperf.send(:detect_format, "anything", :collapsed)
    assert_equal :text, Rperf.send(:detect_format, "anything", :text)
  end

  def test_format_detection_defaults_to_pprof
    assert_equal :pprof, Rperf.send(:detect_format, "profile.pb.gz", nil)
    assert_equal :pprof, Rperf.send(:detect_format, "profile.dat", nil)
    assert_equal :pprof, Rperf.send(:detect_format, "unknown", nil)
  end

  # --- Save with labels preserved in json ---

  def test_json_preserves_labels
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      Rperf.start(frequency: 500, mode: :wall)
      Rperf.label(endpoint: "/users") do
        5_000_000.times { 1 + 1 }
      end
      data = Rperf.stop

      Rperf.save(path, data)
      loaded = Rperf.load(path)

      assert_not_nil loaded[:label_sets]
      assert_operator loaded[:label_sets].size, :>, 1, "Should have at least one non-empty label set"
      has_endpoint = loaded[:label_sets].any? { |ls| ls.is_a?(Hash) && ls[:endpoint] }
      assert has_endpoint, "Should preserve endpoint label"
    end
  end

  # --- aggregate: false + output formats ---

  def test_no_aggregate_has_both_keys
    data = Rperf.start(frequency: 500, aggregate: false) do
      5_000_000.times { 1 + 1 }
    end

    assert_not_nil data
    assert_include data, :raw_samples, "Should have raw_samples"
    assert_include data, :aggregated_samples, "Should have aggregated_samples built from raw"
    assert_operator data[:raw_samples].size, :>, 0
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_no_aggregate_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "pprof output should be created with --no-aggregate"
      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"
    end
  end

  def test_no_aggregate_collapsed_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.collapsed")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path)
      content = File.read(path)
      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0

      lines.each do |line|
        _stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        assert_operator weight_str.to_i, :>, 0
      end
    end
  end

  def test_no_aggregate_text_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path)
      content = File.read(path)
      assert_include content, "Total:"
      assert_include content, "Flat:"
    end
  end

  # --- Write failure for user-specified output ---

  def test_write_failure_raises_for_user_output
    assert_raise(Errno::ENOENT, Errno::EACCES) do
      Rperf.start(output: "/proc/forbidden.json.gz", frequency: 500) do
        5_000_000.times { 1 + 1 }
      end
    end
  end

  # --- .json extension writes plain JSON (not gzip) ---

  def test_json_plain_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json")
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end
      Rperf.save(path, data)

      content = File.binread(path)
      # Should NOT start with gzip magic bytes
      assert_not_equal "\x1f\x8b".b, content[0, 2],
        ".json file should be plain text, not gzip"
      # Should be valid JSON
      require "json"
      parsed = JSON.parse(content, symbolize_names: true)
      assert_include parsed, :mode
      assert_include parsed, :aggregated_samples
    end
  end

  def test_json_gz_output_is_gzip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json.gz")
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end
      Rperf.save(path, data)

      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2],
        ".json.gz file should be gzip compressed"
    end
  end

  def test_load_plain_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.json")
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end
      Rperf.save(path, data)

      loaded = Rperf.load(path)
      assert_not_nil loaded
      assert_equal data[:mode].to_s, loaded[:mode].to_s
      assert_not_nil loaded[:aggregated_samples]
    end
  end
end
