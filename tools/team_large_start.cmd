@echo off
rem Starts (or resumes) the large-field C.04.6 run from this worktree, log
rem appended to team_large_run.log. Arguments replace the default range:
rem   tools\team_large_start.cmd --first 1 --last 14000 --workers 6
cd /d "%~dp0.."
if "%~1"=="" (
  elixir tools\team_large_run.exs --first 1 --last 14000 --chunk 6 --workers 6 >> team_large_run.log 2>&1
) else (
  elixir tools\team_large_run.exs %* >> team_large_run.log 2>&1
)
