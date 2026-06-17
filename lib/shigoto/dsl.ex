defmodule Shigoto.Dsl do
  alias Spark.Builder.{Entity, Field, Section}

  defmodule PayloadField do
    defstruct [
      :name,
      :type,
      :required?,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Event do
    defstruct [
      :name,
      :doc_ref,
      fields: [],
      __identifier__: nil,
      __spark_metadata__: nil
    ]
  end

  defmodule Input do
    defstruct [
      :name,
      :type,
      :required?,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Assertion do
    defstruct [
      :name,
      :requires,
      :after_nodes,
      :after_node,
      :evaluated_by,
      :summary,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Task do
    defstruct [
      :name,
      :call,
      :workflow,
      :requires,
      :produces,
      :after_nodes,
      :after_node,
      :summary,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Decision do
    defstruct [
      :name,
      :evaluated_by,
      :requires,
      :after_nodes,
      :after_node,
      :branches,
      :summary,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Mapping do
    defstruct [
      :target,
      :from,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  defmodule Emit do
    defstruct [
      :event,
      :after_nodes,
      :after_node,
      :__identifier__,
      :__spark_metadata__,
      mappings: []
    ]
  end

  defmodule Workflow do
    defstruct [
      :name,
      :doc_ref,
      inputs: [],
      assertions: [],
      tasks: [],
      decisions: [],
      emits: [],
      persists: [],
      __identifier__: nil,
      __spark_metadata__: nil
    ]
  end

  defmodule Automation do
    defstruct [
      :name,
      :doc_ref,
      :on,
      :idempotency_key,
      :run,
      mappings: [],
      __identifier__: nil,
      __spark_metadata__: nil
    ]
  end

  @field Entity.new(:field, PayloadField,
           args: [:name, :type],
           schema: [
             Field.new(:name, :atom,
               required: true,
               doc: "Payload field name"
             ),
             Field.new(:type, :atom,
               required: true,
               doc: "Payload field type"
             ),
             Field.new(:required?, :boolean,
               default: false,
               doc: "Whether this field is required"
             )
           ]
         )
         |> Entity.build!()

  @event Entity.new(:event, Event,
           args: [:name],
           identifier: :name,
           describe: "Defines a domain event",
           schema: [
             Field.new(:name, :atom,
               required: true,
               doc: "Event name"
             ),
             Field.new(:doc_ref, :any, doc: "Reference to a generated documentation function")
           ],
           entities: [
             fields: [@field]
           ]
         )
         |> Entity.build!()

  @input Entity.new(:input, Input,
           args: [:name, :type],
           schema: [
             Field.new(:name, :atom,
               required: true,
               doc: "Workflow input name"
             ),
             Field.new(:type, :atom,
               required: true,
               doc: "Workflow input type"
             ),
             Field.new(:required?, :boolean,
               default: true,
               doc: "Whether this input is required"
             )
           ]
         )
         |> Entity.build!()

  @assertion Entity.new(:assert, Assertion,
               args: [:name],
               identifier: :name,
               describe: "Defines a workflow precondition",
               schema: [
                 Field.new(:name, :atom,
                   required: true,
                   doc: "Assertion name"
                 ),
                 Field.new(:requires, {:list, :atom},
                   default: [],
                   doc: "Values required to evaluate this assertion"
                 ),
                 Field.new(:after_nodes, {:list, :atom},
                   default: [],
                   doc: "Predecessor nodes (list form)"
                 ),
                 Field.new(:after_node, :atom,
                   doc: "Single predecessor node (convenience alias for after_nodes)"
                 ),
                 Field.new(:evaluated_by, :any,
                   required: true,
                   doc: "{Module, function, arity | arg_list}"
                 ),
                 Field.new(:summary, :string, doc: "Human-readable assertion summary")
               ]
             )
             |> Entity.build!()

  @task Entity.new(:task, Task,
          args: [:name],
          identifier: :name,
          schema: [
            Field.new(:name, :atom,
              required: true,
              doc: "Task name"
            ),
            Field.new(:call, :any,
              doc: "{Module, function, arity | arg_list}"
            ),
            Field.new(:workflow, :any,
              doc: "{Module, workflow_name} or {Module, workflow_name, arg_list}"
            ),
            Field.new(:requires, {:list, :atom},
              default: [],
              doc: "Required values"
            ),
            Field.new(:produces, :atom, doc: "Produced value"),
            Field.new(:after_nodes, {:list, :atom},
              default: [],
              doc: "Predecessor nodes (list form)"
            ),
            Field.new(:after_node, :atom,
              doc: "Single predecessor node (convenience alias for after_nodes)"
            ),
            Field.new(:summary, :string, doc: "Task-specific human summary")
          ]
        )
        |> Entity.build!()

  @decision Entity.new(:decision, Decision,
              args: [:name],
              identifier: :name,
              schema: [
                Field.new(:name, :atom,
                  required: true,
                  doc: "Decision name"
                ),
                Field.new(:evaluated_by, :any,
                  required: true,
                  doc: "{Module, function, arity | arg_list}"
                ),
                Field.new(:requires, {:list, :atom},
                  default: [],
                  doc: "Required values"
                ),
                Field.new(:after_nodes, {:list, :atom},
                  default: [],
                  doc: "Predecessor nodes (list form)"
                ),
                Field.new(:after_node, :atom,
                  doc: "Single predecessor node (convenience alias for after_nodes)"
                ),
                Field.new(:branches, :any,
                  required: true,
                  doc: "Branch name to target node mapping"
                ),
                Field.new(:summary, :string, doc: "Human summary")
              ]
            )
            |> Entity.build!()

  @mapping Entity.new(:map, Mapping,
             args: [:target],
             schema: [
               Field.new(:target, :atom,
                 required: true,
                 doc:
                   "Mapping target. In automation, this is workflow input. In emit, this is event payload field."
               ),
               Field.new(:from, {:list, :atom},
                 required: true,
                 doc: "Source path"
               )
             ]
           )
           |> Entity.build!()

  @emit Entity.new(:emit, Emit,
          args: [:event],
          schema: [
            Field.new(:event, :atom,
              required: true,
              doc: "Event to emit"
            ),
            Field.new(:after_nodes, {:list, :atom},
              default: [],
              doc: "Predecessor nodes (list form)"
            ),
            Field.new(:after_node, :atom,
              doc: "Single predecessor node (convenience alias for after_nodes)"
            )
          ],
          entities: [
            mappings: [@mapping]
          ]
        )
        |> Entity.build!()

  @workflow Entity.new(:workflow, Workflow,
              args: [{:optional, :name, :__default__}],
              identifier: :name,
              describe: "Defines a domain workflow",
              schema: [
                Field.new(:name, :atom,
                  required: false,
                  default: :__default__,
                  doc: "Workflow name (optional for single-workflow modules)"
                ),
                Field.new(:doc_ref, :any, doc: "Reference to a generated documentation function"),
                Field.new(:persists, {:list, :atom},
                  default: [],
                  doc: "Names of produced values to persist as a DB transaction"
                )
              ],
              entities: [
                inputs: [@input],
                assertions: [@assertion],
                tasks: [@task],
                decisions: [@decision],
                emits: [@emit]
              ]
            )
            |> Entity.build!()

  @automation Entity.new(:automation, Automation,
                args: [:name],
                identifier: :name,
                describe: "Defines an event-triggered automation",
                schema: [
                  Field.new(:name, :atom,
                    required: true,
                    doc: "Automation name"
                  ),
                  Field.new(:doc_ref, :any,
                    doc: "Reference to a generated documentation function"
                  ),
                  Field.new(:on, :any,
                    required: true,
                    doc: "Triggering event. Either :event_name or {Module, :event_name}"
                  ),
                  Field.new(:idempotency_key, {:list, :atom},
                    default: [],
                    doc: "Fields used to derive an idempotency key"
                  ),
                  Field.new(:run, :atom,
                    doc: "Workflow to run (inferred for single-workflow modules)"
                  )
                ],
                entities: [
                  mappings: [@mapping]
                ]
              )
              |> Entity.build!()

  @events Section.new(:events,
            top_level?: true,
            describe: "Domain events",
            entities: [@event]
          )
          |> Section.build!()

  @workflows Section.new(:workflows,
               top_level?: true,
               describe: "Domain workflows",
               entities: [@workflow]
             )
             |> Section.build!()

  @automations Section.new(:automations,
                 top_level?: true,
                 describe: "Event-triggered automations",
                 entities: [@automation]
               )
               |> Section.build!()

  use Spark.Dsl.Extension,
    sections: [@events, @workflows, @automations],
    transformers: [
      Shigoto.Transformers.InferMetadata
    ],
    verifiers: [
      Shigoto.Verifiers.ValidateReferences,
      Shigoto.Verifiers.ValidateTaskXor,
      Shigoto.Verifiers.ValidateCyclic
    ]
end
