Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 切换到 VBS 所在目录，相当于 cd /d "%~dp0"
shell.CurrentDirectory = fso.GetParentFolderName(WScript.ScriptFullName)

' 0 = 隐藏窗口
' True = 等待 Python 执行结束
exitCode = shell.Run("python.exe ""windows_mirage.py""", 0, True)

' 相当于 if errorlevel 1 pause
If exitCode <> 0 Then
    MsgBox "windows_mirage.py 执行失败，退出代码：" & exitCode, 16, "Python Error"
End If