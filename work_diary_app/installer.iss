; 极简工作日记 - Inno Setup 安装脚本

#define MyAppName "极简工作日记"
#define MyAppVersion "1.0.22"
#define MyAppPublisher "胜洪宇"
#define MyAppExeName "work_diary_app.exe"
#define MyAppSource "E:\Code\WorkDiary\work_diary_app\build\windows\x64\runner\Release"

; Fail packaging if the app-local Visual C++ runtime is missing.
#if !FileExists(MyAppSource + "\vcruntime140_1.dll") || !FileExists(MyAppSource + "\vcruntime140.dll") || !FileExists(MyAppSource + "\msvcp140.dll")
  #error Required Visual C++ runtime missing. Run flutter build windows --release first.
#endif

[Setup]
; 应用信息
AppId={{B7F3A2E1-5C4D-4E8B-9A6F-1D2E3F4A5B6C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://work.jspang.com
AppSupportURL=https://work.jspang.com
AppUpdatesURL=https://work.jspang.com

; 默认安装目录（用户可以改）
DefaultDirName={autopf}\WorkDiary
DefaultGroupName=极简工作日记

; 输出
OutputDir=E:\Code\WorkDiary
OutputBaseFilename=WorkDiary_Setup_v{#MyAppVersion}

; 压缩
Compression=lzma2
SolidCompression=yes

; 图标
SetupIconFile=E:\Code\WorkDiary\work_diary_app\assets\icons\tray.ico

; 权限
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; 卸载
UninstallDisplayIcon={app}\{#MyAppExeName}
; Let the uninstaller remove files created by the app or older updaters.
Uninstallable=yes

; 语言
ShowLanguageDialog=no

[Languages]
; 简体中文安装界面（官方翻译，随 Inno Setup 6 仓库维护）
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项:"

[Files]
; 复制 Release 目录所有文件
Source: "{#MyAppSource}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Registry]
; The app writes this per-user auto-start value at runtime.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "WorkDiary"; Flags: uninsdeletevalue

[UninstallDelete]
; Remove the complete installed program directory, including runtime-created files.
Type: filesandordirs; Name: "{app}"

[Icons]
; 开始菜单
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
; 桌面快捷方式（可选）
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 安装完成后启动
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteUserDataPage: TInputOptionWizardPage;

function UserDataDir: string;
begin
  Result := ExpandConstant('{userappdata}') + '\work_diary_app';
end;

procedure DeleteIfExists(const Path: string);
begin
  if DirExists(Path) then
    DelTree(Path, True, True, True)
  else if FileExists(Path) then
    DeleteFile(Path);
end;

procedure DeleteUpgradeSiblings;
var
  ParentDir: string;
  FindRec: TFindRec;
begin
  ParentDir := AddBackslash(ExtractFileDir(ExpandConstant('{app}')));
  DeleteIfExists(ParentDir + 'Release_old');
  DeleteIfExists(ParentDir + 'Release_failed');
  DeleteIfExists(ParentDir + 'Release_new');
  if FindFirst(ParentDir + '.WorkDiary.upgrade-*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          DeleteIfExists(ParentDir + FindRec.Name);
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  if FindFirst(ParentDir + '.Release.upgrade-*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          DeleteIfExists(ParentDir + FindRec.Name);
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := True;
end;

procedure InitializeUninstallWizard;
begin
  DeleteUserDataPage := CreateInputOptionPage(
    wpWelcome,
    '本地数据',
    '选择是否删除本地数据',
    '默认保留工作日记、登录状态和日志。勾选后会同时删除本机保存的全部数据。',
    True,
    False);
  DeleteUserDataPage.Add('同时删除本地数据（不可恢复）');
  DeleteUserDataPage.Values[0] := False;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    DeleteUpgradeSiblings;
    if DeleteUserDataPage <> nil then
      if DeleteUserDataPage.Values[0] then
        DeleteIfExists(UserDataDir);
  end;
end;
