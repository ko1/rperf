# フレームワーク統合

rperf は、Web フレームワークやジョブプロセッサからのコンテキストで自動的にプロファイルおよびラベル付けするオプションの統合機能を提供します。これらは [`Rperf.profile`](#index:Rperf.profile) を使用し、タイマーの有効化とラベルの設定を同時に行います。`start(defer: true)` とシームレスに連携します。プロファイリングの開始は別途行ってください（例: イニシャライザで）。

> [!NOTE]
> `Rperf.profile` が有効化するタイマーはプロセス全体に作用します。あるスレッドの `profile` ブロック実行中、同時に動いている他のスレッドもサンプリングされます。各スレッドのサンプルにはそのスレッド自身のラベルが付くため、プロファイル上で区別できます。この設計により、プロファイル対象区間でのGVL競合やバックグラウンド処理の影響も可視化できます。

## Rack ミドルウェア

`Rperf::RackMiddleware` は各リクエストをプロファイルし、エンドポイント（`METHOD /path`）でラベル付けします。デフォルトで動的セグメントが正規化されます（数値 ID → `:id`、UUID → `:uuid`）。`label: :raw` で元の PATH_INFO をそのまま使うか、`label:` にカスタム proc を渡してフレームワーク固有のルート正規化も可能です。

```ruby
require "rperf/rack"
```

### Rails

```ruby
# config/initializers/rperf.rb
require "rperf/rack"
require "rperf/viewer"

Rperf.start(defer: true, mode: :wall, frequency: 99)

Rails.application.config.middleware.use Rperf::Viewer
Rails.application.config.middleware.use Rperf::RackMiddleware

# 60分ごとにスナップショットを取得
Thread.new do
  loop do
    sleep 60 * 60
    Rperf::Viewer.instance&.take_snapshot!
  end
end
```

`/rperf/` にアクセスしてビューアを開きます。tagfocus でエンドポイントをフィルタリング（例: `GET /api/users`）したり、tagroot でエンドポイントごとにフレームグラフをグループ化できます。

### Sinatra

```ruby
require "sinatra"
require "rperf/rack"
require "rperf/viewer"

Rperf.start(defer: true, mode: :wall, frequency: 99)
use Rperf::Viewer
use Rperf::RackMiddleware

Thread.new { loop { sleep 3600; Rperf::Viewer.instance&.take_snapshot! } }

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

ビューアで tagfocus を使ってジョブ名でフィルタリングしたり、tagroot でジョブクラスごとにフレームグラフをグループ化できます。

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

`Rperf::Viewer` は、設定可能なマウントパスでインタラクティブなプロファイリング UI を提供する Rack ミドルウェアです。スナップショットをメモリに保持し、[d3-flame-graph](https://github.com/nicedoc/d3-flame-graph) を使ってブラウザ内で描画します。gem の依存やビルドツールは不要です。ビューアは実行時に CDN（cdnjs.cloudflare.com, cdn.jsdelivr.net）から d3.js と d3-flame-graph を読み込むため、初回アクセス時にインターネット接続が必要です。

> [!WARNING]
> `Rperf::Viewer` には組み込みの認証機能がなく、スタックトレースやラベル値を含むプロファイリングデータがエンドポイントにアクセスできる全員に公開されます。本番環境では必ずフレームワークの認証でアクセスを制限してください（下記「アクセス制御」参照）。

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

`profile` ブロックの外ではタイマーが停止し、オーバーヘッドはゼロです。`profile` ブロック内では、プロセス全体のスレッドがサンプリング対象になります（各スレッドのサンプルにはそのスレッド自身のラベルが付きます）。

`Rperf::Viewer` と組み合わせて結果をブラウザで確認するか、`Rperf.snapshot` + `Rperf.save` でファイルに保存して `rperf report` でオフライン分析もできます。

## Rails の完全な設定例

Web とジョブの両方をプロファイリングする典型的な Rails 設定:

```ruby
# config/initializers/rperf.rb
require "rperf/rack"
require "rperf/viewer"
require "rperf/sidekiq"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# ビューアとリクエストラベリング
Rails.application.config.middleware.use Rperf::Viewer
Rails.application.config.middleware.use Rperf::RackMiddleware

# Sidekiq ジョブにラベル付け
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end

# 60分ごとにスナップショットを取得
Thread.new do
  loop do
    sleep 60 * 60
    Rperf::Viewer.instance&.take_snapshot!
  end
end
```

`/rperf/` にアクセスし、tagroot でエンドポイントやジョブクラスごとにフレームグラフをグループ化して確認できます。
