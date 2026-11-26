; C1, C6: 一炁输入法 Windows 安装程序（NSIS）
Unicode true
!include "MUI2.nsh"
!include "x64.nsh"

Name "一炁输入法"
OutFile "../../dist/YiQi-Windows-Setup.exe"
InstallDir "$PROGRAMFILES64\YiQi"
RequestExecutionLevel admin

!define MUI_ICON "../icons/YiQi.ico"
!define MUI_UNICON "../icons/YiQi.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Section "一炁输入法" SecMain
  ; 升级前先结束旧进程，保留用户 %APPDATA%\YiQi 中的同步凭据与 *.custom.yaml
  nsExec::ExecToLog 'taskkill /F /IM YiQi.exe'
  nsExec::ExecToLog 'taskkill /F /IM WeaselServer.exe'
  nsExec::ExecToLog 'taskkill /F /IM YiQiServer.exe'
  Sleep 400

  SetOutPath "$INSTDIR"
  File "../../build/windows/stage/YiQi.exe"
  File /nonfatal "../../build/windows/stage/*.exe"
  File /nonfatal "../../build/windows/stage/*.dll"
  File /nonfatal "../../build/windows/stage/*.ime"
  File /nonfatal /r "../../build/windows/stage/data"

  ; C1: 指定安装根目录与用户词库目录，使输入法与一炁设置共享 qi_schema.txt 与 qi_hotkey.txt
  WriteRegStr HKLM "Software\Rime\Weasel" "WeaselRoot" "$INSTDIR"
  WriteRegStr HKCU "Software\Rime\Weasel" "RimeUserDir" "$APPDATA\YiQi\Rime"
  CreateDirectory "$APPDATA\YiQi\Rime"

  ; C1: 注册 Windows TSF 输入法并部署雾凇词库
  IfFileExists "$INSTDIR\WeaselSetup.exe" 0 +2
    nsExec::ExecToLog '"$INSTDIR\WeaselSetup.exe" /i'
  IfFileExists "$INSTDIR\WeaselDeployer.exe" 0 +2
    nsExec::ExecToLog '"$INSTDIR\WeaselDeployer.exe" /deploy'

  ; 创建开始菜单快捷方式与卸载信息
  CreateDirectory "$SMPROGRAMS\一炁输入法"
  CreateShortcut "$SMPROGRAMS\一炁输入法\一炁输入法.lnk" "$INSTDIR\YiQi.exe"
  CreateShortcut "$SMPROGRAMS\一炁输入法\卸载一炁输入法.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\YiQi" "DisplayName" "一炁输入法"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\YiQi" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\YiQi" "DisplayIcon" "$INSTDIR\YiQi.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\YiQi" "Publisher" "YiQi"

  ; 启动一炁输入法设置与后台剪贴板同步
  Exec '"$INSTDIR\YiQi.exe"'
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog 'taskkill /F /IM YiQi.exe'
  nsExec::ExecToLog 'taskkill /F /IM WeaselServer.exe'
  Sleep 300
  IfFileExists "$INSTDIR\WeaselSetup.exe" 0 +2
    nsExec::ExecToLog '"$INSTDIR\WeaselSetup.exe" /u'
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "YiQi"
  RMDir /r "$SMPROGRAMS\一炁输入法"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\YiQi"
SectionEnd
