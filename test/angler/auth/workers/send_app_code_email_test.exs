defmodule Angler.Auth.Workers.SendAppCodeEmailTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Swoosh.TestAssertions

  alias Angler.Auth.Workers.SendAppCodeEmail

  test "perform/1 builds and delivers the email" do
    assert :ok =
             perform_job(SendAppCodeEmail, %{"email" => "alice@example.com", "code" => "123456"})

    assert_email_sent(fn email ->
      assert email.to == [{"", "alice@example.com"}]
      assert email.subject =~ "123456"
      assert email.text_body =~ "123456"
    end)
  end

  test "enqueue/2 schedules a job in the :mailers queue" do
    assert {:ok, %Oban.Job{} = job} = SendAppCodeEmail.enqueue("alice@example.com", "654321")
    assert job.queue == "mailers"
    assert job.args == %{"email" => "alice@example.com", "code" => "654321"}
  end
end
