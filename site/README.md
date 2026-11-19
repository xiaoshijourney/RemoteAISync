# RemoteAISync Product Site

This directory contains the static product site for RemoteAISync.

## Local preview

From the repository root:

```powershell
python -m http.server 8790 --directory site
```

Open `http://127.0.0.1:8790/` in a browser. The site has no build step and can be deployed to any static host.

## Deployment

Upload the contents of `site/` to the static hosting provider of your choice. Keep the `assets/` directory beside `index.html` so the product screenshots and brand mark resolve correctly.

The page is intentionally dependency-light: fonts are loaded from Google Fonts when network access is available, and the layout remains usable with the system font fallback when it is not.
