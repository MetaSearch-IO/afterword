# Afterword agent instructions

## Delivering app fixes

- After an Afterword app fix builds successfully, update the Spotlight-indexed
  `~/Applications/Afterword.app` from the build containing that fix. A build in
  `.build/Afterword.app` alone is not delivered to the user.
- Build from the intended change without unrelated uncommitted source edits.
- Check for active recording or processing before replacing or restarting the
  installed app. If either is active, defer installation and report that the
  installed app is still on the previous build.
- For an idle app, quit it, copy the signed bundle with `ditto`, verify it with
  `codesign --verify --strict`, register it with Launch Services, request
  Spotlight indexing, and confirm `mdfind` returns the installed app. Reopen
  the installed path and verify it remains running. Report any incomplete step
  instead of saying the fix is installed.
