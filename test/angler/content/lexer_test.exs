defmodule Angler.Content.LexerTest do
  use Angler.DataCase, async: false

  alias Angler.Content.Lexer
  alias Angler.Profiles

  test "plain text is escaped and wrapped in nothing" do
    %{html: html, mention_profile_ids: pids, hashtag_names: tags} = Lexer.render("<b>hi</b>")
    assert html == "&lt;b&gt;hi&lt;/b&gt;"
    assert pids == []
    assert tags == []
  end

  test "newlines become <br>" do
    %{html: html} = Lexer.render("line one\nline two")
    assert html == "line one<br>line two"
  end

  test "local mention is wrapped in an h-card span and resolves to profile" do
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})

    %{html: html, mention_profile_ids: pids, mention_usernames: names} =
      Lexer.render("hello @alice!")

    assert html =~ ~s(<span class="h-card">)
    assert html =~ ~s(>@alice</a></span>)
    assert pids == [alice.id]
    assert names == ["alice"]
  end

  test "unresolved mention falls back to literal text but still parses" do
    %{html: html, mention_usernames: names, mention_profile_ids: pids} =
      Lexer.render("hello @nobody")

    refute html =~ "<a"
    assert html =~ "@nobody"
    assert names == ["nobody"]
    assert pids == []
  end

  test "remote mention parses but does not link in this slice" do
    %{html: html, mention_usernames: names, mention_profile_ids: pids} =
      Lexer.render("cc @bob@remote.test")

    refute html =~ "<a"
    assert names == ["bob"]
    assert pids == []
  end

  test "hashtags are linked and case-folded in the name list" do
    %{html: html, hashtag_names: tags} = Lexer.render("#Photography is fun")
    assert html =~ ~s(class="mention hashtag")
    assert html =~ ">#Photography</a>"
    assert tags == ["photography"]
  end

  test "URLs become target=\"_blank\" links" do
    %{html: html} = Lexer.render("see https://example.com/foo")
    assert html =~ ~s(<a href="https://example.com/foo")
    assert html =~ ~s(target="_blank")
  end

  test "mixed entities render correctly" do
    {:ok, _} = Profiles.create_profile(%{username: "alice"})

    %{
      html: html,
      mention_usernames: ms,
      hashtag_names: ts
    } = Lexer.render("hi @alice — try #photography or visit https://example.com")

    assert html =~ "@alice"
    assert html =~ "#photography"
    assert html =~ "https://example.com"
    assert ms == ["alice"]
    assert ts == ["photography"]
  end

  test "URL takes precedence over hashtag inside it" do
    %{html: html, hashtag_names: tags} = Lexer.render("https://example.com/#section")
    # The whole URL should be one anchor, no separate #section linkified.
    assert html =~ ~s(href="https://example.com/#section")
    refute html =~ ~s(class="mention hashtag")
    # Note: the hashtag regex still scans the text *outside* of the URL match,
    # so #section here is not double-emitted because of the dedupe_overlapping
    # pass.
    assert tags == []
  end

  test "no false-positive mention inside email-like text" do
    %{html: html, mention_usernames: ms} = Lexer.render("user@example.com")
    refute html =~ "<a"
    assert ms == []
  end
end
