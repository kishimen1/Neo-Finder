# OneCommander 調査と Neo-Finder への採用提案

調査日：2026-10-09（日本時間）
対象：Windows 用 **OneCommander**。macOS 用の「Commander One」は別製品であり、本調査の対象に含めない。

## 調査の範囲と読み方

公式サイト・公式ヘルプ・開発者の投稿で機能の存在と版を確認し、利用者の投稿・第三者の実利用レビューで評価や不満を確認した。Microsoft Store の[指定された製品ページ](https://apps.microsoft.com/detail/9nblggh4s79b?hl=ja-JP&gl=JP)については、本文・星評価・レビュー件数・レビュー本文を取得していない。したがって、Store の評価に基づく人気度は示していない。

以下の「根拠強度」は、この調査で見つかった具体的な評価の厚さであり、機能の品質や支持率の測定値ではない。「複数具体言及」は異なる投稿に具体的な利点への言及があること、「単一レビュー」は個人の使用経験が中心であること、「主に公式・要望程度」は実装説明や改善要望が中心であることを示す。

採用優先度は、利用者評価に加え、Finder との重複、日常操作への効果、実装上の負担を考慮した **調査段階の採用案**である。P0 は初期設計の中核、P1 は次の実装段階、P2 は追加候補を意味する。最終的な段階分けは[設計書](Neo-Finder-design.md)を優先する。例えば簡単な相対日付表示は初期に含め、カラムの基本互換と高度な親列圧縮は分けて扱う。

## 分割表示以外の候補

| 機能候補 | 公式資料で確認した内容 | 利用者の評価・不満と日付 | 根拠強度 | Neo-Finder への採否提案 |
|---|---|---|---|---|
| 永続タブ・作業状態の復元 | セッションをまたいでタブを保持する。[公式機能一覧](https://www.onecommander.com/) | Slant には複数タブ、フォルダー表示の保存を利点とする記載があるが、各投稿日は表示不明。[Slant](https://www.slant.co/options/29288/~one-commander-review)。2023-08-21 の利用者は、多数のお気に入りとは別に、案件で必要な 2〜4 個のタブだけを固定したいと説明。[タブ固定の要望](https://www.reddit.com/r/OneCommander/comments/11ft3fc/) | 複数具体言及。ただし固定タブの投稿は現状への要望であり、実装済み機能への高評価ではない。 | **P0：採用。** 左右のタブ、パス、表示、並び順、分割率を保存する。明示保存した作業環境と自動復元を分け、履歴を残さない選択肢も用意する。 |
| プロジェクト別のお気に入り | サイドバーに任意のグループを作成できる。並べ替えや、実フォルダー名を変更しない表示上の別名を持つ。[公式 Sidebar](https://onecommander.com/help2/Sidebar.html) | 2026-03-27 の実利用記事は、案件に合わせたグループ作成を評価。[Make Tech Easier](https://maketecheasier.com/onecommander-file-explorer-alternative/)。2023-08-21 の別の利用者もお気に入りを便利と述べる一方、タブ固定とは用途が異なると説明。[利用者投稿](https://www.reddit.com/r/OneCommander/comments/11ft3fc/) | 複数具体言及 | **P0：採用。** 「会計」「研究」「個人」などのグループ、別名、折り畳み状態を保存する。ファイルの実配置を変えずに整理する。 |
| 現在フォルダーの即時フィルター | 入力した文字列や拡張子で現在の一覧を絞り込み、Esc で解除できる。[公式 Folder Pane](https://onecommander.com/help2/FolderPane.html) | 2026-04-03 の投稿には、入力するだけで絞れる点を便利とする声と、検索欄を見つけられない、再帰検索と混同する、Space とプレビューが衝突するという不満がある。[検索 UI の議論](https://www.reddit.com/r/OneCommander/comments/1sb4apm/oc_is_an_interesting_program_but_unusable_for_me/)。Slant でも検索・フィルターを利点としているが投稿日は表示不明。[Slant](https://www.slant.co/options/29288/~one-commander-review) | 複数具体言及 | **P0：採用。** 各ペインに「このフォルダーを絞り込む」欄と範囲表示を置く。ファイル名のタイプ選択、絞り込み、広域検索の違いを明示する。 |
| 相対日付・ファイル年齢の色表示 | 最終更新からの経過時間を表示し、色で補助する。[公式 Folder Pane](https://onecommander.com/help2/FolderPane.html) | 2023-11-19 の利用者は年齢列と色を有用としつつ、時間経過で表示が更新されない点を報告。[更新に関する投稿](https://groups.google.com/g/onecommander/c/S8HQR8AbrOU)。2026-04-24 にも日常的に使う利点として具体的言及がある。[比較投稿](https://www.reddit.com/r/OneCommander/comments/1ss3cbn/onecommander_vs_total_commander/)。不要なので隠したいという投稿もある（2025-02-22）。[反対例](https://www.reddit.com/r/OneCommander/comments/1ivck3x/) | 複数具体言及。好みは分かれる。 | **P1：採用。** 「3 時間前」と絶対日時を選択・併記できるようにする。何の日付か明示し、色は任意の補助とする。経過時間の更新も設計する。 |
| File Automator／一括リネーム | 正規表現によるリネーム、画像の変換・サイズ変更、バッチスクリプト処理を備える。公式自身が操作の難しい部分と認めている。[公式 File Automator](https://onecommander.com/help2/FileAutomator.html) | 2026-09-25 に利用者が、OneCommander のリネーム機能を気に入り頻繁に使うと記載。[検索機能告知へのコメント](https://www.reddit.com/r/OneCommander/comments/1wnt81y/everythinglike_instant_search_is_now_built_into/)。2026-03-27 の実利用記事も、連番などの処理を内蔵ツールで行える点を評価。[Make Tech Easier](https://maketecheasier.com/onecommander-file-explorer-alternative/) | 複数具体言及。ただし正規表現など個々の処理の支持率は不明。 | **P1：限定採用。** 連番、日付、置換、正規表現、プリセットを優先する。旧名→新名と衝突を実行前に表示し、戻せる範囲を明示する。動画変換・任意スクリプトは後回し。 |
| Miller Columns の改善 | 深い階層で親列を圧縮し、任意でホバー中の親列を展開する。自動幅変更は無効化できる。[公式 Columns](https://onecommander.com/help2/FolderColumnsandNavigationPane.html) | 2023-09-15 に利用者が、親階層を常時見渡せることを具体的に評価。[Reddit](https://www.reddit.com/r/kde/comments/16jad7v/)。2023-09-05 の別の利用者も、列表示がこのアプリを気に入った理由と述べる。[Google Groups](https://groups.google.com/g/onecommander/c/rFaxZCypHgo) | 複数具体言及 | **P1：差分を採用。** Finder にある列表示自体を新機能と数えず、長い日本語名に合う幅調整、親列圧縮、左右独立の表示を追加候補にする。ホバーで画面が動く挙動は任意にする。 |
| キーボードによるペイン操作 | ペイン間フォーカス移動、他ペインへのコピー・移動、タブ切替などを備える。[公式 Shortcut Keys](https://onecommander.com/help/4._Shortcut_Keys.html) | 2023-09-27 の利用者は、反対ペインの新規タブで開く機能を頻繁に使うため、専用キーを要望。[利用者投稿](https://groups.google.com/g/onecommander/c/ZbDttVBkYw0)。2025-09-19 にもペイン切替・転送キーの改善要望がある。[Wishlist](https://www.reddit.com/r/OneCommander/comments/1hvtx99/wishlist_for_v4/) | 主に公式・要望程度。「キーボード操作が特に高評価」とする根拠は弱い。 | **P0：操作品質として採用。** Finder の標準キーを保ち、ペイン移動・反対側で開く・反対側へのコピー／移動を追加する。Windows のキー配列をそのまま移植しない。 |
| 操作キュー・履歴・再試行 | Taskmaster は並列件数制限、競合方針、失敗分の再試行、条件付きの操作取り消しを説明している。[開発者 Gist](https://gist.github.com/m1l/065e7489b2f80574c918c99bf40fb6db) | 同 Gist の 2024-06-30 コメントには外付け HDD 転送中の停止報告、2026-01-16 には SMB 転送に関する良好な経験がある。いずれも個別環境の報告であり、一般的な速度優位の証拠ではない。[利用者コメントを含む資料](https://gist.github.com/m1l/065e7489b2f80574c918c99bf40fb6db) | 主に公式・要望程度。利用経験はあるが、キューそのものへの広い支持は未確認。 | **P1：段階採用。** 進捗、キャンセル、競合確認、失敗内容、取り消し可能な履歴を先に実装する。永続キュー・途中再開は安全条件を定めて別段階にする。 |
| 常設プレビュー・詳細 | Space によるプレビューと詳細表示を持つ。[公式機能一覧](https://www.onecommander.com/) | 2026-03-27 の著者は特に気に入った機能と評価する一方、入口が目立たず気づかなかったと説明。[Make Tech Easier](https://maketecheasier.com/onecommander-file-explorer-alternative/)。Slant にもプレビューを利点とする記載があるが投稿日は表示不明。[Slant](https://www.slant.co/options/29288/~one-commander-review) | 複数具体言及。ただし具体的使用感は単一レビューが中心。 | **P0：互換性要件として採用。** macOS の既存プレビュー機能との重複が大きい。価値は二つのペインと常設しやすい配置に置き、独自の形式対応エンジンは優先しない。 |
| フォルダー内メモ／To Do | 任意フォルダーにタスクとメモを追加できる。[公式機能一覧](https://www.onecommander.com/) | 2026-03-27 の著者は、特に気に入り常用する機能として挙げている。[Make Tech Easier](https://maketecheasier.com/onecommander-file-explorer-alternative/) | 単一レビュー | **P2：追加候補。** ファイル操作の中核から範囲が広がるため初版必須にしない。採用時は持ち出せる文書形式と、フォルダーへの書き込みが発生することを明示する。 |

## 安定版 v3 と v4 beta の区別

調査時点の公式トップページは、安定版インストーラーを **3.108.0.0（2026-09-26）** と表示している。[公式トップ](https://www.onecommander.com/)

V4 の公式ページは **public beta 0.0.72.0** と表示し、本番・業務用途では引き続き V3 を推奨している。機能や設定の変更が続いており、完成版として扱えない。[V4 公式案内](https://onecommander.com/beta)

| 論点 | 確認できたこと | 設計資料に記載する際の扱い |
|---|---|---|
| タブとセッション | 永続タブは公式の既存機能。V4 は名前付き・保存済み・一時ウィンドウ、セッション全体復元を強化している。[公式](https://www.onecommander.com/)、[V4](https://onecommander.com/beta) | 既存のタブ保持と、V4 の復元範囲の拡張を分ける。「ワークスペース」の細かい挙動が V3 にすべてあるとは書かない。 |
| Taskmaster と Undo | V3 でも Taskmaster を選べば、完了操作を右クリックして条件付きで戻せるとの開発者説明がある（2024-12-16）。上書きや後続操作などにより戻せない場合がある。[開発者回答](https://groups.google.com/g/onecommander/c/_ocbQsBJtm4)。V4 は Taskmaster を既定化し、Ctrl+Z の履歴 UI を提供する。[V4](https://onecommander.com/beta) | 過去レビューの「Undo がない」を現在の OneCommander 全体の説明に使わない。Neo-Finder でも「すべて戻せる」と保証せず、操作単位で可否を扱う。 |
| Everything に似た高速検索 | 開発者は 2026-09-23、V4 Beta .69 で NTFS のファイルテーブルを直接使う検索を告知。Everything のインストールを要する連携ではない。同日の開発者コメントは本文検索を予定しないと説明。[告知・コメント](https://www.reddit.com/r/OneCommander/comments/1wnt81y/everythinglike_instant_search_is_now_built_into/) | 「安定版の Everything 統合」「本文を含む万能検索」と書かない。Neo-Finder では高速に探せる体験を参考にし、macOS の検索基盤と権限に合わせて別設計する。 |
| キューの高度機能 | 開発者 Gist はハッシュ検証、キュー保存、バッチファイルへの書き出しを「Soon」と記載している。ページの最終活動表示は 2026-08-01。[Taskmaster 資料](https://gist.github.com/m1l/065e7489b2f80574c918c99bf40fb6db) | 実装済みとして機能表に転記しない。最終活動日は本文各項目の更新日を保証しない。 |

## Neo-Finder の設計に反映する結論

1. 常時二分割と、左右それぞれのタブ・状態保存を中核にする。そこに案件別のお気に入りと、対象範囲が分かる即時フィルターを組み合わせる。
2. 色付き相対日時と一括リネームは、Finder からの追加価値を説明しやすい。ただし任意表示、明瞭なラベル、実行前の変更一覧を伴わせる。
3. 列表示、プレビュー、標準キーは macOS に既存の体験を維持する部分として扱い、OneCommander との機能数比較だけで新規性を主張しない。
4. 転送キューは人気の印象より、操作の追跡・失敗回復・安全性を理由に段階導入する。調査で見えた課題は、便利な機能の発見しづらさと操作の違いによる戸惑いである。追加機能は見える入口を持たせ、Finder の習慣を不用意に置き換えない。
5. To Do、任意スクリプト、メディア変換、詳細なテーマ編集は初版の中核から外す。必要性を実利用で確認してから追加する。

## macOS設計の一次資料

以下はOneCommanderの評判の根拠ではなく、Neo-Finderの実現方法と互換性を判断する資料である。

| Apple資料 | 設計に用いる確認事項 |
|---|---|
| [Finder Sync](https://developer.apple.com/documentation/FinderSync) | 公開拡張の用途と範囲。独立アプリ採用の判断材料 |
| [Macのショートカット](https://support.apple.com/ja-jp/102650) / [macOS 26の名称変更](https://support.apple.com/ja-jp/guide/mac-help/mchlp1144/26/mac/26) | Returnで名称変更、コピーと移動等の操作契約 |
| [Quick Look](https://support.apple.com/ja-jp/guide/mac-help/mh14119/26/mac/26) / [QLPreviewPanel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel) | macOSの既存体験とアプリへの組込み |
| [NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller) | ネイティブの分割UI |
| [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) | Spotlight検索の基盤 |
| [Sandboxからのファイルアクセス](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | ユーザー選択フォルダ、bookmark、アクセスの存続 |
| [TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) | 内容が未取得のファイルと不要なダウンロードを避ける設計 |
| [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator) / [UndoManager](https://developer.apple.com/documentation/foundation/undomanager) | アクセス調整とアプリ側の逆操作登録を区別 |

## 限定条件

- Windows 実機で OneCommander を操作する検証は行っていない。機能の確認は公開資料に基づく。
- 第三者記事、匿名投稿、製品コミュニティには自己選択の偏りがある。開発者の告知本文を独立した利用者評価には数えていない。
- 表中の投稿の絶対日付は取得できた表示に基づく。日付が取得できない Slant の項目は「表示不明」とし、経過年数から逆算していない。
- 古い不満は設計上の注意点として扱う。現行版でも再現する不具合とは断定しない。Slant には年代の異なる記載が混在するため、現在の機能有無の判定には使っていない。
- 複数の投稿があっても支持率は不明。Make Tech Easier の記事は一人の使用経験として扱い、記事内で取り上げられたことを利用者全体の人気と同一視しない。
- **この調査の主張は統計的な人気ランキングではない。** 公開情報から確認した具体的な評価・要望・機能を、Neo-Finder の設計判断につなぐための整理である。
