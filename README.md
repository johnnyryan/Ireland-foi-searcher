# FOI Search

A free Mac app by Johnny Ryan for searching Irish Freedom of Information disclosures listed on [publicinformation.ie](https://publicinformation.ie/bodies/).

- **Responses tab:** full-text search of every PDF linked as "FOI Request Files", page by page.
- **Requests tab:** search of the FOI requests themselves: what was asked, by what type of requester, the decision and its date, and the public body.
- Optional date range and public body filter, with CSV export of results.
- Scanned PDFs are read with the Mac's built-in text recognition.
- New disclosures are downloaded automatically, at most once a day.

## Install

Requires a Mac with Apple Silicon (M1 or later) and macOS 12 or later.

1. Copy **FOI Search.app** to your Applications folder.
2. The first time, right-click the app and choose **Open**, then **Open** again. The app is not signed with an Apple developer certificate, so macOS asks this once.

The first launch downloads about 1,100 PDFs, which takes 10 to 20 minutes. You can search while it runs. Downloaded files are kept in `~/Library/Application Support/FOI Search`.

## Build from source

You need Apple's free Command Line Tools (`xcode-select --install`). Then run:

```bash
./build.sh
```

This creates `FOI Search.app` in the parent folder.

## Licence

Free and open source under the [MIT License](LICENSE). You may use, copy, change and share it, for any purpose, at no cost. The only condition is to keep the copyright and licence notice.

The FOI data and documents belong to the public bodies that published them.
