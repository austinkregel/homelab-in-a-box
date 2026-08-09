defmodule Homelab.Credo.Check.EarlyReturn do
  use Credo.Check,
    id: "HL0001",
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      A function whose entire body is a single `if`/`unless` with an `else`
      branch, and whose condition is expressible as a guard, should say so in
      the function head instead.

      Elixir has no `return`, so the equivalent of an early return is a guard
      clause: a second function head that handles the precondition and lets the
      main clause carry only the real work, un-indented.

      So instead of:

          def restart_deployment(%Deployment{} = deployment) do
            if deployment.external_id do
              orchestrator().restart(deployment.external_id)
            else
              {:error, :not_deployed}
            end
          end

      ... prefer:

          def restart_deployment(%Deployment{external_id: nil}),
            do: {:error, :not_deployed}

          def restart_deployment(%Deployment{} = deployment) do
            orchestrator().restart(deployment.external_id)
          end

      The `else` branch is usually a precondition failure wearing an `else`
      costume. Hoisting it into the head makes the happy path the shape of the
      function, which is the thing a reader is looking for.

      This check only fires when the condition uses nothing but guard-safe
      operations on the function's own arguments, so the rewrite is always
      mechanically available. It is a refactoring suggestion, not a rule — a
      two-branch condition where BOTH branches are substantive may well read
      better as it stands.
      """
    ]

  # Guard-allowed BIFs. Deliberately excludes `&&`, `||` and `!`, which look
  # like `and`/`or`/`not` but are macros and are NOT permitted in guards.
  @guard_funs ~w(
    is_atom is_binary is_bitstring is_boolean is_exception is_float is_function
    is_integer is_list is_map is_map_key is_nil is_number is_pid is_port
    is_reference is_struct is_tuple
    abs binary_part bit_size byte_size ceil div elem floor hd length map_size
    node rem round self tl trunc tuple_size
  )a

  @guard_ops ~w(== != === !== > >= < <= and or not in + - *)a

  # AST scaffolding that carries no call semantics of its own.
  @structural ~w(. __block__ __aliases__ {} %{} <<>>)a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({def_op, meta, [head, [do: body]]} = ast, ctx)
       when def_op in [:def, :defp] do
    case body do
      {op, _, [condition, branches]} when op in [:if, :unless] ->
        if Keyword.has_key?(branches, :else) and guard_expressible?(condition) do
          {ast, put_issue(ctx, issue_for(ctx, meta, name_of(head)))}
        else
          {ast, ctx}
        end

      _ ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp guard_expressible?(condition) do
    {_ast, guardable?} = Macro.prewalk(condition, true, &guard_node/2)
    guardable?
  end

  # Once anything disqualifies the condition, stay disqualified.
  defp guard_node(node, false), do: {node, false}

  # `Module.fun(...)` is a remote call and never guard-safe, but `map.field` is
  # — and both are dot-nodes. The target tells them apart.
  defp guard_node({{:., _, [target, fun]}, _, args} = node, ok) when is_atom(fun) do
    cond do
      match?({:__aliases__, _, _}, target) -> {node, false}
      args == [] -> {node, ok}
      true -> {node, false}
    end
  end

  defp guard_node({fun, _, args} = node, ok) when is_atom(fun) and is_list(args) do
    if fun in @guard_funs or fun in @guard_ops or fun in @structural do
      {node, ok}
    else
      {node, false}
    end
  end

  # Variables are `{name, meta, context}` with a non-list context, and literals
  # fall through here too. Both are fine in a guard.
  defp guard_node(node, ok), do: {node, ok}

  defp name_of({:when, _, [inner | _]}), do: name_of(inner)
  defp name_of({name, _, args}) when is_atom(name) and is_list(args), do: "#{name}/#{length(args)}"
  defp name_of({name, _, _}) when is_atom(name), do: "#{name}/0"
  defp name_of(_), do: "the function"

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "The body of #{name} is a single if/else whose condition is guard-expressible — " <>
          "consider a guard clause so the function returns early instead.",
      trigger: name,
      line_no: meta[:line]
    )
  end
end
