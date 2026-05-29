@echo off
REM ============================================================
REM  Diagnostico do site da Katy (http://192.168.1.147:8082)
REM  Uso:
REM    diagnostico.bat                    -> IP 192.168.1.147 porta 8082
REM    diagnostico.bat 192.168.1.147 8082 -> informa IP e porta
REM
REM  Rode de DENTRO da rede local. Se rodar no PROPRIO servidor,
REM  ele tambem checa a porta/servico localmente.
REM ============================================================
setlocal

set "HOST=%~1"
if "%HOST%"=="" set "HOST=192.168.1.147"
set "PORT=%~2"
if "%PORT%"=="" set "PORT=8082"
set "URL=http://%HOST%:%PORT%/"

echo.
echo === DIAGNOSTICO: %URL% ===
echo Data: %DATE% %TIME%
echo Maquina: %COMPUTERNAME%
echo.

echo ------------------------------------------------------------
echo ^>^> 1) Ping (a maquina responde na rede?)
echo ------------------------------------------------------------
ping -n 4 %HOST%
echo.

echo ------------------------------------------------------------
echo ^>^> 2) A porta %PORT% esta aberta? (teste TCP via PowerShell)
echo ------------------------------------------------------------
powershell -NoProfile -Command "$r = Test-NetConnection -ComputerName '%HOST%' -Port %PORT% -WarningAction SilentlyContinue; 'TcpTestSucceeded: ' + $r.TcpTestSucceeded"
echo.

echo ------------------------------------------------------------
echo ^>^> 3) Resposta HTTP do site
echo ------------------------------------------------------------
powershell -NoProfile -Command "try { $resp = Invoke-WebRequest -Uri '%URL%' -TimeoutSec 10 -UseBasicParsing; 'HTTP Status: ' + $resp.StatusCode } catch { 'ERRO: ' + $_.Exception.Message }"
echo.

echo ------------------------------------------------------------
echo ^>^> 4) [Somente se rodando NO servidor] Quem escuta na porta %PORT%?
echo ------------------------------------------------------------
netstat -ano | findstr ":%PORT%"
if errorlevel 1 echo [!] Nada escutando na porta %PORT% nesta maquina.
echo.

echo ------------------------------------------------------------
echo ^>^> 5) [Somente se rodando NO servidor] Containers Docker
echo ------------------------------------------------------------
where docker >nul 2>&1
if errorlevel 1 (
  echo [i] Docker nao instalado nesta maquina.
) else (
  echo --- Containers ativos ---
  docker ps
  echo.
  echo --- Containers parados ---
  docker ps -a --filter "status=exited"
)
echo.

echo ------------------------------------------------------------
echo ^>^> FIM
echo ------------------------------------------------------------
echo Copie TODA a saida acima e envie de volta para analise.
echo.
pause
endlocal
