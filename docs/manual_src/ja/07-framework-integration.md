# フレームワーク統合

rperf は、Web フレームワークやジョブプロセッサからのコンテキストで自動的にプロファイルおよびラベル付けするオプションの統合機能を提供します。これらは [`Rperf.profile`](#index:Rperf.profile) を使用し、タイマーの有効化とラベルの設定を同時に行います。`start(defer: true)` とシームレスに連携し、ミドルウェアを通過するリクエスト/ジョブのみがサンプリングされます。プロファイリングの開始は別途行ってください（例: イニシャライザで）。

## Rack ミドルウェア

`Rperf::RackMiddleware` は各リクエストをプロファイルし、エンドポイント（`METHOD /path`）でラベル付けします。

```ruby
require "rperf/rack"
```

### Rails

```ruby
# config/initializers/rperf.rb
require "rperf/rack"

Rperf.start(defer: true, mode: :wall, frequency: 99)

Rails.application.config.middleware.use Rperf::RackMiddleware

at_exit do
  data = Rperf.stop
  Rperf.save("tmp/profile.pb.gz", data) if data
end
```

その後、エンドポイントでプロファイルをフィルタリング:

```bash
go tool pprof -tagfocus=endpoint="GET /api/users" tmp/profile.pb.gz
go tool pprof -tagroot=endpoint tmp/profile.pb.gz   # エンドポイントごとにグループ化
```

### Sinatra

```ruby
require "sinatra"
require "rperf/rack"

Rperf.start(defer: true, mode: :wall, frequency: 99)
use Rperf::RackMiddleware

at_exit do
  data = Rperf.stop
  Rperf.save("profile.pb.gz", data) if data
end

get "/hello" do
  "Hello, world!"
end
```

### ラベルキーのカスタマイズ

デフォルトではミドルウェアはラベルキー `:endpoint` を使用します。変更できます:

```ruby
use Rperf::RackMiddleware, label_key: :route
```

## Active Job

`Rperf::ActiveJobMiddleware` は各ジョブをプロファイルし、クラス名（例: `SendEmailJob`）でラベル付けします。任意の Active Job バックエンド（Sidekiq、GoodJob、Solid Queue など）で動作します。

```ruby
require "rperf/active_job"
```

イニシャライザでプロファイリングを開始し、ベースジョブクラスにインクルードします:

```ruby
# config/initializers/rperf.rb
Rperf.start(defer: true, mode: :wall, frequency: 99)
```

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end
```

すべてのサブクラスが自動的にラベルを継承します:

```ruby
class SendEmailJob < ApplicationJob
  def perform(user)
    # ここのサンプルに job="SendEmailJob" が付く
  end
end
```

ジョブでフィルタリング:

```bash
go tool pprof -tagfocus=job=SendEmailJob profile.pb.gz
go tool pprof -tagroot=job profile.pb.gz   # ジョブクラスごとにグループ化
```

## Sidekiq

`Rperf::SidekiqMiddleware` は各ジョブをプロファイルし、ワーカークラス名でラベル付けします。Active Job ベースのワーカーとプレーンな Sidekiq ワーカーの両方をカバーします。

```ruby
require "rperf/sidekiq"
```

Sidekiq のサーバーミドルウェアとして登録します:

```ruby
# config/initializers/sidekiq.rb
Rperf.start(defer: true, mode: :wall, frequency: 99)

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

> [!NOTE]
> Active Job と Sidekiq を併用する場合は、どちらか一方を選んでください。両方を使用するとラベルが重複します。Sidekiq ミドルウェアの方がより汎用的です（非 Active Job ワーカーもカバー）。

## ブラウザ内ビューア

`Rperf::Viewer` は、設定可能なマウントパスでインタラクティブなプロファイリング UI を提供する Rack ミドルウェアです。スナップショットをメモリに保持し、[d3-flame-graph](https://github.com/nicedoc/d3-flame-graph) を使ってブラウザ内で描画します。gem の依存やビルドツールは不要です。ビューアは実行時に CDN から [d3-flame-graph](https://github.com/nicedoc/d3-flame-graph) を読み込むため、初回アクセス時にインターネット接続が必要です。

```ruby
require "rperf/viewer"
```

### セットアップ

```ruby
# config.ru（または Rails イニシャライザ）
require "rperf/viewer"
require "rperf/rack"

Rperf.start(defer: true, mode: :wall, frequency: 999)

use Rperf::Viewer                           # /rperf/ で UI を提供
use Rperf::RackMiddleware                   # 各リクエストにラベルを付与
run MyApp

# 60分ごとにスナップショットを取得
Thread.new do
  loop do
    sleep 60 * 60
    Rperf::Viewer.instance&.take_snapshot!
  end
end
```

スナップショットが取得された後、ブラウザで `/rperf/` にアクセスしてください。

### オプション

| オプション | デフォルト | 説明 |
|-----------|----------|------|
| `path:` | `"/rperf"` | ビューアの URL プレフィックス |
| `max_snapshots:` | `24` | メモリに保持するスナップショットの最大数（古いものから破棄） |

### スナップショットの取得

```ruby
# プログラムから（コントローラ、バックグラウンドスレッド、コンソール等）
Rperf::Viewer.instance.take_snapshot!

# または事前に取得したデータを追加
data = Rperf.snapshot(clear: true)
Rperf::Viewer.instance.add_snapshot(data)
```

### UI タブ

ビューアには 3 つのタブがあります:

- **Flamegraph** — d3-flame-graph によるインタラクティブなフレームグラフ。フレームをクリックでズームイン、ルートをクリックでズームアウト。
- **Top** — Flat（リーフ）と Cumulative（累積）の重み付けテーブル（上位 50 関数）。カラムヘッダー（Flat、Cum、Function）をクリックでソート。
- **Tags** — 各ラベルキーについて、値ごとの重みとパーセンテージの内訳を表示。値の行をクリックすると tagfocus を設定して Flamegraph タブに遷移。

### フィルタリング

上部のコントロールバーに 4 つのフィルタがあります:

- **tagfocus** — テキスト入力。ラベル値にマッチする正規表現を入力。Enter で適用。
- **tagignore** — ドロップダウン + チェックボックス。チェックした項目に一致するサンプルを除外。各ラベルキーには `(none)` エントリがあり、そのキーを持たないサンプルを除外できます — `endpoint` ラベルのないバックグラウンドスレッドを除外する際に便利です。
- **tagroot** — ラベルキーのドロップダウン + チェックボックス。チェックしたキーがフレームグラフのルートフレームとして先頭に追加されます（例: `[endpoint: GET /users]`）。
- **tagleaf** — tagroot と同様ですが、リーフフレームとして末尾に追加されます。

ラベルキーはアルファベット順にソートされます。`%` プレフィックスの VM 状態キー（`%GC`、`%GVL`）が先頭に来るため、GC や GVL の状態を leaf/root フレームとして追加しやすくなっています。

### アクセス制御

`Rperf::Viewer` には組み込みの認証機能はありません。フレームワークの既存の仕組みでアクセスを制限してください:

```ruby
# Rails: ルート制約（管理者のみ）
# config/routes.rb
require "rperf/viewer"
constraints ->(req) { req.session[:admin] } do
  mount Rperf::Viewer.new(nil, path: ""), at: "/rperf"
end
```

## Rperf.profile によるオンデマンドプロファイリング

特定のエンドポイントやジョブのみをプロファイルし、他の部分ではオーバーヘッドをゼロにしたい場合は、[`Rperf.start(defer: true)`](#index:Rperf.start) と [`Rperf.profile`](#index:Rperf.profile) を使用します:

```ruby
# config/initializers/rperf.rb
require "rperf"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# プロファイルを定期的にエクスポート
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

その後、特定のコードパスを `profile` でラップします:

```ruby
class UsersController < ApplicationController
  def index
    Rperf.profile(endpoint: "GET /users") do
      @users = User.all
    end
  end
end
```

`profile` ブロックのみがサンプリングされます。他のリクエストやバックグラウンド処理にはタイマーのオーバーヘッドがゼロです。

## Rails の完全な設定例

Web とジョブの両方をプロファイリングする典型的な Rails 設定:

```ruby
# config/initializers/rperf.rb
require "rperf/rack"
require "rperf/sidekiq"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# Web リクエストにラベル付け
Rails.application.config.middleware.use Rperf::RackMiddleware

# Sidekiq ジョブにラベル付け
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end

# プロファイルを定期的にエクスポート
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

エンドポイントとジョブ間の時間の使われ方を比較:

```bash
go tool pprof -tagroot=endpoint tmp/profile-*.pb.gz   # Web の内訳
go tool pprof -tagroot=job tmp/profile-*.pb.gz         # ジョブの内訳
```
