defmodule AnglerWeb.SearchControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Hashtags
  alias Angler.Profiles

  setup do
    {:ok, _alpaca} = Profiles.create_profile(%{username: "alpaca"})
    Hashtags.ensure!("alpacas")
    :ok
  end

  test "GET /search/suggest returns accounts and hashtags", %{conn: conn} do
    body = conn |> get(~p"/search/suggest?q=alp") |> json_response(200)

    assert Enum.any?(body["accounts"], &(&1["acct"] == "alpaca"))
    assert Enum.any?(body["hashtags"], &(&1["name"] == "alpacas"))
    assert hd(body["hashtags"])["url"] == "/tags/alpacas"
  end

  test "local accounts link to the in-app profile route", %{conn: conn} do
    body = conn |> get(~p"/search/suggest?q=alpaca") |> json_response(200)
    account = Enum.find(body["accounts"], &(&1["acct"] == "alpaca"))
    assert account["url"] == "/@alpaca"
  end

  test "blank query returns empty buckets", %{conn: conn} do
    body = conn |> get(~p"/search/suggest?q=%20") |> json_response(200)
    assert body == %{"accounts" => [], "hashtags" => []}
  end
end
