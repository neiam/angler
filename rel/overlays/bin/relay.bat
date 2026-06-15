@echo off
if "%~1"=="list" (
  call "%~dp0\angler" rpc "Angler.Release.relay_list()"
) else if "%~1"=="follow" (
  call "%~dp0\angler" rpc "Angler.Release.relay_follow(\"%~2\")"
) else if "%~1"=="unfollow" (
  call "%~dp0\angler" rpc "Angler.Release.relay_unfollow(\"%~2\")"
) else if "%~1"=="enable" (
  call "%~dp0\angler" rpc "Angler.Release.relay_enable(\"%~2\")"
) else if "%~1"=="disable" (
  call "%~dp0\angler" rpc "Angler.Release.relay_disable(\"%~2\")"
) else (
  echo Usage: relay {list ^| follow ^<actor_url^> ^| unfollow ^<actor_url^|id^> ^| enable ^<id^> ^| disable ^<id^>}
  exit /b 1
)
