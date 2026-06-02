@echo off
:: ccg pre-commit hook for TortoiseSVN
:: Register in: TortoiseSVN Settings → Hook Scripts → pre_commit_hook
:: Working Copy Path: <your wc root>
:: Command Line: "C:\path\to\ccg-precommit.bat" %WC% %MESSAGEFILE% %CWD%
::
:: Requires: Git for Windows (provides bash) installed and on PATH
:: Set CCG_SH to the absolute path of ccg.sh on this machine.

set CCG_SH=%~dp0..\ccg.sh

:: Normalize path separators for bash
:: Use double-quotes to safely handle paths with special characters (spaces, single quotes)
set "WC=%1"
set "WC=%WC:\=/%"

bash -c "cd \"%WC%\" && source \"%CCG_SH:\=/%\" && ccg_precommit_gate"
if %ERRORLEVEL% NEQ 0 (
    echo [ccg gate] Commit blocked. Fix issues reported above.
    exit 1
)
exit 0
