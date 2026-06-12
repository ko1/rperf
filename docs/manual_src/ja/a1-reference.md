# クイックリファレンス

## CLI チートシート

```bash
# 性能の概要を表示
rperf stat ruby my_app.rb

# プロファイルテーブル付きの性能概要
rperf stat --report ruby my_app.rb

# 完全な性能レポート（stat --report と同等）
rperf exec ruby my_app.rb

# デフォルトファイルに記録（rperf.json.gz、json 形式、cpu モード）
rperf record ruby my_app.rb

# オプション付きで記録
rperf record -m wall -f 500 -o profile.pb.gz ruby my_app.rb

# テキストプロファイルを stdout に出力して記録
rperf record -p ruby my_app.rb

# テキスト形式で記録
rperf record -o profile.txt ruby my_app.rb

# collapsed stacks で記録
rperf record -o profile.collapsed ruby my_app.rb

# プリフォーキングサーバーの全ワーカーをプロファイル
rperf stat -m wall bundle exec unicorn

# 子プロセストラッキングを無効化
rperf stat --no-inherit ruby my_app.rb

# rperf ビューアでプロファイルを表示
rperf report

# 上位の関数を出力
rperf report --top profile.pb.gz

# 2 つのプロファイルを比較
rperf diff before.pb.gz after.pb.gz

# 完全なドキュメント
rperf help
```

## Ruby API チートシート

```ruby
require "rperf"

# ブロック形式
data = Rperf.start(output: "profile.pb.gz", mode: :cpu) do
  # プロファイルしたいコード
end

# 手動形式
Rperf.start(frequency: 1000, mode: :wall)
# ...
data = Rperf.stop

# ファイルに保存
Rperf.save("profile.pb.gz", data)
Rperf.save("profile.collapsed", data)
Rperf.save("profile.txt", data)

# スナップショット（停止せずにデータを取得）
snap = Rperf.snapshot
Rperf.save("snap.pb.gz", snap)
snap = Rperf.snapshot(clear: true)  # スナップショット後にリセット

# 遅延開始 + 対象を絞ったプロファイリング
Rperf.start(defer: true, mode: :wall)
Rperf.profile(endpoint: "/users") do
  # このブロックのみサンプリングされる
end
data = Rperf.stop

# ラベル（サンプルにコンテキストを付与）
Rperf.label(request: "abc") do
  # 内部のサンプルに request="abc" ラベルが付く
end
Rperf.labels       # 現在のラベルを取得

# Rack ミドルウェア（エンドポイントでリクエストにラベル付け）
require "rperf/rack"
use Rperf::RackMiddleware                    # Rails: config.middleware.use Rperf::RackMiddleware
use Rperf::RackMiddleware, label_key: :route # カスタムラベルキー

# Active Job（クラス名でジョブにラベル付け）
require "rperf/active_job"
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end

# Sidekiq（ワーカークラス名でジョブにラベル付け）
require "rperf/sidekiq"
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

## 環境変数

これらは CLI がオートスタートプロファイラを設定するために内部的に使用します:

| 変数 | 値 | 説明 |
|----------|--------|-------------|
| `RPERF_ENABLED` | `1` | require 時にオートスタート |
| `RPERF_OUTPUT` | path | 出力ファイルパス |
| `RPERF_FREQUENCY` | integer | サンプリング周波数 (Hz) |
| `RPERF_MODE` | `cpu`, `wall` | プロファイリングモード |
| `RPERF_FORMAT` | `json`, `pprof`, `collapsed`, `text` | 出力形式 |
| `RPERF_VERBOSE` | `1` | 統計を stderr に出力 |
| `RPERF_STAT` | `1` | stat モード出力を有効化 |
| `RPERF_STAT_REPORT` | `1` | stat 出力にプロファイルテーブルを含める |
| `RPERF_STAT_COMMAND` | string | stat 出力ヘッダーに表示するコマンド文字列 |
| `RPERF_AGGREGATE` | `0` | サンプル集約を無効化（生サンプルを返す） |
| `RPERF_SIGNAL` | integer または `false` | タイマーシグナル (Linux のみ): シグナル番号、または `false` で nanosleep スレッド |
| `RPERF_DEFER` | `1` | タイマーを停止状態で開始; `Rperf.profile` で有効化 |
| `RPERF_ROOT_PROCESS` | PID 文字列 | マルチプロセスセッションのルートプロセス PID (CLI が設定) |
| `RPERF_SESSION_DIR` | パス | マルチプロセスプロファイル収集用セッションディレクトリ (CLI が設定) |
| `RPERF_TMPDIR` | パス | セッションディレクトリのベースディレクトリを上書き (デフォルト: `$XDG_RUNTIME_DIR` またはシステム tmpdir) |

## プロファイリングモードの比較

| 項目 | cpu | wall |
|--------|-----|------|
| クロック | `CLOCK_THREAD_CPUTIME_ID` | `CLOCK_MONOTONIC` |
| I/O 時間 | 計測されない | `%GVL=blocked` ラベル |
| Sleep 時間 | 計測されない | `%GVL=blocked` ラベル |
| GVL 競合 | 計測されない | `%GVL=wait` ラベル |
| GC 時間 | `%GC=mark`, `%GC=sweep` ラベル | `%GC=mark`, `%GC=sweep` ラベル |
| 適したケース | CPU ホットスポット | レイテンシ分析 |

## 出力形式の比較

| 拡張子 | 形式 | 必要なツール |
|-----------|--------|-----------------|
| `.json.gz` (デフォルト) | JSON (rperf 独自形式) | なし (`rperf report`) |
| `.pb.gz` | pprof protobuf | Go (`rperf report`) |
| `.collapsed` | Collapsed stacks | flamegraph.pl or speedscope |
| `.txt` | テキストレポート | なし |

## VM 状態ラベル

| ラベル | 値 | モード | 意味 |
|-------|-------|------|---------|
| `%GVL` | `blocked` | wall | スレッドが GVL 外（I/O, sleep, C 拡張） |
| `%GVL` | `wait` | wall | スレッドが GVL 待ち（競合） |
| `%GC` | `mark` | 両方 | GC marking フェーズ（wall time） |
| `%GC` | `sweep` | 両方 | GC sweeping フェーズ（wall time） |
| `%pid` | PID 文字列 | 両方 | 子プロセスのプロセス ID（マルチプロセスモードのみ） |

これらはユーザーラベルと同様にサンプルのラベルとして付与されます。pprof で `-tagfocus=%GVL=blocked`、`-tagroot=%GC`、`-tagfocus=%pid=1234` のようにフィルタリングできます。
