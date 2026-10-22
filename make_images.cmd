@echo off
rem Runs make_images.ps1 without being blocked by the execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_images.ps1" %*
