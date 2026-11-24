import AppKit

// Settings live in a bundle-identifier-keyed domain, so import the previous
// one before anything reads the stored language.
AppSettings.migrateDefaultsIfNeeded()
// The language override must be in place before the app bundle resolves its
// localizations, otherwise the first launch after a language change would
// still use the previous language.
AppLanguage.applyStoredLanguage()
DBooyvolApp.main()
