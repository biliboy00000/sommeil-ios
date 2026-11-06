@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Telecommande
where py 1>NUL 2>NUL && (set PY=py -3) || (set PY=python)
if not exist ".venv\installe.txt" (
  echo Premiere installation, patiente une minute...
  if not exist ".venv\Scripts\python.exe" %PY% -m venv .venv
  if not exist ".venv\Scripts\python.exe" (echo. & echo Python n est pas installe. Installe-le depuis https://www.python.org/downloads/ en cochant "Add python.exe to PATH". & pause & exit /b 1)
  ".venv\Scripts\python.exe" -m pip install -q --upgrade pip
  ".venv\Scripts\python.exe" -m pip install -q -r requirements.txt || (echo Installation impossible, verifie ta connexion puis relance. & pause & exit /b 1)
  echo ok> ".venv\installe.txt"
)
".venv\Scripts\python.exe" serveur.py
pause
