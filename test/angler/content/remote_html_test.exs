defmodule Angler.Content.RemoteHtmlTest do
  use ExUnit.Case, async: true

  alias Angler.Content.RemoteHtml

  @html ~S|<p>hi <a href="https://pixelfed.social/discover/tags/Cats?src=hash" class="mention hashtag" rel="tag">#<span>Cats</span></a> <a href="https://x.y/tags/dogs" class="hashtag">#dogs</a> <script>alert(1)</script><img src=x onerror=alert(1)> <a href="javascript:alert(1)">x</a> <span class="h-card"><a href="https://m.s/@a" class="u-url mention">@<span>a</span></a></span></p>|

  test "drops scripts, handlers and javascript: links; keeps mention markup" do
    out = RemoteHtml.clean(@html)
    refute out =~ "<script"
    refute out =~ "onerror"
    refute out =~ "javascript:"
    assert out =~ ~s(class="u-url mention")
  end

  test "points the post's own hashtags at our tag page, case-insensitively" do
    out = RemoteHtml.clean(@html, ["cats"])
    assert out =~ ~s(href="#{AnglerWeb.Endpoint.url()}/tags/cats")
    refute out =~ "pixelfed.social/discover/tags"
    # Not one of the post's tags: left as the origin's link.
    assert out =~ ~s(href="https://x.y/tags/dogs")
  end

  test "nil and empty" do
    assert RemoteHtml.clean(nil) == ""
    assert RemoteHtml.clean("", ["x"]) == ""
  end
end
