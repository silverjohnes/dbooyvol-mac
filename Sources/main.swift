import AppKit

// The language override must be in place before the app bundle resolves its
// localizations, otherwise the first launch after a language change would
// still use the previous language.
AppLanguage.applyStoredLanguage()
DBooyvolApp.main()
