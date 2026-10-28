defmodule Angler.Stories.RemoteMediaTest do
  use ExUnit.Case, async: true

  alias Angler.Stories.RemoteMedia

  defp png(w, h), do: <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", w::32, h::32, 8, 6, 0, 0, 0>>

  test "sniffs the types we take" do
    assert RemoteMedia.sniff(<<0xFF, 0xD8, 0xFF, 0xE0>>) == "image/jpeg"
    assert RemoteMedia.sniff(png(1, 1)) == "image/png"
    assert RemoteMedia.sniff("GIF89a" <> <<1::16>>) == "image/gif"
    assert RemoteMedia.sniff("RIFF" <> <<0::32>> <> "WEBPVP8X") == "image/webp"
    assert RemoteMedia.sniff(<<24::32, "ftypavif", 0::32>>) == "image/avif"
    assert RemoteMedia.sniff(<<24::32, "ftypisom", 0::32>>) == "video/mp4"
    assert RemoteMedia.sniff(<<0x1A, 0x45, 0xDF, 0xA3, 0>>) == "video/webm"
    assert RemoteMedia.sniff("<html>") == nil
  end

  test "reads image dimensions from headers" do
    assert RemoteMedia.dimensions(png(1080, 1920)) == {1080, 1920}

    assert RemoteMedia.dimensions(<<"GIF89a", 1080::little-16, 1920::little-16, 0>>) ==
             {1080, 1920}

    vp8x =
      <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0::32, 1079::little-24, 1919::little-24>>

    assert RemoteMedia.dimensions(vp8x) == {1080, 1920}

    bits = Bitwise.bor(1079, Bitwise.bsl(1919, 14))
    vp8l = <<"RIFF", 0::32, "WEBP", "VP8L", 5::little-32, 0x2F, bits::little-32>>
    assert RemoteMedia.dimensions(vp8l) == {1080, 1920}

    # A JPEG with an APP0 segment before its SOF2 frame header.
    jpeg =
      <<0xFF, 0xD8, 0xFF, 0xE0, 4::16, 0, 0, 0xFF, 0xC2, 11::16, 8, 1920::16, 1080::16, 1, 0>>

    assert RemoteMedia.dimensions(jpeg) == {1080, 1920}
    assert RemoteMedia.dimensions(<<0xFF, 0xD8, 0xFF, 0xE0, 200::16, 0>>) == nil

    avif = <<24::32, "ftypavif", 0::64, "ispe", 0::32, 1080::32, 1920::32>>
    assert RemoteMedia.dimensions(avif) == {1080, 1920}
  end

  test "tells hotlinked paths from stored ones" do
    assert RemoteMedia.hotlinked?("https://cdn.example/s/1.jpg")
    refute RemoteMedia.hotlinked?("m/v2/1/st/story-abc.jpg")
    refute RemoteMedia.hotlinked?(nil)
  end
end
