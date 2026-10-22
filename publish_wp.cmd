@echo off
rem Runs publish_wp.ps1 without being blocked by the execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_wp.ps1" %*
