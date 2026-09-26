# Licensing

Copyright (C) 2026 seijiro and contributors.

my-tategaki is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. The SPDX license identifier is **GPL-3.0-or-later**.

my-tategaki is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.

## 適用範囲

別の表記があるものを除き、本リポジトリのオリジナルのEmacs Lisp、出力用コード、
テスト、スクリプト、マニュアル、サンプル原稿、説明用画像にGPL-3.0-or-laterを適用します。
著作権表示は、個々の寄稿者の権利を他者へ譲渡することを意味しません。
説明用画像に写るOSの画面要素やフォント等の第三者の権利は、それぞれの権利者に帰属します。

このライセンスは拡張自身の配布条件です。拡張を使って利用者が書いた原稿そのものに、
このライセンスを適用するものではありません。

## 第三者のソフトウェア・フォント

Emacs、Dockerのベースイメージ、Pandoc、Vivliostyle、Chromium、EPUBCheck、
Notoフォント等は、それぞれの権利者とライセンスを持ちます。本プロジェクトの
ライセンス表示によって、第三者の条件を変更することはありません。

- npm依存は `export/package-lock.json` に記録しています。たとえば同ファイルの
  Vivliostyle CLI / Core / Viewerの表記は `AGPL-3.0` です。本体のGPLとは区別してください。
- Docker内のDebianパッケージの著作権・ライセンスは、通常
  `/usr/share/doc/<package>/copyright` に含まれます。npm依存の配布物は
  `/opt/vivliostyle/node_modules/`、EPUBCheckの配布物は `/opt/epubcheck/` に置きます。
- 同梱するNotoフォント2系統のライセンスを `/opt/tategaki/licenses/` に保存し、
  出力ジョブにも記録します。このフォルダーは全依存のライセンス一覧ではありません。
  追加フォントの権利・配布条件は各フォントのものです。
- Copilot・Corfuのような任意の連携先パッケージも、そのパッケージ自身の条件に従います。

Dockerイメージを第三者へ再配布する場合は、本体だけでなく同梱する各コンポーネントの
著作権表示・ライセンス・対応するソースの提供条件も維持してください。

GNU GPLの原文は[GNUの公式サイト](https://www.gnu.org/licenses/gpl-3.0.html)でも読めます。
