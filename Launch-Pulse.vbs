' Launches Pulse.ps1 with zero visible window - bypasses the Windows Terminal
' "default terminal app" issue where -WindowStyle Hidden alone can still flash
' a console window on Windows 11.
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""D:\Development\Pulse\Pulse.ps1""", 0, False
