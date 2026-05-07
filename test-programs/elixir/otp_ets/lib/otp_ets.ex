defmodule OtpEts do
  @moduledoc """
  ETS fixture for the M17 OTP fixture matrix. Drives :ets.new/2,
  :ets.insert/2, :ets.lookup/2, :ets.update_counter/3, :ets.delete/1,
  and :ets.tab2list/1. The recorder traces these as MFA call events
  with module=`:ets` so a downstream reader sees ETS access logged as
  trace events.
  """

  def main do
    table = :ets.new(:otp_ets_fixture, [:set, :protected])
    :ets.insert(table, {:k1, 1})
    :ets.insert(table, {:k2, 5})
    :ets.update_counter(table, :k1, {2, 41})
    [{:k1, k1}] = :ets.lookup(table, :k1)
    [{:k2, k2}] = :ets.lookup(table, :k2)
    true = k1 == 42
    true = k2 == 5

    pairs = :ets.tab2list(table) |> Enum.sort()
    true = pairs == [{:k1, 42}, {:k2, 5}]

    :ets.delete(table)
    IO.puts("ets-ok: #{k1 + k2}")
    :ok
  end
end
