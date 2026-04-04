# CLI の使い方

rperf は perf ライクなコマンドラインインターフェースを提供し、5 つの主要サブコマンドがあります: `record`、`stat`、`exec`、`report`、`diff`。

## rperf stat

[`rperf stat`](#index:rperf stat) は性能の概要を最も手軽に確認する方法です。コマンドを [wall](#index:wall mode) モードのプロファイリングで実行し、サマリーを stderr に出力します。

```bash
rperf stat ruby my_app.rb
```

### 例: CPU バウンドなプログラム

シンプルなフィボナッチ計算:

```ruby
# fib.rb
def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end
fib(35)
```

`rperf stat` の実行:

```bash
rperf stat ruby fib.rb
```

```
 Performance stats for 'ruby fib.rb':

           744.4 ms   user
            32.0 ms   sys
           491.0 ms   real

           481.0 ms 100.0%  [Rperf] CPU execution
            12.0 ms         [Ruby ] GC time (9 count: 6 minor, 3 major)
         154,468            [Ruby ] allocated objects
          66,596            [Ruby ] freed objects
              25 MB         [OS   ] peak memory (maxrss)
              31            [OS   ] context switches (10 voluntary, 21 involuntary)
               0 MB         [OS   ] disk I/O (0 MB read, 0 MB write)

  481 samples / 481 triggers, 0.1% profiler overhead
```

出力の意味:

- **user/sys/real**: 標準的な時間計測（`time` コマンドと同様）
- **時間の内訳**: `[Rperf]` プレフィックスの行はサンプリングから導出された時間内訳を示します — CPU 実行、GVL ブロック（I/O/sleep）、GVL 待ち（競合）、GC marking、GC sweeping
- **Ruby の統計**: `[Ruby ]` プレフィックスの行は Ruby ランタイム情報を示します — GC 回数、割り当て済み/解放済みオブジェクト、YJIT 比率（有効な場合）
- **OS の統計**: `[OS   ]` プレフィックスの行は OS レベルの統計を示します — ピークメモリ、コンテキストスイッチ、ディスク I/O

`--report` を使用すると、フラットおよびキュムレイティブな上位 50 関数テーブルが出力に追加されます。

### 例: CPU と I/O の混合

```ruby
# mixed.rb
def cpu_work(n)
  sum = 0
  n.times { |i| sum += i * i }
  sum
end

def io_work
  sleep(0.05)
end

5.times do
  cpu_work(500_000)
  io_work
end
```

`rperf stat` の実行:

```bash
rperf stat ruby mixed.rb
```

`stat` は常に wall モードを使用するため、CPU と I/O の間の時間配分が確認できます。`[Rperf] GVL blocked` の行は sleep/I/O に費やされた時間を示し、`CPU execution` は計算時間を示します。

### stat のオプション

```bash
rperf stat [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | プロファイルをファイルにも保存 (デフォルト: なし) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `wall`) |
| `--report` | フラット/キュムレイティブなプロファイルテーブルを出力に含める |
| `--signal VALUE` | タイマーシグナル (Linux のみ): シグナル番号、または `false` で nanosleep スレッド |
| `--no-aggregate` | サンプル集約を無効化（生サンプルを保持） |
| `--no-inherit` | fork/spawn した子プロセスをプロファイルしない (デフォルト: inherit) |
| `-v` | 追加のサンプリング統計を出力 |

## rperf exec

[`rperf exec`](#index:rperf exec) はコマンドをプロファイリング付きで実行し、完全な性能レポートを stderr に出力します。`rperf stat --report` と同等です。デフォルトで [wall](#index:wall mode) モードを使用し、ファイルには保存しません。

```bash
rperf exec ruby my_app.rb
```

`stat` が表示するすべて（時間計測、時間内訳、GC/メモリ/OS 統計）に加えて、フラットおよびキュムレイティブな上位 50 関数テーブルが出力されます。

### exec のオプション

```bash
rperf exec [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | プロファイルをファイルにも保存 (デフォルト: なし) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `wall`) |
| `--signal VALUE` | タイマーシグナル (Linux のみ): シグナル番号、または `false` で nanosleep スレッド |
| `--no-aggregate` | サンプル集約を無効化（生サンプルを保持） |
| `--no-inherit` | fork/spawn した子プロセスをプロファイルしない (デフォルト: inherit) |
| `-v` | 追加のサンプリング統計を出力 |

## rperf record

[`rperf record`](#index:rperf record) はコマンドをプロファイルし、結果をファイルに保存します。詳細な分析のためにプロファイルをキャプチャする主要な方法です。

```bash
rperf record ruby my_app.rb
```

デフォルトでは、CPU モードの JSON 形式で `rperf.json.gz` に保存します。

### 例: プロファイルの記録

```bash
rperf record ruby fib.rb
```

これにより `rperf.json.gz` が作成されます。その後 `rperf report` で分析したり、他の形式に変換したりできます。

### プロファイリングモードの選択

rperf は 2 つのプロファイリングモードをサポートしています:

- **[cpu](#index:cpu mode)** (デフォルト): スレッドごとの CPU 時間を計測します。CPU サイクルを消費する関数を見つけるのに最適です。sleep、I/O、GVL 待ちの時間は無視されます。
- **[wall](#index:wall mode)**: ウォールクロック時間を計測します。I/O、sleep、GVL 競合を含む、wall time の使われ方を見つけるのに最適です。

```bash
# CPU モード (デフォルト)
rperf record ruby my_app.rb

# wall モード
rperf record -m wall ruby my_app.rb
```

### 出力形式の選択

rperf はファイル拡張子から形式を自動検出します:

```bash
# JSON 形式 (デフォルト)
rperf record -o profile.json.gz ruby my_app.rb

# pprof 形式
rperf record -o profile.pb.gz ruby my_app.rb

# collapsed stacks (FlameGraph / speedscope 向け)
rperf record -o profile.collapsed ruby my_app.rb

# 人間が読めるテキスト
rperf record -o profile.txt ruby my_app.rb
```

形式を明示的に指定することもできます:

```bash
rperf record --format text -o profile.dat ruby my_app.rb
```

### 例: テキスト出力

```bash
rperf record -o profile.txt ruby fib.rb
```

テキスト出力は以下のようになります:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

### 例: wall モードのテキスト出力

```bash
rperf record -m wall -o wall_profile.txt ruby mixed.rb
```

```
Total: 311.8ms (wall)
Samples: 80, Frequency: 1000Hz

 Flat:
            44.1 ms  14.1%  Object#cpu_work (mixed.rb)
            13.9 ms   4.5%  Integer#times (<internal:numeric>)
             3.2 ms   1.0%  Kernel#sleep (<C method>)

 Cumulative:
           311.8 ms 100.0%  Integer#times (<internal:numeric>)
           311.8 ms 100.0%  block in <main> (mixed.rb)
           311.8 ms 100.0%  <main> (mixed.rb)
           253.8 ms  81.4%  Kernel#sleep (<C method>)
           253.8 ms  81.4%  Object#io_work (mixed.rb)
            58.0 ms  18.6%  Object#cpu_work (mixed.rb)

 Labels:
           250.6 ms  80.4%  %GVL: blocked
             0.0 ms   0.0%  %GVL: wait
```

wall モードでは、`%GVL: blocked` ラベルが支配的なコストを示しています -- これは `io_work` の sleep 時間です。`cpu_work` の CPU 時間は明確に分離されています。GVL や GC のアクティビティはスタックフレームではなくサンプルのラベルとして記録され、pprof の `-tagfocus` フラグ（例: `-tagfocus=%GVL=blocked`）でフィルタリングできます。

### Verbose 出力

`-v` フラグはプロファイリング中にサンプリング統計を stderr に出力します:

```bash
rperf record -v ruby my_app.rb
```

```
[Rperf] mode=cpu frequency=1000Hz
[Rperf] sampling: 98 calls, 0.11ms total, 1.1us/call avg
[Rperf] samples recorded: 904
[Rperf] top 10 by flat:
[Rperf]       53.4ms  50.1%  Object#cpu_work (-e)
[Rperf]       17.0ms  15.9%  Integer#times (<internal:numeric>)
...
```

### record のオプション

```bash
rperf record [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | 出力ファイル (デフォルト: `rperf.json.gz`) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `cpu`) |
| `--format FMT` | `json`、`pprof`、`collapsed`、または `text` (デフォルト: 拡張子から自動検出) |
| `-p, --print` | テキストプロファイルを stdout に出力 (`--format=text --output=/dev/stdout` と同等) |
| `--signal VALUE` | タイマーシグナル (Linux のみ): シグナル番号、または `false` で nanosleep スレッド |
| `--no-aggregate` | サンプル集約を無効化（生サンプルを保持） |
| `-v` | サンプリング統計を stderr に出力 |

## rperf report

[`rperf report`](#index:rperf report) はプロファイルを分析用に開きます。JSON 形式 (`.json.gz`) のファイルには rperf の組み込みビューアを使用し（Go 不要）、pprof 形式 (`.pb.gz`) のファイルには `go tool pprof` を使用します（Go が必要）。

```bash
# インタラクティブな Web UI を開く (デフォルト)
rperf report

# 特定のファイルを開く
rperf report profile.json.gz

# 上位の関数を出力
rperf report --top

# pprof テキストサマリーを出力
rperf report --text

# 静的 HTML ビューアを出力（サーバー不要）
rperf report --html profile.json.gz > report.html
```

`--html` フラグはプロファイルデータをインラインで埋め込んだ単一の HTML ファイルを生成します。d3 と d3-flamegraph は CDN から読み込むため、表示にはインターネット接続が必要ですが、サーバーは不要です。プロファイルの共有や GitHub Pages などの静的サイトでのホスティングに便利です。

### 例: top とテキスト出力

先ほど記録した `fib.rb` のプロファイルを使用:

```bash
rperf report --top rperf.json.gz
```

```
 Flat:
        577.3 ms 100.0%  Object#fib (fib.rb)
          0.0 ms   0.0%  <main> (-e)

 Cumulative:
        577.3 ms 100.0%  Object#fib (fib.rb)
        577.3 ms 100.0%  <main> (-e)
```

`.pb.gz` ファイルの場合、`--top` と `--text` は `go tool pprof` を使用し、pprof 形式の出力を生成します。

デフォルト動作（`--top` や `--text` なし）では、フレームグラフ、上位関数ビュー、コールグラフの可視化を備えたインタラクティブな Web UI がブラウザで開きます。JSON 形式では rperf 組み込みビューア、pprof 形式では [pprof](#cite:ren2010) を利用します。

### report のオプション

| オプション | 説明 |
|--------|-------------|
| `--top` | フラットタイムによる上位の関数を出力 |
| `--text` | pprof テキストサマリーを出力 |
| (デフォルト) | ブラウザでインタラクティブな Web UI を開く |

## rperf diff

[`rperf diff`](#index:rperf diff) は 2 つの pprof プロファイルを比較し、差分（target - base）を表示します。最適化の効果を測定するのに便利です。

```bash
# ブラウザで差分を開く
rperf diff before.pb.gz after.pb.gz

# 差分による上位の関数を出力
rperf diff --top before.pb.gz after.pb.gz

# テキスト差分を出力
rperf diff --text before.pb.gz after.pb.gz
```

### ワークフロー例

```bash
# ベースラインをプロファイル
rperf record -o before.pb.gz ruby my_app.rb

# 最適化を実施...

# 再度プロファイル
rperf record -o after.pb.gz ruby my_app.rb

# 比較
rperf diff before.pb.gz after.pb.gz
```

## マルチプロセス プロファイリング

デフォルトで、すべての CLI サブコマンド（`stat`、`exec`、`record`）は fork や spawn された Ruby 子プロセスも自動的にプロファイルします。全プロセスのプロファイルが 1 つの出力にマージされます。stat レポートには集約データが表示され、`record` は単一のマージ済みファイルを生成します。

これは Unicorn や Puma のような[プリフォーキングサーバー](#index:preforking server)で特に有用です:

```bash
# Unicorn サーバーの全ワーカーをプロファイル
rperf stat -m wall bundle exec unicorn -c config.rb

# Puma サーバーのマージ済みプロファイルを記録
rperf record -m wall -o profile.json.gz bundle exec puma
```

### 仕組み

子プロセストラッキングが有効な場合（デフォルト）、rperf は:

1. プロセスごとのプロファイルを収集するためのセッションディレクトリを設定
2. fork された子プロセスでプロファイリングを再開する `Process._fork` フックをインストール
3. spawn された Ruby 子プロセス（`spawn`、`system`、バッククォート経由）は `RUBYOPT=-rrperf` を継承して自動的にプロファイリングを開始
4. 各子プロセスが終了時にプロファイルをセッションディレクトリに書き込み
5. ルートプロセスが全プロファイルを集約して最終出力を生成

各子プロセスのサンプルにはプロセス ID を含む [`%pid`](#index:%pid label) ラベルが付与されます。ビューアーで PID によるフィルタリング（tagfocus）や pprof での `-tagfocus=%pid=1234` が可能です。

### 子プロセストラッキングの無効化

`--no-inherit` でルートプロセスのみをプロファイルします:

```bash
rperf stat --no-inherit ruby my_app.rb
```

### 例: fork で異なる処理を実行

```bash
rperf stat ruby -e '
  def parent_work = 10_000_000.times { 1 + 1 }
  def child_work  = 10_000_000.times { 1 + 1 }
  fork { child_work }
  Process.waitall
  parent_work
'
```

stat 出力には両プロセスの集約データが表示され、「Ruby processes profiled」のカウントが含まれます:

```
               2            [Rperf] Ruby processes profiled
```

### 制限事項

- **デーモン化した子プロセス**: `Process.daemon` を呼び出して親より長く生きるプロセスのプロファイルは失われます。親が終了時にセッションディレクトリを集約・削除するためです。
- **クロスプロセス スナップショット**: `Rperf.snapshot` は現在のプロセスのみを対象とします。全子プロセスを同時にスナップショットする方法はありません。
- **非 Ruby 子プロセス**: Ruby 子プロセスのみがプロファイルされます。シェルスクリプトや Python プロセスなどは影響を受けません。
- **独立した rperf 利用者**: 子プロセスが独自に rperf を使用する場合（自身のコードで `Rperf.start`）、継承されたオートスタートセッションと競合します。そのようなプログラムは rperf を require する前に `RPERF_ENABLED` を環境変数から削除する必要があります。

## rperf help

`rperf help` はプロファイリングモード、出力形式、VM 状態ラベル、診断のヒントを含む完全なリファレンスドキュメントを出力します。

```bash
rperf help
```

人間が読むのにも AI による分析にも適した詳細なドキュメントが出力されます。
