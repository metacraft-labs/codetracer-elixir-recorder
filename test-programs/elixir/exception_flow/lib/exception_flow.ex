defmodule ExceptionFlow do
  @moduledoc false

  def main do
    Process.put(:exception_flow_after, [])

    rescue_result = rescue_matrix(3)
    rescue_score = elem(rescue_result, 1)
    stacktrace_score = elem(rescue_result, 2)
    throw_score = throw_matrix(4)
    exit_score = exit_matrix(5)
    else_score = else_after_matrix(6)
    implicit_score = implicit_body_rescue(7)
    reraise_score = reraise_matrix(8)
    after_score = after_score([:rescue, :throw, :exit, :else, :reraise])

    final_total =
      rescue_score + stacktrace_score + throw_score + exit_score + else_score +
        implicit_score + reraise_score + after_score

    _handled_results = {
      rescue_result,
      throw_score,
      exit_score,
      else_score,
      implicit_score,
      reraise_score
    }

    IO.puts("exception-flow-ok:#{final_total}")
    final_total
  end

  def rescue_matrix(value) do
    try do
      raise_argument(value)
      {:unexpected_rescue_success, 0, 0}
    rescue
      error in ArgumentError ->
        stacktrace = __STACKTRACE__
        message = Exception.message(error)
        stacktrace_depth = length(stacktrace)
        rescue_score = value + 7
        stacktrace_score = if stacktrace_depth > 0 and message == "bad 3", do: 13, else: 0
        {:rescued, rescue_score, stacktrace_score}
    else
      other ->
        {:unexpected_rescue_else, other, 0}
    after
      mark_after(:rescue)
    end
  end

  def throw_matrix(value) do
    try do
      throw_value(value)
      0
    catch
      :throw, {:thrown, caught} ->
        caught + 16
    after
      mark_after(:throw)
    end
  end

  def exit_matrix(value) do
    try do
      exit_value(value)
      0
    catch
      :exit, {:exit_reason, caught} ->
        caught + 25
    after
      mark_after(:exit)
    end
  end

  def else_after_matrix(value) do
    try do
      success_value(value)
    rescue
      _error ->
        0
    catch
      _kind, _reason ->
        0
    else
      {:ok, success} ->
        else_score = success + 34
        else_score
    after
      mark_after(:else)
    end
  end

  def implicit_body_rescue(value) do
    raise_implicit(value)
  rescue
    error in RuntimeError ->
      implicit_score = if Exception.message(error) == "implicit 7", do: value + 43, else: 0
      implicit_score
  end

  def reraise_matrix(value) do
    try do
      try do
        raise_reraised(value)
      rescue
        error in RuntimeError ->
          stacktrace = __STACKTRACE__
          reraise error, stacktrace
      end
    rescue
      error in RuntimeError ->
        reraise_score = if Exception.message(error) == "reraised 8", do: value + 52, else: 0
        reraise_score
    after
      mark_after(:reraise)
    end
  end

  def raise_argument(value) do
    raise ArgumentError, message: "bad #{value}"
  end

  def throw_value(value) do
    throw({:thrown, value})
  end

  def exit_value(value) do
    exit({:exit_reason, value})
  end

  def raise_implicit(value) do
    raise "implicit #{value}"
  end

  def raise_reraised(value) do
    raise RuntimeError, message: "reraised #{value}"
  end

  def success_value(value) do
    {:ok, value}
  end

  def mark_after(tag) do
    seen =
      case Process.get(:exception_flow_after) do
        nil -> []
        values when is_list(values) -> values
      end

    Process.put(:exception_flow_after, Enum.uniq([tag | seen]))
    :ok
  end

  def after_score(tags) do
    seen = Process.get(:exception_flow_after, [])
    length(Enum.filter(tags, &(&1 in seen)))
  end

  # M5 verification entrypoint: deterministically raises an uncaught
  # ArgumentError with a fixture-stable message. The recorder should produce
  # an exception_from event for `crash_inner/0` (and one for `crash/0` too,
  # because the exception unwinds both frames before BEAM exits the
  # process). The driving target script asserts a non-zero exit so this
  # function must never be wrapped in a rescue.
  def crash do
    crash_inner()
  end

  def crash_inner do
    raise ArgumentError, message: "m5 fixture crash"
  end
end
