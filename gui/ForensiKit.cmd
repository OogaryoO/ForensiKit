@echo off
rem ForensiKit one-click collection GUI (T10). Double-click to open; UAC will ask for admin rights when needed.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ForensiKit.Gui.ps1"
