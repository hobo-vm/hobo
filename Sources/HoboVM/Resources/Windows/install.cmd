@echo off
rem Installs Windows from WinPE, in place of Windows Setup, then powers off. Called by the answer
rem file's windowsPE pass as: install.cmd <drive of the media's data partition>. Hobo reads the
rem result from hobo\result and hobo\install.log on that partition once the VM has stopped.
setlocal EnableExtensions EnableDelayedExpansion
set MEDIA=%~1
set HOBO=%MEDIA%\hobo
set LOG=%HOBO%\install.log
echo [%time%] installing from %MEDIA% > %LOG%

rem The VM's disk is its only NVMe one: the install media is USB. "NVMe" is the same in any language.
set DISK=
for /l %%d in (0,1,7) do (
  (echo select disk %%d& echo detail disk) > X:\detail.txt
  for /f "tokens=*" %%l in ('diskpart /s X:\detail.txt') do (
    set LINE=%%l
    if not "!LINE:NVMe=!"=="!LINE!" if not defined DISK set DISK=%%d
  )
)
if not defined DISK (echo no NVMe disk found >> %LOG% & goto failed)
echo [%time%] disk %DISK% >> %LOG%

rem Windows goes last, with no recovery partition after it, so that hobo set --disk can grow it.
(
  echo select disk %DISK%
  echo clean
  echo convert gpt
  echo create partition efi size=260
  echo format quick fs=fat32 label=System
  echo assign letter=S
  echo create partition msr size=16
  echo create partition primary
  echo format quick fs=ntfs label=Windows
  echo assign letter=W
) > X:\partition.txt
diskpart /s X:\partition.txt >> %LOG% 2>&1 || goto failed

rem Windows 11 Pro if the image has it, otherwise whatever edition it starts with.
set IMAGE=%MEDIA%\sources\install.wim
if not exist %IMAGE% set IMAGE=%MEDIA%\sources\install.esd
set EDITION=/Name:"Windows 11 Pro"
dism /Get-ImageInfo /ImageFile:%IMAGE% %EDITION% > nul 2>&1 || set EDITION=/Index:1
echo [%time%] applying %EDITION% >> %LOG%
dism /Apply-Image /ImageFile:%IMAGE% %EDITION% /ApplyDir:W:\ /Compact >> %LOG% 2>&1 || goto failed
echo [%time%] adding drivers >> %LOG%
dism /Image:W:\ /Add-Driver /Driver:%HOBO%\drivers /Recurse >> %LOG% 2>&1 || goto failed

rem The answer file's later passes, and what SetupComplete.cmd runs on the way to the first logon.
mkdir W:\Windows\Panther W:\Windows\Setup\Scripts W:\ProgramData\Hobo
copy /y %MEDIA%\autounattend.xml W:\Windows\Panther\unattend.xml >> %LOG% || goto failed
copy /y %HOBO%\SetupComplete.cmd W:\Windows\Setup\Scripts\ >> %LOG% || goto failed
xcopy /y /e %HOBO%\guest W:\ProgramData\Hobo\ >> %LOG% || goto failed

bcdboot W:\Windows /s S: /f UEFI >> %LOG% 2>&1 || goto failed
rem The driver registered this path when the media booted; from the next boot the firmware finds it here.
mkdir S:\EFI\hobo
copy /y %HOBO%\framebuffer.efi S:\EFI\hobo\ >> %LOG% || goto failed

echo [%time%] done >> %LOG%
echo OK> %HOBO%\result
goto off

:failed
echo [%time%] failed >> %LOG%
echo FAILED> %HOBO%\result

:off
wpeutil shutdown
rem Setup carries on if this script returns, so stay here until the power goes.
:wait
ping -n 60 127.0.0.1 > nul
goto wait
