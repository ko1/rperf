require_relative "../rperf"
require "json"

# Rack middleware that serves flamegraph visualizations of rperf snapshots.
#
# Usage:
#   require "rperf/viewer"
#   use Rperf::Viewer                             # mount at /rperf (default)
#   use Rperf::Viewer, path: "/profiler"          # custom mount path
#   use Rperf::Viewer, max_snapshots: 12          # keep fewer snapshots
#
# Take snapshots periodically:
#   viewer = Rperf::Viewer.instance
#   viewer.take_snapshot!          # snapshot with clear: true
#   viewer.add_snapshot(data)      # or add pre-taken snapshot data
#
class Rperf::Viewer
  @instance = nil

  class << self
    # Returns the most recently created Viewer instance.
    attr_reader :instance
  end

  attr_reader :max_snapshots, :path

  def initialize(app, path: "/rperf", max_snapshots: 24)
    @app = app
    @path = path.chomp("/")
    @max_snapshots = max_snapshots
    @snapshots = []  # [{id:, taken_at:, data:}, ...]
    @mutex = Mutex.new
    @next_id = 0
    self.class.instance_variable_set(:@instance, self)
  end

  # Take a snapshot from the running profiler and store it.
  # Returns the snapshot entry or nil if profiler is not running.
  def take_snapshot!
    data = Rperf.snapshot(clear: true)
    return nil unless data
    add_snapshot(data)
  end

  # Add a pre-taken snapshot hash to the history.
  def add_snapshot(data)
    @mutex.synchronize do
      @next_id += 1
      entry = { id: @next_id, taken_at: Time.now, data: data }
      @snapshots << entry
      @snapshots.shift while @snapshots.size > @max_snapshots
      entry
    end
  end

  # Rack interface
  def call(env)
    req_path = env["PATH_INFO"] || "/"

    # Not our path — pass through to app
    if req_path == @path
      # Exact match: redirect to trailing slash
      return [301, { "location" => "#{@path}/" }, [""]]
    end
    unless req_path.start_with?("#{@path}/")
      return @app ? @app.call(env) : [404, { "content-type" => "text/plain" }, ["Not Found"]]
    end

    # Strip prefix to get sub-path
    sub_path = req_path[@path.size..]

    case sub_path
    when "/"
      serve_html
    when "/snapshots"
      serve_snapshot_list
    when %r{\A/snapshots/(\d+)\z}
      serve_snapshot($1.to_i)
    else
      [404, { "content-type" => "text/plain" }, ["Not Found"]]
    end
  end

  private

  LOGO_SVG = begin
    path = File.expand_path("../../docs/logo.svg", __dir__)
    File.exist?(path) ? File.read(path).freeze : ""
  end

  def serve_html
    logo = LOGO_SVG
      .sub("<svg ", '<svg style="height:36px;width:auto" ')
    [200, {
      "content-type" => "text/html; charset=utf-8",
      "x-frame-options" => "DENY",
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'self'; img-src data:; frame-ancestors 'none'",
    }, [VIEWER_HTML.sub("<!-- LOGO -->") { logo }]]
  end

  def serve_snapshot_list
    list = @mutex.synchronize do
      @snapshots.map do |s|
        {
          id: s[:id],
          taken_at: s[:taken_at].iso8601,
          mode: s[:data][:mode],
          duration_ns: s[:data][:duration_ns],
          sampling_count: s[:data][:sampling_count],
        }
      end
    end
    json_response(list)
  end

  def serve_snapshot(id)
    entry = @mutex.synchronize { @snapshots.find { |s| s[:id] == id } }
    return [404, { "content-type" => "text/plain" }, ["Snapshot not found"]] unless entry

    data = entry[:data]
    samples = data[:aggregated_samples]
    label_sets = data[:label_sets] || []

    # Convert samples to JSON-friendly format.
    # Stack is stored top-to-bottom (leaf first) in C; reverse to root-first for flamegraph.
    json_samples = samples.map do |frames, weight, thread_seq, label_set_id|
      {
        stack: frames.reverse.map { |_, label| label },
        weight: weight,
        thread_seq: thread_seq || 0,
        label_set_id: label_set_id || 0,
      }
    end

    # Convert label_sets: symbol keys to string keys for JSON
    json_label_sets = label_sets.map do |ls|
      ls.is_a?(Hash) ? ls.transform_keys(&:to_s) : ls
    end

    json_response({
      id: entry[:id],
      taken_at: entry[:taken_at].iso8601,
      mode: data[:mode],
      frequency: data[:frequency],
      duration_ns: data[:duration_ns],
      sampling_count: data[:sampling_count],
      samples: json_samples,
      label_sets: json_label_sets,
    })
  end

  def json_response(obj)
    [200, {
      "content-type" => "application/json; charset=utf-8",
      "x-content-type-options" => "nosniff",
    }, [JSON.generate(obj)]]
  end

  VIEWER_HTML = <<~'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>rperf Viewer</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/d3-flame-graph@4/dist/d3-flamegraph.css" integrity="sha384-DgAQSBzzhv8bu6Qc6Lq08THluOr+kO5qLMHt1yv8A3my7Jz2OQv6aq/WSZRYIQkG" crossorigin="anonymous">
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; background: #fafafa; color: #333; }

/* Header */
.header { background: #fff; padding: 10px 20px; display: flex; align-items: center; gap: 16px; flex-wrap: wrap; border-bottom: 1px solid #ddd; }
.controls { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.controls label { font-size: 13px; color: #555; }
.controls select, .controls input[type="text"] {
  background: #fff; color: #333; border: 1px solid #ccc; border-radius: 4px;
  padding: 4px 8px; font-size: 13px; font-family: inherit;
}
.controls input[type="text"] { width: 120px; }
.dropdown-cb { position: relative; display: inline-block; vertical-align: middle; }
.dropdown-cb-btn {
  background: #fff; color: #888; border: 1px solid #ccc; border-radius: 4px;
  padding: 4px 8px; font-size: 13px; font-family: inherit; cursor: pointer; min-width: 60px; text-align: left;
}
.dropdown-cb-btn.has-selection { color: #333; }
.dropdown-cb-btn:hover { border-color: #999; }
.dropdown-cb-list {
  display: none; position: absolute; top: 100%; left: 0; z-index: 100;
  background: #fff; border: 1px solid #ccc; border-radius: 4px;
  padding: 4px 0; min-width: 180px; max-height: 240px; overflow-y: auto;
  box-shadow: 0 4px 12px rgba(0,0,0,0.15);
}
.dropdown-cb-list.open { display: block; }
.dropdown-cb-list label {
  display: block; padding: 4px 10px; font-size: 12px; cursor: pointer; white-space: nowrap;
  color: #333; background: none; border: none; border-radius: 0;
}
.dropdown-cb-list label:hover { background: #f0e8e0; }
.controls input[type="text"]::placeholder { color: #aaa; }

/* Tabs */
.tabs { display: flex; background: #fff; border-bottom: 1px solid #ddd; padding: 0 20px; }
.tab {
  padding: 8px 20px; font-size: 13px; color: #888; cursor: pointer;
  border-bottom: 2px solid transparent; transition: color 0.15s;
}
.tab:hover { color: #555; }
.tab.active { color: #cc342d; border-bottom-color: #cc342d; }

/* Info bar */
.info-bar { background: #f5f5f5; padding: 6px 20px; font-size: 12px; color: #888; border-bottom: 1px solid #eee; }

/* Tab content */
.tab-content { display: none; }
.tab-content.active { display: block; }
#panel-flamegraph { background: #fff; min-height: 300px; }
.empty-state { display: flex; align-items: center; justify-content: center; height: 400px; color: #aaa; font-size: 16px; }
#panel-flamegraph .d3-flame-graph rect { stroke: #fff; stroke-width: 0.5px; }

/* Top table */
#panel-top { padding: 16px 20px; background: #fff; }
#panel-top table { width: 100%; border-collapse: collapse; font-size: 13px; }
#panel-top th { text-align: left; color: #cc342d; border-bottom: 2px solid #eee; padding: 6px 8px; cursor: pointer; }
#panel-top th:hover { color: #a82a24; }
#panel-top td { padding: 5px 8px; border-bottom: 1px solid #f0f0f0; }
#panel-top tr:hover td { background: #faf5f0; }
.num { text-align: right; font-variant-numeric: tabular-nums; }

/* Tags panel */
#panel-tags { padding: 16px 20px; background: #fff; }
.tag-group { margin-bottom: 20px; }
.tag-group h3 { font-size: 14px; color: #cc342d; margin-bottom: 8px; }
.tag-group table { width: 100%; max-width: 600px; border-collapse: collapse; font-size: 13px; }
.tag-group th { text-align: left; color: #888; border-bottom: 2px solid #eee; padding: 5px 8px; }
.tag-group td { padding: 5px 8px; border-bottom: 1px solid #f0f0f0; }
.tag-group tr:hover td { background: #faf5f0; }
.tag-group tr { cursor: pointer; }
.tag-bar { display: inline-block; height: 12px; background: #cc342d; border-radius: 2px; vertical-align: middle; }
</style>
</head>
<body>
<div class="header">
  <a href="https://github.com/ko1/rperf" target="_blank" rel="noopener" title="rperf on GitHub" style="display:flex;align-items:center;text-decoration:none;">
    <!-- LOGO -->
  </a>
  <div class="controls">
    <label>Snapshot:
      <select id="sel-snapshot"><option value="">Loading...</option></select>
    </label>
    <label>tagfocus: <input type="text" id="in-tagfocus" placeholder="value regex"></label>
    <label>tagignore:
      <span class="dropdown-cb">
        <button type="button" id="btn-tagignore" class="dropdown-cb-btn">none</button>
        <div id="cb-tagignore" class="dropdown-cb-list"></div>
      </span>
    </label>
    <label>tagroot:
      <span class="dropdown-cb">
        <button type="button" id="btn-tagroot" class="dropdown-cb-btn">none</button>
        <div id="cb-tagroot" class="dropdown-cb-list"></div>
      </span>
    </label>
    <label>tagleaf:
      <span class="dropdown-cb">
        <button type="button" id="btn-tagleaf" class="dropdown-cb-btn">none</button>
        <div id="cb-tagleaf" class="dropdown-cb-list"></div>
      </span>
    </label>
  </div>
</div>
<div class="tabs">
  <div class="tab active" data-tab="flamegraph">Flamegraph</div>
  <div class="tab" data-tab="top">Top</div>
  <div class="tab" data-tab="tags">Tags</div>
</div>
<div id="info-bar" class="info-bar"></div>
<div id="panel-flamegraph" class="tab-content active"></div>
<div id="panel-top" class="tab-content"></div>
<div id="panel-tags" class="tab-content"></div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/d3/7.9.0/d3.min.js" integrity="sha384-CjloA8y00+1SDAUkjs099PVfnY2KmDC2BZnws9kh8D/lX1s46w6EPhpXdqMfjK6i" crossorigin="anonymous"></script>
<script src="https://cdn.jsdelivr.net/npm/d3-flame-graph@4/dist/d3-flamegraph.min.js" integrity="sha384-p4NaVVE+k6MT/enE0MtQ8B15rM9BGzHCnx8DizawPGks1ssZUeNdw6bAPpH2gp2w" crossorigin="anonymous"></script>
<script>
"use strict";

var BASE = location.pathname.replace(/\/$/, "");
var currentData = null;
var currentTab = "flamegraph";
var filteredSamples = null;  // cached after filter
var totalFilteredNs = 0;

// --- Helpers ---

function fmtMs(ns) { return (ns / 1e6).toFixed(2); }
function fmtPct(ns, total) { return total > 0 ? (ns / total * 100).toFixed(1) : "0.0"; }

// --- Data fetching ---

async function fetchJSON(path) {
  var res = await fetch(BASE + path);
  if (!res.ok) throw new Error(res.status + " " + res.statusText);
  return res.json();
}

async function loadSnapshotList() {
  var list = await fetchJSON("/snapshots");
  var sel = document.getElementById("sel-snapshot");
  sel.innerHTML = "";
  if (list.length === 0) {
    sel.innerHTML = '<option value="">No snapshots</option>';
    return;
  }
  var reversed = list.slice().reverse();
  reversed.forEach(function(s) {
    var opt = document.createElement("option");
    opt.value = s.id;
    var t = new Date(s.taken_at);
    var dur = (s.duration_ns / 1e9).toFixed(1);
    opt.textContent = "#" + s.id + " " + t.toLocaleTimeString() +
      " (" + s.mode + ", " + dur + "s, " + s.sampling_count + " samples)";
    sel.appendChild(opt);
  });
  await loadSnapshot(reversed[0].id);
}

async function loadSnapshot(id) {
  currentData = await fetchJSON("/snapshots/" + id);
  updateTagDropdowns();
  applyAndRender();
}

// --- Update tag key/value dropdowns from current snapshot ---

function updateTagDropdowns() {
  if (!currentData || !currentData.label_sets) return;
  var labelSets = currentData.label_sets;

  // Collect all keys and all key:value pairs
  var keys = {};
  var vals = {};
  labelSets.forEach(function(ls) {
    if (!ls) return;
    Object.keys(ls).forEach(function(k) {
      keys[k] = true;
      var compound = k + " = " + ls[k];
      vals[compound] = true;
    });
  });

  var sortedKeys = Object.keys(keys).sort();
  // Group by key: for each key, (none) first, then values sorted
  var sortedVals = [];
  sortedKeys.forEach(function(k) {
    sortedVals.push(k + " = (none)");
    Object.keys(vals).sort().forEach(function(v) {
      if (v.substring(0, k.length + 3) === k + " = ") sortedVals.push(v);
    });
  });

  // tagroot / tagleaf: dropdown checkboxes for label keys
  ["tagroot", "tagleaf"].forEach(function(name) {
    var container = document.getElementById("cb-" + name);
    var prev = getCheckedValues(container);
    container.innerHTML = "";
    sortedKeys.forEach(function(k) {
      var lbl = document.createElement("label");
      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.value = k;
      if (prev.indexOf(k) >= 0) cb.checked = true;
      cb.addEventListener("change", function() {
        updateDropdownButton("btn-" + name, "cb-" + name, "none");
        applyAndRender();
      });
      lbl.appendChild(cb);
      lbl.appendChild(document.createTextNode(" " + k));
      container.appendChild(lbl);
    });
    updateDropdownButton("btn-" + name, "cb-" + name, "none");
  });

  // tagignore: dropdown with checkboxes for key=value pairs
  var container = document.getElementById("cb-tagignore");
  var prev = getCheckedValues(container);
  container.innerHTML = "";
  sortedVals.forEach(function(display) {
    var lbl = document.createElement("label");
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = display;
    if (prev.indexOf(display) >= 0) cb.checked = true;
    cb.addEventListener("change", function() {
      updateDropdownButton("btn-tagignore", "cb-tagignore", "none");
      applyAndRender();
    });
    lbl.appendChild(cb);
    lbl.appendChild(document.createTextNode(" " + display));
    container.appendChild(lbl);
  });
  updateDropdownButton("btn-tagignore", "cb-tagignore", "none");
}

function updateDropdownButton(btnId, containerId, emptyText) {
  var vals = getCheckedValues(document.getElementById(containerId));
  var btn = document.getElementById(btnId);
  if (vals.length === 0) {
    btn.textContent = emptyText;
    btn.classList.remove("has-selection");
  } else {
    btn.textContent = vals.join(", ");
    btn.classList.add("has-selection");
  }
}

function getCheckedValues(container) {
  var result = [];
  var cbs = container.querySelectorAll("input[type=checkbox]:checked");
  for (var i = 0; i < cbs.length; i++) result.push(cbs[i].value);
  return result;
}

// --- Tag filtering ---

function getFilteredSamples() {
  if (!currentData) return [];
  var samples = currentData.samples;
  var labelSets = currentData.label_sets || [];
  var tagfocus = document.getElementById("in-tagfocus").value.trim();
  var tagignoreVals = getCheckedValues(document.getElementById("cb-tagignore"));
  var tagroots = getCheckedValues(document.getElementById("cb-tagroot"));
  var tagleaves = getCheckedValues(document.getElementById("cb-tagleaf"));

  var filtered = samples;

  // tagfocus: keep only samples whose label values match the regex
  if (tagfocus) {
    try { var re = new RegExp(tagfocus); } catch(e) { /* invalid regex, skip filter */ }
    if (!re) return filtered;
    filtered = filtered.filter(function(s) {
      if (s.label_set_id === 0) return false;
      var ls = labelSets[s.label_set_id];
      if (!ls) return false;
      return Object.values(ls).some(function(v) { return re.test(String(v)); });
    });
  }

  // tagignore: remove samples matching selected key=value pairs (or missing key for "(none)")
  if (tagignoreVals.length > 0) {
    var ignores = tagignoreVals.map(function(s) {
      var idx = s.indexOf(" = ");
      return { key: s.substring(0, idx), val: s.substring(idx + 3) };
    });
    filtered = filtered.filter(function(s) {
      var ls = (s.label_set_id > 0) ? labelSets[s.label_set_id] : null;
      return !ignores.some(function(ig) {
        if (ig.val === "(none)") {
          // Match samples that do NOT have this key
          return !ls || !(ig.key in ls);
        }
        return ls && ls[ig.key] !== undefined && String(ls[ig.key]) === ig.val;
      });
    });
  }

  // tagroot: prepend label values as root frames (outermost first)
  if (tagroots.length > 0) {
    filtered = filtered.map(function(s) {
      if (s.label_set_id === 0) return s;
      var ls = labelSets[s.label_set_id];
      if (!ls) return s;
      var extra = [];
      for (var i = 0; i < tagroots.length; i++) {
        var k = tagroots[i];
        if (k in ls) extra.push("[" + k + ": " + ls[k] + "]");
      }
      if (extra.length === 0) return s;
      return Object.assign({}, s, { stack: extra.concat(s.stack) });
    });
  }

  // tagleaf: append label values as leaf frames (innermost first)
  if (tagleaves.length > 0) {
    filtered = filtered.map(function(s) {
      if (s.label_set_id === 0) return s;
      var ls = labelSets[s.label_set_id];
      if (!ls) return s;
      var extra = [];
      for (var i = 0; i < tagleaves.length; i++) {
        var k = tagleaves[i];
        if (k in ls) extra.push("[" + k + ": " + ls[k] + "]");
      }
      if (extra.length === 0) return s;
      return Object.assign({}, s, { stack: s.stack.concat(extra) });
    });
  }

  return filtered;
}

function applyAndRender() {
  filteredSamples = getFilteredSamples();
  totalFilteredNs = 0;
  for (var i = 0; i < filteredSamples.length; i++) totalFilteredNs += filteredSamples[i].weight;

  // Update info bar
  if (!currentData) return;
  var dur = (currentData.duration_ns / 1e9).toFixed(2);
  document.getElementById("info-bar").textContent =
    "Mode: " + currentData.mode + " | Freq: " + currentData.frequency + "Hz | Duration: " + dur + "s" +
    " | Stacks: " + filteredSamples.length + " | Total weight: " + fmtMs(totalFilteredNs) + "ms";

  renderCurrentTab();
}

function renderCurrentTab() {
  if (currentTab === "flamegraph") renderFlamegraph();
  else if (currentTab === "top") renderTop();
  else if (currentTab === "tags") renderTags();
}

// ==================== Flamegraph ====================

function buildTree(samples) {
  var root = { name: "root", value: 0, children: [] };
  for (var si = 0; si < samples.length; si++) {
    var sample = samples[si];
    var node = root;
    for (var i = 0; i < sample.stack.length; i++) {
      var name = sample.stack[i];
      var child = null;
      for (var j = 0; j < node.children.length; j++) {
        if (node.children[j].name === name) { child = node.children[j]; break; }
      }
      if (!child) {
        child = { name: name, value: 0, children: [] };
        node.children.push(child);
      }
      node = child;
    }
    node.value += sample.weight;
  }
  return root;
}

function renderFlamegraph() {
  var el = document.getElementById("panel-flamegraph");
  el.innerHTML = "";
  if (!filteredSamples || filteredSamples.length === 0) {
    el.innerHTML = '<div class="empty-state">No matching samples</div>';
    return;
  }
  var tree = buildTree(filteredSamples);
  var total = totalFilteredNs;
  var width = el.clientWidth || document.body.clientWidth;
  var chart = flamegraph()
    .width(width)
    .cellHeight(20)
    .selfValue(true)
    .getName(function(d) {
      return d.data.name + " (" + fmtMs(d.data.value) + "ms, " + fmtPct(d.data.value, total) + "%)";
    });
  d3.select("#panel-flamegraph").datum(tree).call(chart);
}

// ==================== Top ====================

var topSortKey = "flat";
var topSortAsc = false;

function renderTop() {
  var el = document.getElementById("panel-top");
  if (!filteredSamples || filteredSamples.length === 0) {
    el.innerHTML = '<div class="empty-state">No matching samples</div>';
    return;
  }

  // Compute flat (leaf) and cumulative (any position) per function
  var flatMap = {};
  var cumMap = {};
  for (var si = 0; si < filteredSamples.length; si++) {
    var s = filteredSamples[si];
    var stack = s.stack;
    var w = s.weight;
    var leaf = stack[stack.length - 1];
    flatMap[leaf] = (flatMap[leaf] || 0) + w;
    var seen = {};
    for (var i = 0; i < stack.length; i++) {
      if (!seen[stack[i]]) {
        seen[stack[i]] = true;
        cumMap[stack[i]] = (cumMap[stack[i]] || 0) + w;
      }
    }
  }

  var rows = [];
  var allNames = {};
  Object.keys(flatMap).forEach(function(k) { allNames[k] = true; });
  Object.keys(cumMap).forEach(function(k) { allNames[k] = true; });
  Object.keys(allNames).forEach(function(name) {
    rows.push({ name: name, flat: flatMap[name] || 0, cum: cumMap[name] || 0 });
  });

  // Sort
  var key = topSortKey;
  var asc = topSortAsc;
  rows.sort(function(a, b) {
    var va = (key === "name") ? a.name : a[key];
    var vb = (key === "name") ? b.name : b[key];
    if (key === "name") {
      return asc ? va.localeCompare(vb) : vb.localeCompare(va);
    }
    return asc ? va - vb : vb - va;
  });

  var total = totalFilteredNs;
  var arrow = function(k) { return (topSortKey === k) ? (topSortAsc ? " \u25b2" : " \u25bc") : ""; };
  var html = '<table><thead><tr>' +
    '<th class="num" data-sort="flat">Flat' + arrow("flat") + '</th>' +
    '<th class="num" data-sort="cum">Cum' + arrow("cum") + '</th>' +
    '<th data-sort="name">Function' + arrow("name") + '</th>' +
    '</tr></thead><tbody>';
  var limit = Math.min(rows.length, 50);
  for (var ri = 0; ri < limit; ri++) {
    var r = rows[ri];
    html += '<tr>' +
      '<td class="num">' + fmtMs(r.flat) + 'ms (' + fmtPct(r.flat, total) + '%)</td>' +
      '<td class="num">' + fmtMs(r.cum) + 'ms (' + fmtPct(r.cum, total) + '%)</td>' +
      '<td>' + escHtml(r.name) + '</td>' +
      '</tr>';
  }
  html += '</tbody></table>';
  if (rows.length > 50) {
    html += '<p style="color:#888;margin-top:8px;font-size:12px;">Showing top 50 of ' + rows.length + ' functions</p>';
  }
  el.innerHTML = html;

  // Attach sort handlers
  el.querySelectorAll("th[data-sort]").forEach(function(th) {
    th.addEventListener("click", function() {
      var newKey = th.getAttribute("data-sort");
      if (topSortKey === newKey) {
        topSortAsc = !topSortAsc;
      } else {
        topSortKey = newKey;
        topSortAsc = (newKey === "name");
      }
      renderTop();
    });
  });
}

function escHtml(s) {
  return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

// ==================== Tags ====================

function renderTags() {
  var el = document.getElementById("panel-tags");
  if (!currentData) { el.innerHTML = '<div class="empty-state">No data</div>'; return; }

  var samples = filteredSamples || [];
  var labelSets = currentData.label_sets || [];
  if (labelSets.length === 0) {
    el.innerHTML = '<div class="empty-state">No tags in this snapshot</div>';
    return;
  }

  // Collect all tag keys
  var tagKeys = {};
  labelSets.forEach(function(ls) {
    if (!ls) return;
    Object.keys(ls).forEach(function(k) { tagKeys[k] = true; });
  });

  var keys = Object.keys(tagKeys);
  if (keys.length === 0) {
    el.innerHTML = '<div class="empty-state">No tags in this snapshot</div>';
    return;
  }

  // For each key, aggregate weight per value
  var html = "";
  keys.forEach(function(key) {
    var byVal = {};     // value -> weight
    var untagged = 0;   // weight without this key
    for (var i = 0; i < samples.length; i++) {
      var s = samples[i];
      var ls = (s.label_set_id > 0) ? labelSets[s.label_set_id] : null;
      if (ls && key in ls) {
        var v = String(ls[key]);
        byVal[v] = (byVal[v] || 0) + s.weight;
      } else {
        untagged += s.weight;
      }
    }

    var entries = [];
    Object.keys(byVal).forEach(function(v) { entries.push({ val: v, weight: byVal[v] }); });
    entries.sort(function(a, b) { return b.weight - a.weight; });
    var maxWeight = entries.length > 0 ? entries[0].weight : 0;
    var total = totalFilteredNs;

    html += '<div class="tag-group"><h3>' + escHtml(key) +
      ' <span style="color:#666;font-weight:normal;">(' + entries.length + ' values)</span></h3>';
    html += '<table><thead><tr><th>Value</th><th class="num">Weight</th><th class="num">%</th><th style="width:200px"></th></tr></thead><tbody>';
    entries.forEach(function(e) {
      var barW = maxWeight > 0 ? Math.max(1, Math.round(e.weight / maxWeight * 180)) : 0;
      html += '<tr data-tagfocus="' + escAttr(key) + ':' + escAttr(e.val) + '">' +
        '<td>' + escHtml(e.val) + '</td>' +
        '<td class="num">' + fmtMs(e.weight) + 'ms</td>' +
        '<td class="num">' + fmtPct(e.weight, total) + '%</td>' +
        '<td><span class="tag-bar" style="width:' + barW + 'px"></span></td>' +
        '</tr>';
    });
    if (untagged > 0) {
      html += '<tr style="color:#666"><td>(untagged)</td>' +
        '<td class="num">' + fmtMs(untagged) + 'ms</td>' +
        '<td class="num">' + fmtPct(untagged, total) + '%</td>' +
        '<td></td></tr>';
    }
    html += '</tbody></table></div>';
  });

  el.innerHTML = html;

  // Click on a tag value row -> set tagfocus and switch to flamegraph
  el.querySelectorAll("tr[data-tagfocus]").forEach(function(tr) {
    tr.addEventListener("click", function() {
      var parts = tr.getAttribute("data-tagfocus").split(":");
      var val = parts.slice(1).join(":");
      document.getElementById("in-tagfocus").value = "^" + escRegex(val) + "$";
      switchTab("flamegraph");
      applyAndRender();
    });
  });
}

function escAttr(s) { return s.replace(/&/g,"&amp;").replace(/"/g,"&quot;").replace(/</g,"&lt;"); }
function escRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

// ==================== Tab switching ====================

function switchTab(name) {
  currentTab = name;
  document.querySelectorAll(".tab").forEach(function(t) {
    t.classList.toggle("active", t.getAttribute("data-tab") === name);
  });
  document.querySelectorAll(".tab-content").forEach(function(c) {
    c.classList.toggle("active", c.id === "panel-" + name);
  });
  renderCurrentTab();
}

// ==================== Events ====================

document.getElementById("sel-snapshot").addEventListener("change", function(e) {
  if (e.target.value) loadSnapshot(e.target.value);
});

// Dropdown toggles for tagignore, tagroot, tagleaf
["tagignore", "tagroot", "tagleaf"].forEach(function(name) {
  document.getElementById("btn-" + name).addEventListener("click", function(e) {
    e.stopPropagation();
    // Close other dropdowns first
    ["tagignore", "tagroot", "tagleaf"].forEach(function(other) {
      if (other !== name) document.getElementById("cb-" + other).classList.remove("open");
    });
    document.getElementById("cb-" + name).classList.toggle("open");
  });
});
document.addEventListener("click", function(e) {
  ["tagignore", "tagroot", "tagleaf"].forEach(function(name) {
    var list = document.getElementById("cb-" + name);
    if (!list.contains(e.target) && e.target.id !== "btn-" + name) {
      list.classList.remove("open");
    }
  });
});

document.querySelectorAll(".tab").forEach(function(t) {
  t.addEventListener("click", function() { switchTab(t.getAttribute("data-tab")); });
});

var inputs = document.querySelectorAll(".controls input[type=text]");
for (var i = 0; i < inputs.length; i++) {
  inputs[i].addEventListener("keydown", function(e) {
    if (e.key === "Enter") applyAndRender();
  });
}

// --- Init ---
loadSnapshotList();
</script>
</body>
</html>
  HTML
end
