@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Suivi du sommeil - demarrage automatique du recepteur
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "LANCEUR=%STARTUP%\SuiviSommeil_recepteur.bat"
echo.
if exist "%LANCEUR%" goto desactiver
> "%LANCEUR%" echo @echo off
>> "%LANCEUR%" echo cd /d "%~dp0"
>> "%LANCEUR%" echo start "Suivi du sommeil" /min "%~dp05_RECEVOIR_IPHONE.bat"
if not exist "%LANCEUR%" (
  echo  Impossible d activer le demarrage automatique.
  goto fin
)
echo  Demarrage automatique ACTIVE.
echo.
echo  A chaque ouverture de session Windows, le recepteur de l app Sommeil
echo  s ouvrira tout seul, en fenetre reduite. L app pourra alors envoyer
echo  les nuits et lancer le Blue Yeti sans que tu touches au PC.
echo  Tant que le recepteur est ouvert, le PC ne se met pas en veille.
echo.
echo  Pour desactiver : double-clique a nouveau sur ce fichier.
goto fin
:desactiver
del "%LANCEUR%"
echo  Demarrage automatique DESACTIVE.
echo  Le recepteur ne s ouvrira plus tout seul. Tu peux toujours le lancer avec
echo  5_RECEVOIR_IPHONE.bat.
:fin
echo.
pause
