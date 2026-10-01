# shhcast 設計

リビングに置いたランプで、kawaz がいまミーティング中か / 話しかけて大丈夫かを家族に一目で伝える。Mac 上の常駐デーモン (Swift) が各会議アプリの状態を集めて 3 値に畳み込み、家庭内 LAN 上の ESP32 が LED を点ける。

実測の根拠は [`findings/2026-09-30-slack-huddle-ax-and-coreaudio.md`](findings/2026-09-30-slack-huddle-ax-and-coreaudio.md) と `../probe/*.swift`。本文で「実測」と書いたものはそこに記録がある。記録が無いものは「未確認」と明記する。

## 1. 目的と責務境界

### 目的

- 家族が kawaz の状態を部屋の外 (リビング) から一目で分かる
- 状態は 3 値だけ: `idle` (消灯) / `live` (ミーティング中・マイク on、赤) / `muted` (ミーティング中・マイク off、緑)
- 状態変化からランプ反映までを体感でリアルタイム (目標 1 秒以内) にする。ポーリング間隔で遅れる構造を避け、各ソースは変化通知で駆動する

### 増やしたくないもの

- **誤って消灯すること** (= ミーティング中なのに「話しかけて良い」と見える)。3 値の中でこれが一番害が大きい。判定に迷ったら点灯側 (赤) に倒す。ただし Mac が寝ている・デーモンが死んでいる時まで赤を出し続けると「ずっと赤のランプ」になり信用が落ちるので、その場合は消灯する (後述の lease)
- **家族側の操作**。ランプは表示専用。家族にボタンやアプリを触らせない
- **会議アプリごとの常駐物**。Mac 側の常駐プロセスはデーモン 1 本、ブラウザ側は拡張 1 本に収める

### 扱わないこと (境界)

| 項目 | 扱わない理由 | 将来入れるときの拡張点 |
|---|---|---|
| 予定表 (Google Calendar 等) 連携 | 「予定がある」と「今つながっている」は別物で、目的は後者。予定は開始遅れ・早期終了で実態とずれる | `Source` protocol の 1 実装として足せる。予定は「もうすぐ会議」という 4 値目を生むので、状態モデルの拡張が先に要る |
| 通知 (家族のスマホへ push 等) | 目的はランプを見れば分かること。通知は別チャネルの設計になる | 合成後の状態変化を購読する `Sink` として足せる (ESP32 配信と同じ層) |
| 複数 Mac の集約 | 今は仕事 Mac 1 台。集約はどちらの Mac が主かの規則が要る | ESP32 側で「送り主ごとの lease」を持ち、最悪値 (live > muted > idle) を取る形にすれば Mac 側は変えずに済む。プロトコルに送信元 ID を最初から入れておく |
| 電話・Mac 外の通話 (スマホの通話等) | Mac から観測できない | 手動 override (CLI で `set live` 等) を拡張点として残す |
| 音声の中身・録音 | 状態判定に不要。CoreAudio は「誰かが入力デバイスを動かしているか」の 1 bit しか読まない | 該当なし |

## 2. 状態モデル

### 各ソースの観測値

各ソースは自分の観測を次の `Observation` として報告する。3 値への畳み込みはデーモンの合成層だけが行い、ソースは畳み込みをしない (ソースの責務は「見えたものを正直に言う」まで)。

| 値 | 意味 |
|---|---|
| `none` | このソースの範囲ではミーティングは無い |
| `meeting(mic: .on)` | ミーティング中でマイク on |
| `meeting(mic: .off)` | ミーティング中でマイク off |
| `meeting(mic: .unknown)` | ミーティング中なのは分かるがマイク状態が読めない (UI 文言が未知の言語等) |
| `micInUse` | CoreAudio 専用。入力デバイスを誰かが動かしている。ミーティングかどうかは分からない |
| `unavailable` | ソース自体が観測不能 (Slack 未起動、権限なし、拡張の接続切れ、TTL 切れ) |

| ソース | 観測元 | 取れる値 | 根拠 |
|---|---|---|---|
| Slack AX | `AXToolbar description=ハドルミーティングのアクション` の有無、マイクボタンの description | `none` / `meeting(on/off/unknown)` / `unavailable` | 実測 (findings「Slack ハドル AX 調査」) |
| crx: Google Meet | マイクボタンの DOM 属性 | 同上 | 未確認 (selector は実装時に採取) |
| crx: Teams (web) | 同上 | 同上 | 未確認 |
| crx: Zoom (web) | 同上 | 同上 | 未確認 |
| CoreAudio | デフォルト入力デバイスの `kAudioDevicePropertyDeviceIsRunningSomewhere` | `none` / `micInUse` | 実測 (ffmpeg で in-use / idle 遷移を確認)。会議アプリでの挙動は未確認 |

### 畳み込み規則

上から順に評価し、最初に当たった行で決まる。

| # | 条件 | 結果 | 理由 |
|---|---|---|---|
| 1 | Mac がスリープ中 / デーモン停止 (ESP32 側で lease 切れ) | `idle` (消灯) | 観測者が居ない状態で点灯を続けるとランプの信用が落ちる。ESP32 側で判定する (§3) |
| 2 | いずれかのミーティングソースが `meeting(mic: .on)` | `live` (赤) | 1 つでもマイクが開いていれば聞かれている |
| 3 | いずれかのミーティングソースが `meeting(mic: .unknown)` | `live` (赤) | 読めないときは点灯側に倒す (誤消灯を増やしたくない) |
| 4 | いずれかのミーティングソースが `meeting(mic: .off)` | `muted` (緑) | 全ミーティングソースがミュート |
| 5 | ミーティングソースがすべて `none` / `unavailable`、CoreAudio が `micInUse` | 裁定待ち Q2 (推し: `live`) | 未知アプリ (Zoom デスクトップ、FaceTime、Discord 等) の会議の可能性。音声入力・録音・音声認識でも立つので誤点灯はある |
| 6 | それ以外 | `idle` (消灯) | |

補足:

- **複数ソースが同時にミーティング中を言う時** (例: Slack ハドル + Meet を同時に開いている) は規則 2〜4 のとおり最悪値 (`live` > `muted`) を取る。どのソースが言っているかは `daemon status` に出す (§4)
- **ミュートと CoreAudio の関係**: 会議アプリがミュート中も入力デバイスを掴み続けるか (= ミュート中も `micInUse` が立つか) はアプリ依存で未確認 (findings の実機マトリクスが未記入)。このため CoreAudio は「ミーティングソースが `meeting(mic: .off)` を言っている時にそれを覆す」用途には使わない。CoreAudio が効くのは規則 5 の「誰もミーティングを言っていない」場合だけ
- **`unavailable` は `none` と同じ扱い** (規則 5, 6)。ソースが落ちたからといって点灯はしない。落ちた事実は `daemon status` で見せる

### ソースの生存 (heartbeat / TTL)

| ソース | 生存の知り方 | 落ちた時の扱い |
|---|---|---|
| Slack AX | `NSWorkspace` の起動 / 終了通知でプロセス生死を知る。AX 通知が来なくても状態は保持 (通知駆動なので無音 = 変化なし) | Slack 終了で即 `unavailable`。ハドル中に Slack がクラッシュすれば通話も切れているので消灯で正しい |
| crx 各タブ | 拡張がタブごとに 15 秒間隔で heartbeat (現状値の再送) を送る。TTL 45 秒 (heartbeat 3 回分) で `unavailable` | タブを閉じた時は拡張が `tabs.onRemoved` で明示的に `none` を送るので TTL は保険。TTL を待つのはブラウザごと落ちた / 拡張が殺された時だけ |
| CoreAudio | 同一プロセス内なので heartbeat 不要。デフォルト入力デバイスの切替はリスナ付け替えで追う (probe と同じ構造、切替追従は未実測) | 読み取りエラー時は `none` |

crx の heartbeat 15 秒は「拡張が生きている」の確認であって状態変化の伝達経路ではない (状態変化は MutationObserver から即時 push)。TTL 45 秒の遅れが出るのはブラウザごと落ちた場合だけで、その時はミーティングも切れているので赤が 45 秒余計に残る方向の誤差に留まる。

## 3. コンポーネントとプロトコル

```
 [Slack.app] --AX--> ┐
 [Chrome + crx] --HTTP(localhost)--> [shhcast daemon (Swift)] --HTTP(LAN)--> [ESP32 + LED]
 [CoreAudio] -------> ┘
```

| コンポーネント | 責務 | 責務でないもの |
|---|---|---|
| デーモン (Swift) | ソースの観測、3 値への合成、ESP32 への配信、Mac スリープ時の消灯送信、`daemon` / `service` CLI | サイトごとの DOM 解釈 (crx の責務)、LED の色・明るさ (ESP32 の責務) |
| Chrome 拡張 (TS) | 会議サイトのタブでマイクボタンを監視し、タブごとの観測値をデーモンへ送る。サイト別 selector 表を持つ | 複数タブの合成 (デーモンの責務。拡張はタブ単位で素直に送る) |
| ESP32 ファーム (ESPHome) | 3 値を受けて LED を点ける。lease が切れたら自分で消灯する | 何がミーティングかの判断 |

### crx → デーモン

| 候補 | 評価 |
|---|---|
| **localhost HTTP POST (推し)** | MV3 の service worker は休止されるので常時接続を持ちにくい。POST なら休止から起きたときに送るだけで済む。heartbeat も同じ POST で兼ねる。デーモン側は `127.0.0.1` だけで listen |
| WebSocket | 変化時の遅延は POST と体感差が無い。MV3 service worker の休止で切れて再接続の管理が要る分だけ複雑 |
| Native Messaging | 拡張がデーモンを子プロセスとして起こす形になり、デーモンを launchd 監督にする構成と衝突する |

リクエスト形:

```http
POST http://127.0.0.1:<port>/v1/observations
Content-Type: application/json

{"source": "crx", "site": "meet", "tab": 1234, "observation": "meeting", "mic": "off", "at": "2026-09-30T12:34:56Z"}
```

- `tab` はタブ ID。デーモンは `(site, tab)` ごとに観測を持ち、TTL もこの単位で数える
- localhost でも他プロセスから叩ける。偽の状態を注入されてもランプの色が変わるだけなので、認証は置かない (未確認の脅威は無い前提。気になれば共有トークンを後付けできる)
- 拡張側は MV3 の `host_permissions` に `http://127.0.0.1/*` を入れる

### デーモン → ESP32

要件:

- LAN 内。ESP32 の IP は DHCP で変わり得る
- ESP32 の再起動 / Wi-Fi 切断からの復帰後、すぐ現在の状態に戻る
- **Mac がスリープしたらランプを消す**。スリープ直前に送れない場合 (蓋を閉じた瞬間に Wi-Fi が落ちる等) も最終的に消える

| 候補 | ESP32 復帰時 | Mac スリープ時 | 依存 | 評価 |
|---|---|---|---|---|
| **mDNS + HTTP、ESP32 側 lease (推し)** | デーモンが 10 秒ごとに現状値を再送するので最大 10 秒で戻る | デーモンは `NSWorkspace.willSleepNotification` で `idle` を送る。送れなくても ESP32 側の lease (30 秒) 切れで消灯 | 追加サーバ無し。ESPHome の `web_server` + `mdns` で足りる | 家庭内に常設サーバを増やさない。消灯保証を ESP32 側の lease に持たせるので Mac 側の失敗に強い |
| MQTT | retained message で即復帰 | LWT (Last Will) で broker が `idle` を配る | broker が要る (Home Assistant 等) | broker が既に家にあるなら最有力。無いならそのためだけに常設サーバを 1 台増やす |
| ESPHome native API | ESPHome の標準経路 | 同上、client 切断検知 | Swift の client 実装が無い (protobuf を自前実装) | 実装コストに見合わない |

推しは mDNS + HTTP。家庭内に broker が既にあるかどうかで MQTT が逆転するので裁定待ち Q1 に置く。

HTTP の形 (ESPHome の `web_server` が標準で出すエンドポイントに乗る場合):

```http
POST http://meeting-lamp.local/select/lamp_state/set?option=live
```

ESPHome 側に `select` (選択肢 `idle` / `live` / `muted`) を 1 つ置き、`on_value` で LED を切り替える。同じ `on_value` で lease タイマー (30 秒) を張り直し、切れたら `idle` にする。lease 30 秒 / 再送 10 秒は「再送 2 回の取りこぼしまで耐える」ための比。

mDNS の名前解決は macOS 側で `.local` が標準で引けるので、デーモンは名前 (`meeting-lamp.local`) を設定に持つだけでよい。解決失敗・送信失敗はログに出し、次の再送で自然に回復させる (再送が定期的にあるのでリトライ機構を別に持たない)。

送信元 ID (`?source=<hostname>` 等) を最初から付けておく。今は ESP32 側で読まないが、複数 Mac 集約の拡張点になる (§1)。

## 4. デーモン内部

### 構造

```swift
enum MicState { case on, off, unknown }
enum Observation { case none, meeting(mic: MicState), micInUse, unavailable(reason: String) }

protocol Source: AnyObject {
    var id: String { get }                    // "slack", "crx:meet:1234", "coreaudio"
    var kind: SourceKind { get }              // .meeting / .micActivity (畳み込み規則で区別)
    func start(emit: @escaping (Observation) -> Void)
    func stop()
}

enum LampState { case idle, live, muted }
```

- `SlackAXSource` / `CoreAudioSource` は `Source` を実装する常駐ソース
- crx は HTTP receiver が 1 つあり、`(site, tab)` ごとに `CrxTabSource` を生成・破棄する (TTL 切れで破棄)。タブ単位を `Source` にするのは、TTL と status 表示の単位をタブに揃えるため
- `Composer` が全ソースの最新 `Observation` を持ち、変化のたびに §2 の規則で `LampState` を再計算する。値が変わった時は即 `LampSink` へ、変わらなくても 10 秒ごとに再送
- `LampSink` は ESP32 への HTTP 配信。将来の通知等は別 `Sink` として並べる
- 全体をメインの `RunLoop` (AXObserver が RunLoop source を要求するため) と serial queue 1 本で回す。`Composer` の状態はその queue にだけ触らせる

### CLI

`reference/cli-daemon-subcommands` の体系に従う。unit はこのツールでは Mac 1 台につき 1 つ (デフォルト unit のみ) で、`add` / `remove` は持たない。差分:

- `daemon run` — foreground 起動 (開発・切り分け用)
- `daemon supervise` / `start` / `stop` / `restart` / `status` / `log` — 標準どおり
- `service register` / `unregister` / `start` / `stop` / `status` / `log` — 標準どおり。Accessibility 権限は binary に紐づくので、reference 末尾の「署名済み launcher を登録する」構成を採り、binary 更新で権限付与をやり直さない
- ツール固有: `state` (合成結果と各ソースの観測を JSON で 1 回出す。`--follow` で JSONL 追従)、`set <idle|live|muted> [--for <duration>]` (手動 override。Mac 外の通話用の拡張点、初版では未実装でよい)

### `daemon status` の出力例

標準の unit 行に、ツール固有の `lamp` と `sources` を足す。

```json
[
  {
    "id": 0,
    "unit": "default",
    "enabled": true,
    "running": true,
    "pid": 41234,
    "started_at": "2026-09-30T09:00:12Z",
    "version": "0.1.0",
    "restarts": 0,
    "lamp": {
      "state": "live",
      "decided_by": "slack",
      "rule": 2,
      "sink": {"target": "meeting-lamp.local", "last_sent_at": "2026-09-30T12:34:50Z", "last_error": null}
    },
    "sources": [
      {"id": "slack", "kind": "meeting", "observation": "meeting", "mic": "on", "since": "2026-09-30T12:30:02Z"},
      {"id": "crx:meet:1234", "kind": "meeting", "observation": "meeting", "mic": "off", "since": "2026-09-30T12:31:40Z", "last_heartbeat_at": "2026-09-30T12:34:48Z"},
      {"id": "coreaudio", "kind": "mic_activity", "observation": "mic_in_use", "since": "2026-09-30T12:30:03Z"}
    ]
  }
]
```

`decided_by` と `rule` は「なぜ今この色か」に答えるための field。家族から「ずっと赤だった」と言われた時に遡れるよう、状態変化は `log` にも同じ形 (1 行 JSON) で残す。

## 5. Slack AX watcher

### 対象と購読

- Slack の識別は bundle ID `com.tinyspeck.slackmacgap` (localizedName は言語で変わり得るので使わない)
- `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` で Slack の起動・終了を追う。デーモン起動時点で既に動いていればそれに attach する
- attach 時に `AXManualAccessibility=true` をアプリ要素にセットする (実測: セット前は web 内容が見えない。`AXEnhancedUserInterface` は attributeUnsupported で不要)。Slack が再起動すると pid が変わり設定も消えるので、起動通知ごとにセットし直す
- セット直後は AX ツリーの構築に時間がかかる可能性がある (未確認)。attach 後の初回走査で toolbar が見つからなくても、以降の通知で拾えるよう購読は先に張る
- `AXObserver` はアプリ要素に対して `AXWindowCreated` / `AXUIElementDestroyed` / `AXTitleChanged` / `AXValueChanged` を購読する。probe (`ax-watch`) はツリー全要素に購読を張っているが、デーモンでは要素数が多い (600 行超) ので、次の順で絞れるか実装時に確認する (未確認)
  1. アプリ要素への購読だけで子孫の `AXTitleChanged` が届くか
  2. 届かなければ、ハドルウィンドウ (toolbar を含むウィンドウ) の配下だけに購読を張り、`AXWindowCreated` で張り直す
- 通知を受けたら、差分を解釈せず「ハドル toolbar を探し、マイクボタンの状態を読む」を毎回やり直す (再走査)。通知の中身から状態を組み立てるより、毎回ツリーから読む方が取りこぼしに強い。走査はハドルウィンドウ配下に限れば軽い (実測の dump は全体で 644〜683 行)
- 取りこぼし対策として、ハドル中に限り 30 秒ごとの再走査を足す。状態変化の伝達は通知駆動で、定期再走査は「通知が来なかった」ことへの保険 (間隔の根拠: 取りこぼしは稀で、30 秒遅れても誤表示が長引かない範囲)

### 判定

| 観測 | 結果 |
|---|---|
| ハドル toolbar なし | `none` |
| toolbar あり、マイクボタンの description が「on 候補」に一致 | `meeting(mic: .on)` |
| toolbar あり、description が「off 候補」に一致 | `meeting(mic: .off)` |
| toolbar あり、マイクボタンが見つからない / description が候補外 | `meeting(mic: .unknown)` (→ 赤) |
| Slack 未起動 / AX 権限なし / `AXManualAccessibility` セット失敗 | `unavailable(reason)` |

toolbar はハドルウィンドウとメインウィンドウ下部のミニコントロールの 2 か所に出るが、マイクボタンはハドルウィンドウ側にだけある (実測)。toolbar を見つけたら、その中にマイクボタンがある方を採る。

### UI 言語依存の吸収

description は UI 言語に依存する (実測は日本語 UI のみ)。

| 用途 | 日本語 (実測) | 英語 (未確認、実装時に採取) |
|---|---|---|
| ハドル toolbar | `ハドルミーティングのアクション` | 採取する |
| マイク on (押すとミュート) | `マイクをミュートする` | 採取する |
| マイク off (押すと解除) | `マイクのミュートを解除する` | 採取する |

- 候補表は設定ファイルで上書き可能にし、組み込みの既定値に日本語 + 英語を持つ。Slack を別言語に切り替えた時に kawaz が表を足せば直る
- 併用する手掛かり: ミュート切替時に `AXStaticText value=Audio, Muted` の `AXTitleChanged` が届く (実測)。日本語 UI でも英語文字列なので言語非依存の可能性があるが未確認。これが言語非依存と確認できれば、「toolbar の存在」だけ言語依存の候補表で、マイク状態は `Audio, Muted` の有無で読む形に寄せられる。ただし toolbar の検出にも言語依存が残るので、toolbar は role 構造 (`AXToolbar` の子にボタン 4 つ + `AXPopUpButton`) での検出を代替案として実装時に試す
- 候補表に当たらない場合は `meeting(mic: .unknown)` = 赤。言語不一致で黙って消灯するより、赤で気づける方を選ぶ

### Slack が落ちた時

- 終了通知で即 `unavailable(reason: "not running")`。ハドルも切れているので消灯で正しい
- ハング (プロセスは居るが AX が応答しない) は AX 呼び出しが `kAXErrorCannotComplete` 等で返る。AX 呼び出しにはタイムアウト (`AXUIElementSetMessagingTimeout`、値は実装時に決める) を付けてデーモン全体が止まらないようにし、連続失敗時は `unavailable(reason: "ax timeout")`。この時 CoreAudio の規則 5 が効くので、ハドル中なら赤は残る見込み (CoreAudio 側の Slack での挙動は未確認)

## 6. 実装順 (リスクの高い順)

1. **会議アプリごとの CoreAudio 挙動を実測** (findings の実機マトリクスを埋める: Slack / Meet / Teams / Zoom で、マイク on / off 時に in-use が立つか)。規則 5 の意味と Q2 の判断材料がここで決まり、結果次第で畳み込み規則を直す。コードを書く前に済む
2. **Slack AX watcher 単体** (デーモン化せず CLI で `state` を JSONL で吐く)。購読範囲の絞り込み、Slack 再起動時の `AXManualAccessibility` 再セット、英語 UI の文言採取、`Audio, Muted` の言語非依存性の確認。最優先ソースで未確認点が一番多い
3. **ESP32 + ESPHome で lease 付きランプ**。`curl` で `select` を叩いて色が変わること、lease 切れで消えること、ESP32 再起動後に再送で戻ることを確認。Q1 / Q3 の裁定が要る
4. **デーモン骨格**: `Source` / `Composer` / `LampSink`、Slack + CoreAudio の 2 ソース、スリープ通知で `idle` 送信。ここで家庭内で使い始められる (優先 1 の Slack がこれで動く)
5. **Chrome 拡張 (Meet)**: selector 採取、MutationObserver、POST + heartbeat、`tabs.onRemoved`。デーモン側 receiver と TTL
6. **`daemon` / `service` CLI と launchd 登録** (署名済み launcher 構成)。常用に入る前に要る
7. **Teams / Zoom の selector 追加**。拡張の selector 表に行を足すだけの作業になっているはず
