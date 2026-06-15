# WorkflowSpec DSL フィールド仕様

## 概要

WorkflowSpec DSL は、ドメインロジックの操作グラフを人間が理解しやすい形で記述するための宣言DSLである。

このDSLは実行系を提供しない。
主目的は以下である。

* ドメイン操作の依存関係を明示する
* ドメインイベントとワークフローの関係を記述する
* イベント起点のオートメーションを定義する
* ワークフロー図、Markdown文書、影響範囲一覧などを生成する
* LLMが生成したドメインロジックを、人間がレビュー可能な構造に整理する

DSLの主要概念は以下の3つである。

| 概念           | 意味                          |
| ------------ | --------------------------- |
| `event`      | ドメイン上で「起きた」とみなされる出来事        |
| `workflow`   | ドメイン操作の依存グラフ                |
| `automation` | イベントをトリガーとしてワークフローを開始する接続規則 |

---

# 共通ルール

## 名前

各DSL要素の `name` は atom で表す。

```elixir
workflow :approve_order do
end
```

名前は図や文書にそのまま出力されるため、ドメイン用語として読める名前にする。

推奨:

```elixir
:approve_order
:reserve_inventory
:payment_authorized
```

非推奨:

```elixir
:step1
:process
:handle
:do_stuff
```

## ドキュメント

`event`、`workflow`、`automation` には `@doc` を付ける。

```elixir
@doc """
注文が提出されたことを表す。
"""
event :order_submitted do
end
```

DSL内に `doc` フィールドは持たせない。
ドキュメント本文は Elixir の `@doc` / `@moduledoc` から取得する。

## 実行しない

このDSLは関数を実行しない。
`task` や `decision` は関数への参照を持つだけである。

```elixir
task :load_order,
  call: {MyApp.Orders, :get_order, 1}
```

この指定は「このタスクは `MyApp.Orders.get_order/1` に対応する」という意味であり、DSL解釈時に関数を呼び出すという意味ではない。

---

# `event`

## 意味

`event` は、ドメイン上で観測または発火される出来事を定義する。

イベントは状態変更そのものではなく、ドメイン上「何が起きたか」を表す語彙である。

```elixir
@doc """
注文が提出されたことを表すドメインイベント。
"""
event :order_submitted do
  field :order_id, :uuid, required?: true
  field :submitted_by, :user_id, required?: true
end
```

## 命名規則

イベント名は過去形または完了形にする。

推奨:

```elixir
:order_submitted
:payment_authorized
:shipment_created
```

非推奨:

```elixir
:submit_order
:authorize_payment
:create_shipment
```

イベントは「これから行うこと」ではなく「すでに起きたこと」を表すためである。

---

## `event.name`

| 項目 | 内容                 |
| -- | ------------------ |
| 型  | `atom`             |
| 必須 | 必須                 |
| 例  | `:order_submitted` |

イベントの識別子。

ワークフロー内の `emit` や、オートメーションの `on` から参照される。

```elixir
event :payment_authorized do
end
```

---

## `event.fields`

| 項目 | 内容                                        |
| -- | ----------------------------------------- |
| 型  | `list(field)`                             |
| 必須 | 任意                                        |
| 例  | `field :order_id, :uuid, required?: true` |

イベントpayloadの構造を表す。

イベントが発火されたとき、どのような情報が含まれるかを宣言する。

---

# `field`

## 意味

`field` はイベントpayloadの1項目を定義する。

```elixir
field :order_id, :uuid, required?: true
```

---

## `field.name`

| 項目 | 内容          |
| -- | ----------- |
| 型  | `atom`      |
| 必須 | 必須          |
| 例  | `:order_id` |

payload内のフィールド名。

---

## `field.type`

| 項目 | 内容                                                      |
| -- | ------------------------------------------------------- |
| 型  | `atom`                                                  |
| 必須 | 必須                                                      |
| 例  | `:uuid`, `:string`, `:integer`, `:datetime`, `:user_id` |

フィールドの意味的な型。

この型はElixir型そのものではなく、ドメイン仕様上の型を表す。

例:

```elixir
field :order_id, :uuid
field :submitted_by, :user_id
field :submitted_at, :datetime
```

---

## `field.required?`

| 項目    | 内容                |
| ----- | ----------------- |
| 型     | `boolean`         |
| 必須    | 任意                |
| デフォルト | `false`           |
| 例     | `required?: true` |

そのフィールドがイベントpayloadに必ず含まれるかを表す。

```elixir
field :order_id, :uuid, required?: true
```

---

# `workflow`

## 意味

`workflow` はドメイン操作の依存グラフを定義する。

ワークフローは単なる手続き列ではなく、入力、タスク、判断、イベント発火、サブワークフローなどから構成される操作グラフである。

```elixir
@doc """
注文内容を確認し、必要に応じて承認処理を行う。
"""
workflow :approve_order do
  input :order_id, :uuid

  task :load_order,
    call: {MyApp.Orders, :get_order, 1},
    requires: [:order_id],
    produces: :order

  task :evaluate_policy,
    call: {MyApp.OrderPolicy, :evaluate, 1},
    requires: [:order],
    produces: :policy_result,
    after: [:load_order]
end
```

---

## `workflow.name`

| 項目 | 内容               |
| -- | ---------------- |
| 型  | `atom`           |
| 必須 | 必須               |
| 例  | `:approve_order` |

ワークフローの識別子。

`automation.run` や `subflow.run` から参照される。

命名は動詞句にする。

推奨:

```elixir
:approve_order
:prepare_shipment
:capture_payment
```

---

## `workflow.inputs`

| 項目 | 内容            |
| -- | ------------- |
| 型  | `list(input)` |
| 必須 | 任意            |

ワークフロー開始時に必要な入力を定義する。

---

## `workflow.tasks`

| 項目 | 内容           |
| -- | ------------ |
| 型  | `list(task)` |
| 必須 | 任意           |

ワークフロー内のドメイン操作を定義する。

各 `task` は関数参照、入力依存、生成値、前段ノードなどを持つ。

---

## `workflow.decisions`

| 項目 | 内容               |
| -- | ---------------- |
| 型  | `list(decision)` |
| 必須 | 任意               |

ワークフロー内の分岐判断を定義する。

`decision` は `if` や `case` の代替ではなく、ドメイン上の判断点を表す。

---

## `workflow.emits`

| 項目 | 内容           |
| -- | ------------ |
| 型  | `list(emit)` |
| 必須 | 任意           |

ワークフローの進行に応じて発火されうるイベントを定義する。

---

# `input`

## 意味

`input` はワークフロー開始時に必要な外部入力を定義する。

```elixir
input :order_id, :uuid
```

---

## `input.name`

| 項目 | 内容          |
| -- | ----------- |
| 型  | `atom`      |
| 必須 | 必須          |
| 例  | `:order_id` |

入力値の名前。

`task.requires` から参照される。

---

## `input.type`

| 項目 | 内容                              |
| -- | ------------------------------- |
| 型  | `atom`                          |
| 必須 | 必須                              |
| 例  | `:uuid`, `:user_id`, `:integer` |

入力値の意味的な型。

---

## `input.required?`

| 項目    | 内容        |
| ----- | --------- |
| 型     | `boolean` |
| 必須    | 任意        |
| デフォルト | `true`    |

ワークフロー開始時に必須の入力かどうかを表す。

---

# `task`

## 意味

`task` はワークフロー内のドメイン操作を表す。

通常、1つの `task` は1つのドメイン関数に対応する。

```elixir
task :load_order,
  call: {MyApp.Orders, :get_order, 1},
  requires: [:order_id],
  produces: :order
```

---

## `task.name`

| 項目 | 内容            |
| -- | ------------- |
| 型  | `atom`        |
| 必須 | 必須            |
| 例  | `:load_order` |

タスクの識別子。

図や文書に表示され、他ノードの `after` から参照される。

命名は動詞句にする。

推奨:

```elixir
:load_order
:evaluate_policy
:request_manager_approval
```

---

## `task.call`

| 項目 | 内容                              |
| -- | ------------------------------- |
| 型  | `{module, function, arity}`     |
| 必須 | 必須                              |
| 例  | `{MyApp.Orders, :get_order, 1}` |

このタスクが対応する関数参照。

これは実行指示ではない。
ドメイン操作とコード上の関数を対応付けるためのメタデータである。

```elixir
call: {MyApp.Orders, :get_order, 1}
```

生成ドキュメントでは、この参照先関数の `@doc` をタスク説明として利用できる。

---

## `task.requires`

| 項目    | 内容            |
| ----- | ------------- |
| 型     | `list(atom)`  |
| 必須    | 任意            |
| デフォルト | `[]`          |
| 例     | `[:order_id]` |

このタスクが必要とする値の一覧。

`requires` には以下を指定できる。

* `workflow.input` で定義された入力
* 先行する `task.produces` の値
* 先行する `subflow.produces` の値
* 先行する `decision` の結果値

```elixir
requires: [:order_id]
```

`requires` はデータ依存を表す。
実行順序そのものではない。

---

## `task.produces`

| 項目 | 内容       |
| -- | -------- |
| 型  | `atom`   |
| 必須 | 任意       |
| 例  | `:order` |

このタスクが生成する値の名前。

後続タスクの `requires` から参照される。

```elixir
produces: :order
```

---

## `task.after`

| 項目    | 内容              |
| ----- | --------------- |
| 型     | `list(atom)`    |
| 必須    | 任意              |
| デフォルト | `[]`            |
| 例     | `[:load_order]` |

このタスクが、どのノードの後に位置づくかを表す。

`after` は制御依存を表す。
`requires` がデータ依存を表すのに対し、`after` はグラフ上の順序制約を表す。

```elixir
after: [:load_order]
```

通常は `requires` から順序を推論できるが、明示的に順序を示したい場合に使う。

---

## `task.summary`

| 項目 | 内容                    |
| -- | --------------------- |
| 型  | `string`              |
| 必須 | 任意                    |
| 例  | `"注文承認のために対象注文を取得する"` |

タスク固有の文脈説明。

通常、タスク説明は `task.call` の参照先関数の `@doc` から取得する。
ただし、同じ関数が複数の文脈で使われる場合は `summary` で補足する。

```elixir
task :load_order,
  summary: "注文承認のために対象注文を取得する",
  call: {MyApp.Orders, :get_order, 1}
```

---

# `decision`

## 意味

`decision` はワークフロー内のドメイン判断を表す。

```elixir
decision :approval_required,
  evaluated_by: {MyApp.OrderPolicy, :approval_required?, 1},
  requires: [:policy_result],
  branches: [
    required: :request_manager_approval,
    not_required: :mark_approved
  ]
```

`decision` はコード上の `if` や `case` をそのまま表すものではない。
人間が理解すべき業務上の判断点を表す。

---

## `decision.name`

| 項目 | 内容                   |
| -- | -------------------- |
| 型  | `atom`               |
| 必須 | 必須                   |
| 例  | `:approval_required` |

判断点の識別子。

疑問形に近い名前にすると図で読みやすい。

推奨:

```elixir
:approval_required
:payment_retryable
:customer_eligible
```

---

## `decision.evaluated_by`

| 項目 | 内容                                            |
| -- | --------------------------------------------- |
| 型  | `{module, function, arity}`                   |
| 必須 | 必須                                            |
| 例  | `{MyApp.OrderPolicy, :approval_required?, 1}` |

判断に対応する関数参照。

これは実行指示ではなく、判断ロジックの所在を表す。

```elixir
evaluated_by: {MyApp.OrderPolicy, :approval_required?, 1}
```

---

## `decision.requires`

| 項目    | 内容                 |
| ----- | ------------------ |
| 型     | `list(atom)`       |
| 必須    | 任意                 |
| デフォルト | `[]`               |
| 例     | `[:policy_result]` |

判断に必要な値の一覧。

---

## `decision.branches`

| 項目 | 内容                                                                    |
| -- | --------------------------------------------------------------------- |
| 型  | `keyword(atom)`                                                       |
| 必須 | 必須                                                                    |
| 例  | `[required: :request_manager_approval, not_required: :mark_approved]` |

判断結果と遷移先ノードの対応を表す。

```elixir
branches: [
  required: :request_manager_approval,
  not_required: :mark_approved
]
```

左辺は判断結果の名前。
右辺は遷移先ノード名。

---

## `decision.summary`

| 項目 | 内容                |
| -- | ----------------- |
| 型  | `string`          |
| 必須 | 任意                |
| 例  | `"管理者承認が必要か判定する"` |

判断点の人間向け説明。

参照先関数の `@doc` だけでは業務文脈が不足する場合に指定する。

---

# `emit`

## 意味

`emit` はワークフローの進行に応じて発火されうるイベントを表す。

```elixir
emit :order_approved,
  after: [:mark_approved],
  payload_from: :approved_order
```

`emit` はイベント発火の可能性を宣言する。
このDSL自体がイベントを発火するわけではない。

---

## `emit.event`

| 項目 | 内容                |
| -- | ----------------- |
| 型  | `atom`            |
| 必須 | 必須                |
| 例  | `:order_approved` |

発火されうるイベント名。

この値は、同じDSL内で定義された `event.name` を参照する。

---

## `emit.after`

| 項目    | 内容                 |
| ----- | ------------------ |
| 型     | `list(atom)`       |
| 必須    | 任意                 |
| デフォルト | `[]`               |
| 例     | `[:mark_approved]` |

どのノードの後でイベントが発火されうるかを表す。

---

## `emit.payload_from`

| 項目 | 内容                |
| -- | ----------------- |
| 型  | `atom`            |
| 必須 | 任意                |
| 例  | `:approved_order` |

イベントpayloadを構築する元になる値。

通常は先行タスクの `produces` を指定する。

```elixir
payload_from: :approved_order
```

---

# `automation`

## 意味

`automation` は、イベントをトリガーとしてワークフローを開始する接続規則を定義する。

```elixir
@doc """
注文提出イベントを受けて、注文承認ワークフローを開始する。
"""
automation :approve_order_when_submitted do
  on :order_submitted
  run :approve_order

  map_input :order_id, from: [:event, :order_id]
end
```

Automation は Workflow の内部ではなく、Event と Workflow の間にある接続である。

---

## `automation.name`

| 項目 | 内容                              |
| -- | ------------------------------- |
| 型  | `atom`                          |
| 必須 | 必須                              |
| 例  | `:approve_order_when_submitted` |

オートメーションの識別子。

命名は因果関係が読める形にする。

推奨:

```elixir
:approve_order_when_submitted
:start_shipping_after_payment_authorized
:notify_customer_when_shipment_created
```

---

## `automation.on`

| 項目 | 内容                 |
| -- | ------------------ |
| 型  | `atom`             |
| 必須 | 必須                 |
| 例  | `:order_submitted` |

トリガーとなるイベント名。

同じDSL内で定義された `event.name` を参照する。

```elixir
on :order_submitted
```

---

## `automation.run`

| 項目 | 内容               |
| -- | ---------------- |
| 型  | `atom`           |
| 必須 | 必須               |
| 例  | `:approve_order` |

イベント発生時に開始されるワークフロー名。

同じDSL内で定義された `workflow.name` を参照する。

```elixir
run :approve_order
```

---

## `automation.mappings`

| 項目 | 内容                |
| -- | ----------------- |
| 型  | `list(map_input)` |
| 必須 | 任意                |

イベントpayloadからワークフロー入力への対応を表す。

---

# `map_input`

## 意味

`map_input` は、トリガーイベントのpayloadをワークフロー入力へ対応付ける。

```elixir
map_input :order_id, from: [:event, :order_id]
```

---

## `map_input.input`

| 項目 | 内容          |
| -- | ----------- |
| 型  | `atom`      |
| 必須 | 必須          |
| 例  | `:order_id` |

対応先となるワークフロー入力名。

この値は `automation.run` で指定されたワークフローの `input.name` を参照する。

---

## `map_input.from`

| 項目 | 内容                    |
| -- | --------------------- |
| 型  | `list(atom)`          |
| 必須 | 必須                    |
| 例  | `[:event, :order_id]` |

入力値の取得元を表すパス。

基本形は以下である。

```elixir
from: [:event, :order_id]
```

これは、トリガーイベントpayloadの `order_id` をワークフロー入力に渡すことを意味する。

---

# 内部フィールド

以下のフィールドはDSL利用者が直接指定しない。
SparkやWorkflowSpec実装が内部的に利用する。

---

## `doc_ref`

| 項目    | 内容                                                                                   |
| ----- | ------------------------------------------------------------------------------------ |
| 型     | `{module, function, arity}`                                                          |
| 利用者指定 | 不可                                                                                   |
| 例     | `{MyApp.Workflows.OrderApproval, :__workflow_spec_workflow_doc__approve_order__, 0}` |

`@doc` を取得するための内部参照。

`event`、`workflow`、`automation` は、wrapper macro により隠し関数を生成し、その関数に付いた `@doc` を後で `Code.fetch_docs/1` から取得する。

---

## `__spark_metadata__`

| 項目    | 内容           |
| ----- | ------------ |
| 型     | Spark内部メタデータ |
| 利用者指定 | 不可           |

SparkがDSL要素の位置情報や内部メタデータを保持するために使う。

主にエラー表示、検証、ツール支援に利用される。

---

# 参照整合性ルール

DSLは以下の整合性を検証する。

## Event参照

以下は定義済みの `event.name` を参照しなければならない。

* `automation.on`
* `emit.event`

未定義イベントを参照した場合はエラーとする。

---

## Workflow参照

以下は定義済みの `workflow.name` を参照しなければならない。

* `automation.run`
* `subflow.run`

未定義ワークフローを参照した場合はエラーとする。

---

## Node参照

以下は同一ワークフロー内のノード名を参照しなければならない。

* `task.after`
* `decision.branches` の遷移先
* `emit.after`

未定義ノードを参照した場合はエラーとする。

---

## Data参照

以下はワークフロー内で利用可能な値を参照しなければならない。

* `task.requires`
* `decision.requires`

利用可能な値は以下である。

* `workflow.input`
* 先行 `task.produces`
* 先行 `subflow.produces`
* 必要に応じて定義された内部値

未定義の値を `requires` した場合はエラーとする。

---

## Automation mapping

`map_input.input` は、`automation.run` が参照するワークフローの `input.name` と一致しなければならない。

`map_input.from` は、`automation.on` が参照するイベントのpayload fieldと一致しなければならない。

---

# 推奨される最小DSL例

```elixir
defmodule MyApp.Workflows.OrderApproval do
  use WorkflowSpec

  @moduledoc """
  注文承認ドメインのワークフロー仕様。
  """

  @doc """
  注文が提出されたことを表す。
  """
  event :order_submitted do
    field :order_id, :uuid, required?: true
    field :submitted_by, :user_id, required?: true
  end

  @doc """
  注文内容を確認し、必要に応じて承認処理を行う。
  """
  workflow :approve_order do
    input :order_id, :uuid

    task :load_order,
      call: {MyApp.Orders, :get_order, 1},
      requires: [:order_id],
      produces: :order

    task :evaluate_policy,
      call: {MyApp.OrderPolicy, :evaluate, 1},
      requires: [:order],
      produces: :policy_result,
      after: [:load_order]

    decision :approval_required,
      summary: "管理者承認が必要か判定する",
      evaluated_by: {MyApp.OrderPolicy, :approval_required?, 1},
      requires: [:policy_result],
      branches: [
        required: :request_manager_approval,
        not_required: :mark_approved
      ]

    emit :order_approved,
      after: [:mark_approved],
      payload_from: :order
  end

  @doc """
  注文提出イベントを受けて、注文承認ワークフローを開始する。
  """
  automation :approve_order_when_submitted do
    on :order_submitted
    run :approve_order

    map_input :order_id, from: [:event, :order_id]
  end
end
```

---

# 設計方針

## DSLは仕様であり、実装ではない

このDSLはドメインロジックを実行しない。
実行順序、再試行、タイムアウト、キューイング、分散実行などの実装詳細はDSLの中核に含めない。

必要な場合は、将来的に `policy` や `metadata` として拡張する。

---

## 順序より依存を優先する

ワークフローは上から順に実行される手続き列ではなく、依存グラフである。

* `requires` はデータ依存
* `after` は制御依存
* `branches` は判断結果による遷移
* `emit` はイベント発火の可能性

として扱う。

---

## 人間が読む名前を優先する

DSL要素の名前は、図や文書にそのまま出る。
そのため、コード都合の名前ではなく、ドメイン上の意味が読める名前を使う。

よいDSLは、生成された図を見た人間が「何をしているか」を理解できる。
悪いDSLは、生成された図を見た人間が元コードを読み始める。これは敗北である。

