# MediaVault

A native macOS app for downloading and browsing YouTube and Reddit content.

## Features

- **Sync channels and subreddits** — add any YouTube channel/playlist or Reddit user/subreddit and MediaVault keeps it up to date automatically
- **Media library** — browse your downloads in a grid with thumbnails, duration badges, and hover-to-preview
- **Video player** — built-in playback with an Up Next queue, theater mode (fills the window), and space-to-pause
- **Gallery viewer** — photo albums open in a grid; click any image for a full lightbox with filmstrip navigation
- **Private groups** — lock any group behind Face ID / Touch ID / system password
- **Liked content** — heart videos and photos; filter the library to liked items only
- **Thumbnails** — fetched from YouTube at download time; random-frame captures generated via ffmpeg for everything else; right-click any card to regenerate
- **Auto-update** — checks GitHub for a newer build on every launch and installs it silently in the background

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon only
- [yt-dlp](https://github.com/yt-dlp/yt-dlp), [gallery-dl](https://github.com/mikf/gallery-dl), and [ffmpeg](https://ffmpeg.org/) — the app walks you through installing them on first launch via Homebrew

## Installation

1. Go to the [Releases](../../releases) page and download the latest `MediaVault.zip`
2. Unzip and move `MediaVault.app` to your Applications folder
3. Right-click → Open on first launch (required once to bypass Gatekeeper on unsigned builds)
4. Pick a folder where downloads will live and follow the dependency setup prompt

After that, updates install automatically whenever a new build is available.

## Adding sources

Click **+** in the sidebar, paste a YouTube channel/playlist URL or a Reddit user/subreddit URL, and choose a sync schedule. MediaVault will download new content on that schedule and surface it in the library.
