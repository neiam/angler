defmodule Angler.Auth.RestrictedNames do
  @moduledoc """
  Usernames that are not allowed on signup.

  Mirrors the most important entries from Pixelfed's
  `App\Util\Lexer\RestrictedNames`. Full upstream list (~280 names of routes,
  reserved subdomains, common services) can be ported in a follow-up — for now
  we take the canonical "additional" list plus our own routes.

  Operators can extend at runtime via `Angler.Auth.RestrictedNames.add/1`
  (TODO once `Angler.Config` lands).
  """

  @additional ~w(
    autoconfig blog broadcasthost copyright download domainadmin domainadministrator
    errors events example faq faqs features ftp guest guests hostmaster
    imap info information is isatap it localdomain localhost mail
    mailer-daemon mailerdaemon marketing me mis mx no-reply nobody noc
    noreply ns0 ns1 ns2 ns3 ns4 ns5 ns6 ns7 ns8 ns9 owner pop pop3
    postmaster pricing root sales security signin signout smtp src
    ssladmin ssladministrator sslwebmaster sys sysadmin system tutorial
    tutorials usenet uucp webmaster wpad
  )

  # Names colliding with our own routes / namespaces.
  @ours ~w(
    admin api app apps auth dev i instance oauth p settings static stories users storage
    well-known robots.txt favicon.ico
  )

  @reserved MapSet.new(@additional ++ @ours, &String.downcase/1)

  @spec restricted?(String.t()) :: boolean()
  def restricted?(name) when is_binary(name) do
    MapSet.member?(@reserved, String.downcase(name))
  end

  @spec all() :: [String.t()]
  def all, do: MapSet.to_list(@reserved)
end
