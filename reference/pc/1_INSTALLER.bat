@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Suivi du sommeil - installation
echo.
echo  ================================================
echo    SUIVI DU SOMMEIL - installation (une seule fois)
echo  ================================================
echo.
where py >nul 2>nul
if errorlevel 1 (
  echo  Python n'est pas encore installe. Installation automatique...
  echo.
  winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
  if errorlevel 1 (
    echo.
    echo  L'installation automatique a echoue.
    echo  Installe Python depuis https://www.python.org/downloads/
    echo  en cochant "Add python.exe to PATH", puis relance ce fichier.
    pause
    exit /b 1
  )
  echo.
  echo  Python est installe. FERME cette fenetre et relance 1_INSTALLER.bat
  pause
  exit /b 0
)
echo  Preparation de l'environnement...
if not exist .venv\Scripts\python.exe py -3 -m venv .venv
if not exist .venv\Scripts\python.exe (
  echo  Impossible de creer l'environnement Python.
  pause
  exit /b 1
)
echo  Telechargement des composants (quelques minutes)...
.venv\Scripts\python.exe -m pip install --upgrade pip >nul
.venv\Scripts\python.exe -m pip install -r requirements.txt
if errorlevel 1 (
  echo.
  echo  Probleme pendant le telechargement. Verifie la connexion internet et relance.
  pause
  exit /b 1
)
echo.
echo  Micros detectes (le Blue Yeti doit y etre si tu l'utilises) :
.venv\Scripts\python.exe -c "import sounddevice as sd; [print('   -', d['name']) for d in sd.query_devices() if d['max_input_channels']>0 and sd.query_hostapis(d['hostapi'])['name']=='MME']"
echo.
echo  ================================================
echo    Installation terminee !
echo    Double-clique maintenant sur 5_RECEVOIR_IPHONE.bat
echo  ================================================
pause
