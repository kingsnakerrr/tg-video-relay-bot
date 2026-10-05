# iPhone direct download for TikTok and Douyin

`POST /resolve` is experimental. It asks the VPS to extract a single-file MP4 address without downloading the video and checks the first bytes before offering direct mode. The phone can then fetch the MP4 from the media host directly. `/download` remains available when extraction cannot produce a readable direct link.

Use the existing `SUBMIT_API_SECRET`. Submit form fields `secret` and `url` to `http://YOUR_VPS:8787/resolve`. A successful response looks like:

```json
{"ok":true,"mode":"direct","url":"https://media.example/video.mp4","headers":{"User-Agent":"...","Referer":"..."},"format_id":"h264_720p","height":720}
```

If extraction is unavailable, the API returns HTTP 200 with `{"ok":false,"mode":"server","error":"..."}`. A bad secret returns HTTP 403. Only TikTok and Douyin source links are accepted for direct extraction; other platforms should continue using the existing `/download` flow.

## Shortcut flow

1. Receive URL or text from the Share Sheet and extract the first video URL, as in the current shortcut.
2. Use **Get Contents of URL** with `POST`, form body `secret` and `url`, to call `/resolve`.
3. Read the `ok` field from the returned dictionary. If it is true, read `url`, then use **Get Contents of URL** with `GET` to fetch that URL. Pass through the returned `headers` where the Shortcut editor permits request headers.
4. Save the fetched video to Photos. Show the success notification **after** the save action succeeds.
5. If `ok` is false, call the existing `/download` URL with the same `secret` and source `url`, then save its video response. Never pass a JSON error response into **Save to Photo Album**.

Direct media URLs can expire quickly. Some TikTok URLs are tied to the IP or proxy used during extraction: the VPS currently resolves TikTok through the Japan SOCKS tunnel. A tested TikTok link returned HTTP 403 even from that proxy, so `/resolve` correctly chose VPS fallback for it. A successful server-side probe still does not guarantee the iPhone's network can read the URL. If fetching a direct URL fails, use the existing VPS download action. Douyin extraction still needs fresh Douyin cookies when the platform requests them.

This endpoint is opt-in; existing Telegram and `/download` requests are unchanged. Prefer an HTTPS reverse proxy for the iPhone shortcut, because the request contains the API secret and the response contains a signed media URL.
