defmodule AnglerWeb.InstagramImportLiveTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Import.Workers.InstagramImport

  setup do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    %{conn: conn, profile: profile}
  end

  test "anonymous visitors are redirected to login" do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(build_conn(), ~p"/settings/import/instagram")

    assert to =~ "/login"
  end

  test "renders the upload form for a logged-in user", ctx do
    {:ok, lv, html} = live(ctx.conn, ~p"/settings/import/instagram")
    assert html =~ "Import from Instagram"
    assert has_element?(lv, "input[type=file]")
    assert has_element?(lv, "button[type=submit]")
  end

  test "uploading a zip stages it and enqueues an import job", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/settings/import/instagram")

    archive =
      file_input(lv, "form", :archive, [
        %{name: "export.zip", content: "PK\x03\x04 not a real zip", type: "application/zip"}
      ])

    assert render_upload(archive, "export.zip") =~ "export.zip"

    lv |> element("form") |> render_submit(%{"visibility" => "unlisted"})

    assert_enqueued(worker: InstagramImport, args: %{"profile_id" => ctx.profile.id})

    [job] = all_enqueued(worker: InstagramImport)
    assert job.args["opts"]["visibility"] == "unlisted"
    assert File.exists?(job.args["zip_path"])

    on_exit(fn -> File.rm_rf(job.args["zip_path"]) end)

    # The page reflects the in-progress state.
    assert render(lv) =~ "Import in progress…"
  end

  test "submitting without a file shows an error", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/settings/import/instagram")

    html = lv |> element("form") |> render_submit(%{"visibility" => "public"})
    assert html =~ "Choose your Instagram export"
    assert [] == all_enqueued(worker: InstagramImport)
  end
end
