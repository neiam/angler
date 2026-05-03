defmodule Angler.Auth.ScopeTest do
  use ExUnit.Case, async: true

  alias Angler.Auth.Scope

  describe "has_scope?/2" do
    test "exact match" do
      assert Scope.has_scope?(%Scope{scopes: ["read"]}, "read")
      assert Scope.has_scope?(%Scope{scopes: ["read:accounts"]}, "read:accounts")
    end

    test "parent scope covers child" do
      scope = %Scope{scopes: ["read"]}
      assert Scope.has_scope?(scope, "read:accounts")
      assert Scope.has_scope?(scope, "read:statuses")
    end

    test "child scope does NOT cover parent" do
      scope = %Scope{scopes: ["read:accounts"]}
      refute Scope.has_scope?(scope, "read")
      refute Scope.has_scope?(scope, "read:statuses")
    end

    test "different parent does not cover" do
      scope = %Scope{scopes: ["read"]}
      refute Scope.has_scope?(scope, "write")
      refute Scope.has_scope?(scope, "write:statuses")
    end

    test "multiple granted scopes are checked" do
      scope = %Scope{scopes: ["read", "write:statuses"]}
      assert Scope.has_scope?(scope, "read:accounts")
      assert Scope.has_scope?(scope, "write:statuses")
      refute Scope.has_scope?(scope, "write")
      refute Scope.has_scope?(scope, "follow")
    end

    test "nil scope is never satisfied" do
      refute Scope.has_scope?(nil, "read")
    end

    test "empty scope list" do
      refute Scope.has_scope?(%Scope{scopes: []}, "read")
    end
  end
end
