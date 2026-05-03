defmodule Angler.Federation.Webfinger do
  @moduledoc """
  RFC 7033 webfinger document builder + resource string parser.

  See `plans/federation/endpoints/get_well_known_webfinger.md`.
  """

  alias Angler.Profiles.Profile

  @type resource ::
          {:local, String.t()}
          | {:instance_actor, String.t()}
          | :invalid

  @doc """
  Parse a `?resource=` value into something we can resolve.

  Accepts:

  * `acct:user@host` — local lookup if `host` matches our domain.
  * `acct:domain@domain` — instance actor handle.
  * `https://domain/users/username` — local lookup.
  * `https://domain/@username` — local lookup.

  Returns `:invalid` for anything else (including foreign-domain references and
  malformed input). The caller maps that to a 400 response.
  """
  @spec parse_resource(String.t() | nil, String.t()) :: resource()
  def parse_resource(nil, _our_domain), do: :invalid
  def parse_resource("", _our_domain), do: :invalid

  def parse_resource("acct:" <> rest, our_domain) do
    case String.split(rest, "@", parts: 2) do
      [user, host] when host == our_domain ->
        cond do
          user == our_domain -> {:instance_actor, our_domain}
          valid_username?(user) -> {:local, user}
          true -> :invalid
        end

      _ ->
        :invalid
    end
  end

  def parse_resource("https://" <> _ = url, our_domain) do
    case URI.parse(url) do
      %URI{host: host} when host != our_domain -> :invalid
      %URI{path: "/users/" <> user} -> classify(user, our_domain)
      %URI{path: "/@" <> user} -> classify(user, our_domain)
      _ -> :invalid
    end
  end

  def parse_resource(_, _), do: :invalid

  defp classify(user, our_domain) do
    cond do
      user == our_domain -> {:instance_actor, our_domain}
      valid_username?(user) -> {:local, user}
      true -> :invalid
    end
  end

  defp valid_username?(user) when is_binary(user) do
    String.length(user) in 1..30 and
      Regex.match?(~r/^[A-Za-z0-9_.-]+$/, user)
  end

  defp valid_username?(_), do: false

  @doc "JRD describing the instance actor."
  @spec instance_actor_jrd(String.t()) :: map()
  def instance_actor_jrd(our_domain) do
    base = AnglerWeb.Endpoint.url()

    %{
      "subject" => "acct:#{our_domain}@#{our_domain}",
      "aliases" => [base <> "/i/actor"],
      "links" => [
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => base <> "/site/kb/instance-actor"
        },
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => base <> "/i/actor"
        },
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => base <> "/authorize_interaction?uri={uri}"
        }
      ]
    }
  end

  @doc "JRD describing a local profile."
  @spec profile_jrd(Profile.t(), String.t()) :: map()
  def profile_jrd(%Profile{} = profile, our_domain) do
    base = AnglerWeb.Endpoint.url()
    actor = base <> "/users/" <> profile.username
    html = base <> "/@" <> profile.username

    %{
      "subject" => "acct:#{profile.username}@#{our_domain}",
      "aliases" => [html, actor],
      "links" => [
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => html
        },
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => actor
        },
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => base <> "/authorize_interaction?uri={uri}"
        }
      ]
    }
  end
end
