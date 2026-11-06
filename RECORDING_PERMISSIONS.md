# Recording permission after app updates

Afterword can ask for Screen & System Audio Recording access again even while
its switch in System Settings is on. On this Mac, the app build script falls
back to ad hoc signing when no signing identity is supplied. Ad hoc signatures
identify a specific build, so macOS can treat a rebuilt app as a different
app for privacy permissions. Apple documents this in
[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
and confirms the repeated ScreenCaptureKit prompt for ad hoc builds in
[this Developer Forums thread](https://developer.apple.com/forums/thread/819406).

On November 6, 2026, the worktree had no `.build/afterword-signing-identity`,
`Scripts/build-app.sh` signed with `-`, and the installed app prompted again.
The existing `Afterword Local Signing` certificate was present in Keychain.
It signed and passed `codesign --verify --strict` on the host, but the build
script did not look for its identity file in the main worktree. An enabled
privacy switch did not prove the ad hoc build could capture.

For future app builds:

1. Use the same signing identity for every build and worktree. The build script
   checks `.build/afterword-signing-identity` in the current worktree and the
   main worktree. Check the resulting bundle on the host; sandboxed Keychain
   checks can give misleading trust errors.
2. Verify the bundle with `codesign --verify --strict` and inspect its
   designated requirement with `codesign -dr - Afterword.app`. Do not install
   an ad hoc build as the everyday app.
3. After changing the signing identity, grant Screen & System Audio Recording
   access once, quit Afterword completely, and reopen it. Apple's
   [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
   says a restart is needed after granting permission.
4. Test a short real recording before calling an installed build working.

Repeatedly toggling the privacy switch cannot make an ad hoc signature stable
across future builds. If the prompt recurs, check signing first.
