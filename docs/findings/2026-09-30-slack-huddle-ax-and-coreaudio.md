# Slack ハドル AX と CoreAudio の実測

- Date: 2026-09-30

## 判明した事実

- Slack ハドルの Accessibility toolbar とマイクボタンの description から、ハドル参加とミュート状態を観測できた。
- CoreAudio では、ffmpeg によるデフォルト入力デバイスの使用開始・終了を変更通知で観測できた。会議アプリの CoreAudio 挙動は未測定。

## 実用的な示唆 / ベストプラクティス

CoreAudio の使用状態だけで会議参加やミュート状態を断定しない。

## 検証の詳細

### Mac 側マイク使用検出

今回はデフォルト入力デバイスが使用中かどうかだけを検出する。ミーティング中かどうか、ミュート状態、使用プロセスの識別は判定しない。

## probe

```sh
swiftc probe/mic-in-use.swift -o /tmp/mic-in-use
/tmp/mic-in-use
```

デフォルト入力デバイスの `kAudioDevicePropertyDeviceIsRunningSomewhere` を `AudioObjectAddPropertyListenerBlock` で監視し、初期値と変更時に UTC 時刻と `state=in-use|idle` を出力する。デフォルト入力デバイス変更の通知も監視し、リスナを付け替える。ポーリングはしない。終了は Ctrl-C。

## 実測 (2026-09-30、macOS Darwin 25.5、Apple M1 Max)

probe を起動したまま、別プロセスで `ffmpeg -hide_banner -loglevel info -f avfoundation -i ':0' -t 3 -f null -` を実行した。出力は捨てており、録音ファイルは作成していない。ffmpeg は MacBook Pro のマイクを開き、3 秒後に終了した。probe の stdout は以下。

```text
2026-09-30T12:07:25Z state=idle
2026-09-30T12:07:39Z state=in-use
2026-09-30T12:07:42Z state=idle
```

この結果は MacBook Pro のマイクと ffmpeg の組み合わせでの確認であり、別デバイスや会議アプリの挙動を保証しない。デフォルト入力デバイスの切り替え追従は未実測。

## 使用プロセスの識別についての副調査

macOS SDK の公開ヘッダー `CoreAudio.framework/Headers/AudioHardware.h` では `kAudioDevicePropertyDeviceIsRunningSomewhere` を、システム上の少なくとも一つのプロセスで AudioDevice が動作しているかを返す `UInt32` (1 または 0) と定義している。使用プロセスの PID やアプリ名はこのプロパティからは得られない。`kAudioDevicePropertyHogMode` は排他的アクセスの所有プロセス PID を表し、値が -1 なら全プロセスがアクセス可能である。一般的な共有使用中のプロセス一覧を提供するものではない。`AudioObjectAddPropertyListenerBlock` はプロパティ変更通知を登録する公開 API。

Control Center の使用中アプリ名を提供する公開 API、あるいは安定した `log stream` subsystem が存在するかは未確認。ここでのヘッダー調査だけから「公開 API が存在しない」とは断定しない。

## Slack ハドル AX 調査

`ax-dump` は Slack の各ウィンドウから Accessibility ツリーを再帰表示する。`ax-watch` は通知を購読して変更を逐次表示する。どちらも Slack の操作はしない。

```sh
swiftc probe/ax-dump.swift -o probe/bin/ax-dump
swiftc probe/ax-watch.swift -o probe/bin/ax-watch
probe/bin/ax-dump Slack --max-depth 12 --max-elements 2000
probe/bin/ax-watch Slack
```

ビルド前に `mkdir -p probe/bin` を実行する。アプリ引数には localizedName (`Slack`) または bundle ID (`com.tinyspeck.slackmacgap`) を指定できる。`ax-dump` の深さ・要素数の上限は `--max-depth` / `--max-elements` で変更できる。

権限がない場合は両ツールとも終了コード 1 で理由を表示する。macOS の「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で、直接実行する `probe/bin/ax-dump` と `probe/bin/ax-watch`、または親のターミナルアプリに権限を付ける。付与後はターミナルを再起動して再実行する。権限ダイアログが出た場合は手動で対応する。

調査時の手動操作:

1. Slack でハドルを開始し、`ax-dump` の出力を `probe/logs/huddle-dump.txt` に保存する。
2. `ax-watch` を起動して出力を `probe/logs/huddle-watch.txt` に保存し、起動したままマイクのミュートを数回 on/off する。終了は Ctrl-C。
3. ダンプからミュートボタンの `role` / `title` / `value`、ハドルウィンドウの `subrole` / `title` を比較する。通知の `role` / `title` / `value` とミュート切替の対応を確認する。出力にはワークスペースや会話の名前が含まれ得るため、`probe/logs/` は gitignore 対象にしている。
4. 下のマトリクスの「Slack ハドル」行に、別途 `mic-in-use` を起動して観測したマイク on/off 時の CoreAudio `state=in-use|idle` を記入する。AX の観測結果だけから CoreAudio 列を埋めない。

### ax-enable

Slack (Electron) は既定では web 内容の AX ツリーを公開しない。`ax-enable` は対象アプリに `AXManualAccessibility` と `AXEnhancedUserInterface` をセットする。

```sh
swiftc probe/ax-enable.swift -o probe/bin/ax-enable
probe/bin/ax-enable Slack
```

引数は `ax-dump` と同じく localizedName または bundle ID。実行後に `ax-dump` / `ax-watch` を使う。

### 実測結果

前提:

- `AXManualAccessibility=true` をセットする前は AX ツリーが 25 行で web 内容が見えない。セット後は 683 行になりハドル UI が見える
- `AXManualAccessibility` は ok。`AXEnhancedUserInterface` は err -25208 (attributeUnsupported) で、セットは不要

構造 (ハドル中):

- `AXToolbar description=ハドルミーティングのアクション` の配下に次の要素がある
  - `AXButton description=マイクをミュートする` (ミュート中は `マイクのミュートを解除する`)
  - `AXButton description=カメラをオンにする` (オン中は `カメラをオフにする`)
  - `AXPopUpButton description=オーディオ設定`
  - `AXButton description=ハドルミーティングを退出する`

判定方法:

- ハドル中かどうか: 上記 toolbar の存在。退出後は該当 toolbar が 0 件になる
- マイク on/off: ミュートボタンの description の文言
- 切替の通知: ミュート切替時に `AXTitleChanged role=AXButton` と、`AXStaticText value=Audio, Muted` の `AXTitleChanged` が届く

ウィンドウ状態の影響 (実測):

- toolbar は 2 か所に出る (ハドルウィンドウ本体と、メインウィンドウ下部のミニコントロール)。マイクボタンはハドルウィンドウ側にだけある
- ハドルウィンドウを最小化、Slack 本体も最小化、別アプリをフルスクリーン (別 Space) のいずれでも、toolbar とマイクボタンは AX ツリーに残る (dump 644〜653 行、description も現状を反映)。ウィンドウ可視性は検出に影響しない
- 最小化中はユーザ自身がミュートを操作できないため、最小化中の切替通知は検証対象外

課題:

- description は UI 言語に依存するため、日本語以外の UI では文言が変わる
- `Audio, Muted` の英語 StaticText は言語非依存の判定材料になり得るが、未確認

## 次の実機マトリクス (未測定)

各会議サービスの操作は手動で実施する。表の値は未記入。

| アプリ | マイク on 時の CoreAudio in-use | マイク off 時の CoreAudio in-use |
|---|---|---|
| Slack ハドル |  |  |
| Google Meet (Chrome) |  |  |
| Teams |  |  |
