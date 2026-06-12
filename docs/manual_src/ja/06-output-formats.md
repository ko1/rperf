# 出力形式

rperf は 4 つの出力形式をサポートしています。形式はファイル拡張子から自動検出されるか、`--format` フラグ（CLI）または `format:` パラメータ（API）で明示的に設定できます。

## JSON (デフォルト)

[JSON](#index:json) 形式は rperf のネイティブ形式で、デフォルトの出力形式です。2 つのバリエーションがあります:

- **`.json.gz`**（デフォルト）— gzip 圧縮 JSON。コンパクトで、保存・共有に推奨。
- **`.json`** — プレーンテキスト JSON。`jq`、テキストエディタ、その他の JSON ツールで展開なしに読める。

両方のバリエーションは `Rperf.load` と `rperf report` で自動検出されます。

**表示方法**:

```bash
# rperf ビューアで開く
rperf report profile.json.gz
rperf report profile.json      # こちらも動作
```

**Ruby でロード**:

```ruby
data = Rperf.load("profile.json.gz")  # gzip
data = Rperf.load("profile.json")     # プレーンテキスト
```

**利点**: rperf のネイティブ形式。表示に外部ツール不要。ポータブルな形式。Ruby にロードし直したり、JSON 対応の任意のツールで処理可能。`jq` でパイプ処理したい場合は `.json` を使用。

### メタデータと要約統計 (meta / summary)

JSON プロファイルのトップレベルには [`meta`](#index:meta) と [`summary`](#index:summary) が埋め込まれます:

```json
{
  "meta": {
    "format_version": 1,
    "created_at": "2026-06-12T10:00:00Z",
    "ruby_version": "3.5.0",
    "rperf_version": "0.10.0",
    "mode": "cpu",
    "hostname": "...",
    "git": { "sha": "88e1a40...", "branch": "main",
             "subject": "Add nested includes support",
             "committed_at": "2026-06-09T...", "dirty": false },
    "labels": { "ci": "github-actions", "pr": "123" }
  },
  "summary": {
    "total_ms": 2001.8, "cpu_ms": 2023.3,
    "gc_count_minor": 2, "gc_count_major": 2, "gc_ms": 3.0,
    "allocated_objects": 48741, "freed_objects": 27034,
    "maxrss_mb": 16, "samples": 1999,
    "top_methods": [ { "name": "Object#fibonacci", "self_pct": 99.9, "total_pct": 99.9 } ]
  }
}
```

設計上のポイント:

- `meta` / `summary` はファイルの**先頭**に書かれるため、`Rperf.read_meta(path)` は gzip の先頭部分だけを伸長して読み取れます。時間旅行ビューアの一覧表示が本体のロードなしで成立するのはこのためです。
- git 情報は git リポジトリ外では省略されます（エラーにはなりません）。GitHub Actions 環境では `GITHUB_SHA` などが git コマンドより優先されます。
- GC 回数とアロケーション数はプロファイル期間中の差分です。`maxrss_mb` はプロセス起動からのピーク値です。
- `meta` のない旧バージョンのファイルも従来どおり読み込めます。
- pprof / collapsed / text 形式には `meta` は反映されません。

## pprof

[pprof](#index:pprof) 形式は gzip 圧縮された Protocol Buffers バイナリです。これは Go の pprof ツールで使用される標準形式です。

**拡張子の規約**: `.pb.gz`

**表示方法**:

```bash
# インタラクティブな Web UI（Go が必要）
rperf report profile.pb.gz

# 上位の関数
rperf report --top profile.pb.gz

# テキストレポート
rperf report --text profile.pb.gz

# go tool pprof を直接使用する場合
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
```

[speedscope](https://www.speedscope.app/) の Web インターフェースから pprof ファイルをインポートすることもできます。

**利点**: 幅広いツールエコシステムでサポートされている標準形式。2 つのプロファイル間の差分比較が可能。フレームグラフ、コールグラフ、ソースアノテーション付きのインタラクティブな探索。

### 埋め込みメタデータ

rperf は各 pprof プロファイルに以下のメタデータを埋め込みます:

| フィールド | 説明 |
|-------|-------------|
| `comment` | rperf バージョン、プロファイリングモード、周波数、Ruby バージョン |
| `time_nanos` | プロファイル収集開始時刻（エポックナノ秒） |
| `duration_nanos` | プロファイル期間（ナノ秒） |
| `doc_url` | rperf ドキュメントへのリンク |

コメントの表示: `go tool pprof -comments profile.pb.gz`

### サンプルラベル

各サンプルには `thread_seq` 数値ラベルが付きます。これはプロファイリングセッション中に rperf が各スレッドを初めて検出したときに割り当てられるスレッド連番（1 始まり）です。[`Rperf.label`](#index:Rperf.label) を使用すると、カスタムのキーバリュー文字列ラベルもサンプルに付与されます。

`go tool pprof` でこれらのラベルをフィルタリングできます:

```bash
go tool pprof -tagroot=thread_seq profile.pb.gz     # スレッドごとにグループ化
go tool pprof -tagfocus=request=abc-123 profile.pb.gz  # ラベルでフィルタ
go tool pprof -tagroot=request profile.pb.gz         # ラベルでグループ化
```

> [!NOTE]
> rperf ビューア（JSON 形式）は Go 不要で同じタグ操作（tagfocus、tagignore、tagroot、tagleaf）をサポートしています。詳細は[ブラウザ内ビューア](#index:Rperf::Viewer)を参照してください。

## Collapsed stacks

[collapsed stacks](#index:collapsed stacks) 形式は、ユニークなスタックトレースごとに 1 行のプレーンテキスト形式です。各行にはセミコロン区切りのスタック（ボトムからトップ）の後にスペースとナノ秒単位の重みが続きます。

**拡張子の規約**: `.collapsed`

**形式**:

```
bottom_frame;...;top_frame weight_ns
```

**出力例**:

```
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times;Object#cpu_work 53419170
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times 16962309
<main>;Integer#times;block in <main>;Object#io_work;Kernel#sleep 2335151
```

**使用方法**:

```bash
# FlameGraph SVG を生成
rperf record -o profile.collapsed ruby my_app.rb
flamegraph.pl profile.collapsed > flamegraph.svg

# speedscope で開く（.collapsed ファイルをドラッグ＆ドロップ）
# macOS: open https://www.speedscope.app/
# Linux: xdg-open https://www.speedscope.app/
```

**利点**: シンプルなテキスト形式で、コマンドラインツールで処理しやすい。Brendan Gregg の [FlameGraph](#cite:gregg2016) ツールや speedscope と互換性があります。

### collapsed stacks のプログラマティックなパース

```ruby
File.readlines("profile.collapsed").each do |line|
  stack, weight = line.rpartition(" ").then { |s, _, w| [s, w.to_i] }
  frames = stack.split(";")
  # frames[0] がボトム（main）、frames[-1] がリーフ（ホット）
  puts "#{frames.last}: #{weight / 1_000_000.0}ms"
end
```

## テキストレポート

テキスト形式は、フラットおよびキュムレイティブな上位 N テーブルを含む人間が読める（AI にも読める）レポートです。

**拡張子の規約**: `.txt`

**出力例**:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

**セクション**:

- **ヘッダー**: プロファイルされた合計時間、サンプル数、周波数
- **フラットテーブル**: セルフタイム（関数がリーフ/最深部フレームだった時間）でソートされた関数
- **キュムレイティブテーブル**: トータルタイム（関数がスタックのどこかに出現した時間）でソートされた関数

**利点**: ツール不要 — `cat` で読める。テーブルごとにデフォルトで上位 50 エントリ。クイック分析、イシューレポートでの共有、AI アシスタントへの入力に適しています。

## 形式の比較

| 機能 | json | pprof | collapsed | text |
|---------|------|-------|-----------|------|
| ファイルサイズ | 中 (json + gzip) | 小 (バイナリ + gzip) | 中 (テキスト) | 小 (テキスト) |
| フレームグラフ | あり (rperf ビューア) | あり (pprof Web UI) | あり (flamegraph.pl) | なし |
| コールグラフ | なし | あり | なし | なし |
| 差分比較 | あり (`rperf diff` — `--format table`/`table-json` は Ruby 内で計算、Go 不要。pprof ベースの diff モードは Go 必要) | あり (`rperf diff`、Go 必要) | なし | なし |
| ツール不要 | はい | いいえ (Go 必要) | いいえ (flamegraph.pl 必要) | はい |
| Ruby にロード | あり (`Rperf.load`) | なし | なし | なし |
| プログラマティックなパース | 容易 (JSON) | 複雑 (protobuf) | シンプル | シンプル |
| AI フレンドリー | はい | いいえ | はい | はい |

## 自動検出ルール

| ファイル拡張子 | 形式 |
|----------------|--------|
| `.json.gz` | JSON (デフォルト) |
| `.json` | JSON (プレーンテキスト) |
| `.pb.gz` | pprof |
| `.collapsed` | Collapsed stacks |
| `.txt` | テキストレポート |
| (その他) | pprof |

認識されない拡張子はすべて pprof になります。デフォルトの出力ファイル（`rperf.json.gz`）は JSON 形式を使用します。
