@echo off
rem Windows runs this as SYSTEM once its own setup is done, before the first logon.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Hobo\setup.ps1 > C:\ProgramData\Hobo\setup.log 2>&1
