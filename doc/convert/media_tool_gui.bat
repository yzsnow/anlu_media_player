@echo off
rem FPGA media player - asset tool (GUI)
cd /d "%~dp0"
where pythonw >nul 2>nul && (start "" pythonw media_tool_gui.py & exit /b)
python media_tool_gui.py
if errorlevel 1 pause
