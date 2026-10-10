@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Suivi du sommeil v2 - reception des nuits de l app iPhone Sommeil
set PYTHONIOENCODING=utf-8
if exist .venv\Scripts\python.exe (
  .venv\Scripts\python.exe recevoir_iphone.py %*
  goto fin
)
where py >nul 2>nul
if errorlevel 1 (
  echo  Python est introuvable. Lance d abord 1_INSTALLER.bat
  goto fin
)
py -3 recevoir_iphone.py %*
:fin
pause
