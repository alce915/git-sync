@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0sync-project.ps1" %*
