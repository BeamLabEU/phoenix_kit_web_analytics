defmodule PhoenixKitWebAnalytics.Ring do
  @moduledoc false
  # Small in-memory ring buffers and counters, per node — the last N of
  # something (rate-limit denials, the client-address sample of
  # `IpHealth`) without a database row or a setting. One public ETS table,
  # owned by this process; writers write to it straight from the request
  # process. With the process not running every write is a no-op and every
  # read is empty.
  #
  # A ring is `{ring, slot}` rows, `slot = seq rem size`: a push overwrites
  # the oldest entry, so the table never grows past `size` per ring.

  use GenServer

  @table :phoenix_kit_web_analytics_rings

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds `item` to `ring`, keeping the last `size`. Never raises."
  @spec push(atom(), pos_integer(), term()) :: :ok
  def push(ring, size, item) when is_atom(ring) and is_integer(size) and size > 0 do
    seq = :ets.update_counter(@table, {:seq, ring}, {2, 1}, {{:seq, ring}, 0})
    :ets.insert(@table, {{ring, rem(seq, size)}, seq, item})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The last `size` items of `ring`, newest first."
  @spec list(atom(), pos_integer()) :: [term()]
  def list(ring, size) do
    newest =
      case :ets.lookup(@table, {:seq, ring}) do
        [{_, seq}] -> seq
        [] -> 0
      end

    @table
    |> :ets.match_object({{ring, :_}, :_, :_})
    |> Enum.filter(fn {_key, seq, _item} -> seq > newest - size end)
    |> Enum.sort_by(fn {_key, seq, _item} -> seq end, :desc)
    |> Enum.map(fn {_key, _seq, item} -> item end)
  rescue
    ArgumentError -> []
  end

  @doc "Adds `by` to the counter `key`. Never raises."
  @spec bump(term(), integer()) :: :ok
  def bump(key, by \\ 1) do
    :ets.update_counter(@table, {:count, key}, {2, by}, {{:count, key}, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The counter `key` (0 when never bumped)."
  @spec count(term()) :: non_neg_integer()
  def count(key) do
    case :ets.lookup(@table, {:count, key}) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Empties `ring` (tests, and a reset from the admin)."
  @spec clear(atom()) :: :ok
  def clear(ring) do
    :ets.match_delete(@table, {{ring, :_}, :_, :_})
    :ets.delete(@table, {:seq, ring})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
