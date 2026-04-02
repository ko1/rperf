# インストール

## gem のインストール

rperf は C 拡張を持つ Ruby gem として配布されています:

```bash
gem install rperf
```

または Gemfile に追加:

```ruby
gem "rperf"
```

その後:

```bash
bundle install
```

## インストールの確認

rperf が正しくインストールされていることを確認します:

```bash
rperf --help
```

以下のように表示されるはずです:

```
Usage: rperf record [options] command [args...]
       rperf stat [options] command [args...]
       rperf exec [options] command [args...]
       rperf report [options] [file]
       rperf diff [options] base.pb.gz target.pb.gz
       rperf help

Run 'rperf help' for full documentation
```

## プラットフォームサポート

rperf は POSIX システムをサポートしています:

| プラットフォーム | タイマー実装 | 備考 |
|----------|---------------------|-------|
| Linux | `timer_create` + シグナル (デフォルト) | 最高精度 (1000Hz で ~1000us) |
| Linux | `nanosleep` スレッド (`signal: false` 使用時) | フォールバック、~100us のドリフト/tick |
| macOS | `nanosleep` スレッド | シグナルベースのタイマーは利用不可 |

Linux では、rperf はデフォルトで `timer_create` と `SIGEV_THREAD_ID` を使い、専用のワーカースレッドにタイマーシグナルを送ります。これにより、Ruby スレッドを中断することなく正確なインターバルタイミングが実現されます。シグナル番号はデフォルトで `SIGRTMIN+8` で、Ruby API の `Rperf.start` に対する `signal:` キーワード引数で変更できます。

macOS では（および Linux で `signal: false` を設定した場合）、rperf は `nanosleep` ループを持つ専用の pthread にフォールバックします。

## オプション: Go ツールチェーン

Go は `rperf report` で pprof (`.pb.gz`) ファイルを表示する場合と、`rperf diff` サブコマンドでのみ必要です。どちらも `go tool pprof` のラッパーです。これらの機能が必要な場合は、[go.dev](https://go.dev/dl/) から Go をインストールしてください。

Go がなくても、デフォルトの JSON (`.json.gz`) 形式での `rperf report` を含む rperf のすべての機能を使用できます。この形式では rperf 組み込みビューアが開きます。pprof ファイルも [speedscope](https://www.speedscope.app/) などの他のツールで表示したり、テキスト/collapsed 形式で直接生成したりできます。
