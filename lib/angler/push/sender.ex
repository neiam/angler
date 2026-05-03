defmodule Angler.Push.Sender do
  @moduledoc """
  Behaviour around the actual WebPush HTTP send. Two impls:

    * `Angler.Push.Sender.WebPushEncryption` — production. Encrypts via
      `:web_push_encryption` and POSTs to the subscription endpoint.
    * `Angler.Push.Sender.Test` — captures sends in `:persistent_term`
      so unit tests can assert on payloads without hitting the network.
  """

  @callback send(body :: binary(), subscription :: map()) ::
              {:ok, %{status_code: integer()}} | {:error, term()}
end

defmodule Angler.Push.Sender.WebPushEncryption do
  @moduledoc false
  @behaviour Angler.Push.Sender

  @impl true
  def send(body, subscription) do
    case WebPushEncryption.send_web_push(body, subscription) do
      {:ok, response} -> {:ok, %{status_code: response.status_code}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Angler.Push.Sender.Test do
  @moduledoc """
  Test sender — accumulates `{body, subscription}` tuples in
  `:persistent_term` keyed by `pid` so test processes can read what was
  "sent" without wiring up a mock HTTP server.
  """

  @behaviour Angler.Push.Sender

  @key {__MODULE__, :sent}

  @impl true
  def send(body, subscription) do
    list = :persistent_term.get(@key, [])
    :persistent_term.put(@key, [{body, subscription} | list])
    {:ok, %{status_code: 201}}
  end

  @doc "Read everything `send/2` has captured since the last `clear/0`."
  @spec sent() :: [{binary(), map()}]
  def sent, do: :persistent_term.get(@key, []) |> Enum.reverse()

  @doc "Drop captured sends."
  @spec clear() :: :ok
  def clear do
    :persistent_term.put(@key, [])
    :ok
  end
end
