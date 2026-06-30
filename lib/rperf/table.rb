# Flat table output for AI / machine consumption (`--format table` /
# `--format table-json`). Aggregation, diffing, and cutoff all happen here so
# consumers (LLMs, scripts) get a flat result table instead of a sample tree.
#
# TSV: header row, data rows, then a trailing "# summary" line of
# tab-separated key=value pairs.
# JSON: an array of row objects; the last element is { "summary": { ... } }.
#
# json is required lazily in the format methods, not here: rperf loads at
# interpreter boot via `-rrperf`, before the profiled app's bundler/setup, and
# eagerly activating the default json gem would clash with a bundle that pins a
# different json (see the note in meta.rb).

module Rperf
  module Table
    ROWS_LIMIT = 50

    module_function

    # --- single-profile report ---

    # Rows: method, self_pct, total_pct, self_ms — self_pct descending,
    # top 50 plus an "(other)" row aggregating the rest.
    def report_rows(data, limit: ROWS_LIMIT)
      flat, cum, total = flat_cum_by_name(data)
      entries = flat.sort_by { |name, w| [-w, name] }
      rows = entries.first(limit).map do |name, w|
        {
          method: name,
          self_pct: pct(w, total),
          total_pct: pct(cum[name], total),
          self_ms: ms(w),
        }
      end
      if entries.size > limit
        # Aggregate the raw weights, not the already-rounded row values:
        # per-row rounding errors are systematic and would make the (other)
        # row inconsistent with itself (pct vs ms) and with the true total
        rest_weight = entries.drop(limit).sum { |_, w| w }
        rows << {
          method: "(other)",
          self_pct: pct(rest_weight, total),
          total_pct: nil,  # overlapping cumulative values cannot be summed
          self_ms: ms(rest_weight),
        }
      end
      rows
    end

    def report_summary(data)
      s = data[:summary] || Meta.build_summary(data)
      out = {}
      out[:total_ms] = s[:total_ms] if s[:total_ms]
      out[:cpu_ms] = s[:cpu_ms] if s[:cpu_ms]
      out[:allocated_objects] = s[:allocated_objects] if s[:allocated_objects]
      out[:gc_count_minor] = s[:gc_count_minor] if s[:gc_count_minor]
      out[:gc_count_major] = s[:gc_count_major] if s[:gc_count_major]
      out
    end

    def report_tsv(data)
      rows = report_rows(data)
      out = String.new
      out << "method\tself_pct\ttotal_pct\tself_ms\n"
      rows.each do |r|
        out << [tsv_cell(r[:method]), r[:self_pct], r[:total_pct], r[:self_ms]].map { |v| v.nil? ? "" : v.to_s }.join("\t") << "\n"
      end
      out << summary_line(report_summary(data))
      out
    end

    def report_json(data)
      require "json"
      JSON.generate(report_rows(data) + [{ summary: report_summary(data) }])
    end

    # --- diff (head - base) ---

    # Rows: method, self_pct_base, self_pct_head, delta_pt — |delta_pt|
    # descending, top 50. Per-method allocation data does not exist in
    # rperf profiles, so allocation appears only in the summary.
    def diff_rows(base, head, limit: ROWS_LIMIT)
      base_flat, _, base_total = flat_cum_by_name(base)
      head_flat, _, head_total = flat_cum_by_name(head)
      names = (base_flat.keys | head_flat.keys)
      rows = names.map do |name|
        b = pct(base_flat[name] || 0, base_total)
        h = pct(head_flat[name] || 0, head_total)
        {
          method: name,
          self_pct_base: b,
          self_pct_head: h,
          delta_pt: (h - b).round(2),
        }
      end
      rows.sort_by! { |r| [-r[:delta_pt].abs, r[:method]] }
      rows.first(limit)
    end

    def diff_summary(base, head)
      b = report_summary(base)
      h = report_summary(head)
      out = {}
      %i[total_ms allocated_objects gc_count_minor gc_count_major].each do |key|
        out[:"#{key}_base"] = b[key] if b[key]
        out[:"#{key}_head"] = h[key] if h[key]
        out[:"#{key}_delta"] = (h[key] - b[key]).round(1) if b[key] && h[key]
      end
      out
    end

    def diff_tsv(base, head)
      rows = diff_rows(base, head)
      out = String.new
      out << "method\tself_pct_base\tself_pct_head\tdelta_pt\n"
      rows.each do |r|
        out << [tsv_cell(r[:method]), r[:self_pct_base], r[:self_pct_head], r[:delta_pt]].join("\t") << "\n"
      end
      out << summary_line(diff_summary(base, head))
      out
    end

    def diff_json(base, head)
      require "json"
      JSON.generate(diff_rows(base, head) + [{ summary: diff_summary(base, head) }])
    end

    # --- helpers ---

    # Flat / cumulative weights merged by method name (compute_flat_cum keys
    # are [label, path]; a method split across paths counts once).
    def flat_cum_by_name(data)
      result = Rperf.send(:compute_flat_cum, data[:aggregated_samples] || [])
      flat = Hash.new(0)
      result[:flat].each { |(label, _path), w| flat[label] += w }
      cum = Hash.new(0)
      result[:cum].each { |(label, _path), w| cum[label] += w }
      [flat, cum, result[:total_weight]]
    end

    def pct(weight, total)
      total > 0 ? (weight * 100.0 / total).round(2) : 0.0
    end

    def ms(ns)
      (ns / 1e6).round(1)
    end

    def summary_line(summary)
      (["# summary"] + summary.map { |k, v| "#{k}=#{v}" }).join("\t") + "\n"
    end

    # TSV has no escaping convention — replace separator characters so a
    # pathological method name (define_method allows any string) cannot
    # shift columns or split a row.
    def tsv_cell(value)
      s = value.to_s
      s.match?(/[\t\n\r]/) ? s.gsub(/[\t\n\r]/, " ") : s
    end
  end
end
