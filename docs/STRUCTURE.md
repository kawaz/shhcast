# リポジトリ物理構造

```text
shhcast/main/
  README.md / README-ja.md  # 利用者向け概要（設計段階）
  LICENSE                   # MIT License
  justfile                  # lint と push の入口
  docs/
    DESIGN.md               # 実装前の設計
    QUESTIONS.md            # 裁定待ち
    STRUCTURE.md            # この文書
    decisions/INDEX.md      # Decision Records 一覧
    findings/               # 実測記録
  probe/                    # Swift 調査用プログラム（bin/ と logs/ は除外）
```

デーモン・Chrome 拡張・ESP32 ファームウェアは未実装です。
