defmodule Angler.Media.LicenseTest do
  use ExUnit.Case, async: true

  alias Angler.Media.License

  describe "get/1" do
    test "returns the license object for a known CC id" do
      assert %{id: 11, title: "CC BY", url: "https://creativecommons.org/licenses/by/4.0/"} =
               License.get(11)
    end

    test "accepts a string id" do
      assert %{id: 11} = License.get("11")
    end

    test "returns nil for All Rights Reserved (id 1)" do
      assert License.get(1) == nil
      assert License.get("1") == nil
    end

    test "returns nil for unknown / blank values" do
      assert License.get(999) == nil
      assert License.get(nil) == nil
      assert License.get("nonsense") == nil
    end
  end

  describe "valid?/1" do
    test "true for known ids, false otherwise" do
      assert License.valid?(1)
      assert License.valid?("16")
      refute License.valid?(2)
      refute License.valid?(nil)
    end
  end

  describe "normalize_stored/1" do
    test "keeps a real license id as a string" do
      assert License.normalize_stored(12) == "12"
      assert License.normalize_stored("12") == "12"
    end

    test "drops the implicit default and invalid values" do
      assert License.normalize_stored(1) == nil
      assert License.normalize_stored(nil) == nil
      assert License.normalize_stored(2) == nil
      assert License.normalize_stored("") == nil
    end
  end

  test "all/0 is the full Pixelfed-numbered set" do
    ids = License.all() |> Enum.map(& &1.id)
    assert ids == [1, 5, 6, 11, 12, 13, 14, 15, 16]
  end
end
