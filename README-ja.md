# shhcast

> [English](./README.md) | 日本語

リビングのランプで、家族にミーティング中か、マイクがオンかを伝えます。**設計段階**であり、デーモン・ブラウザ拡張・ランプのファームウェアは未実装です。

## インストール

未提供です。現時点では設計資料と Swift の調査用 probe のみを収録しています。

## 使い方

計画中の表示は `idle`（消灯）、`live`（会議中・マイクオンで赤）、`muted`（会議中・マイクオフで緑）の 3 値です。対象は Slack ハドルおよびブラウザ版 Google Meet、Teams、Zoom を予定しています。

## ドキュメント

- [設計](./docs/DESIGN.md) — Swift デーモン、Chrome 拡張、ESP32 ランプの構成
- [裁定待ち](./docs/QUESTIONS.md)
- [構造](./docs/STRUCTURE.md)
- [実測記録](./docs/findings/2026-09-30-slack-huddle-ax-and-coreaudio.md)

## ライセンス

MIT License, Yoshiaki Kawazu (@kawaz)
