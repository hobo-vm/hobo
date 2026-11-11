---
title: Shared clipboard
description: Copy on the Mac and paste in the guest, or the other way, while its window shows.
sidebar:
  order: 45
---

While a VM's window shows, its clipboard and the Mac's are one: copy text on the Mac and paste it
in the guest, or copy in the guest and paste on the Mac. There's nothing to install or turn on.

```sh
hobo view dev     # copy and paste both ways while this window shows
```

<!-- more -->

## When it's shared

- Only while the window shows. A headless VM, which is every VM an agent runs, never sees your
  clipboard, and nothing the guest copies reaches the Mac while you aren't looking.
- Your Mac's copies go to the guest when you click into its window, and while it stays in front.
- The guest's copies come to the Mac within about half a second.
- Text only, up to 16 MB. Images and files stay where they were copied; use
  [`hobo cp` or a shared folder](./getting-inside.md) for files.
- Windows guests get Windows line endings, and the Mac gets its own back.

## Guests

| Guest | Shared clipboard |
| --- | --- |
| macOS | Yes |
| Windows | Yes |
| Linux | Not yet |

The guest's side is hobo's own guest agent, which every VM already runs, so a VM created before
this needs nothing new. It needs the guest's desktop session to be logged in, as the VM's own user
is at boot.

## macOS's paste permission

The first time hobo reads the Mac's clipboard for a guest, macOS may ask whether Hobo can paste from
the app you copied in. Choose to always allow it. To change your mind later, use System Settings >
Privacy & Security > Paste. With Hobo denied, the guest still shares its copies with the Mac, but
doesn't get yours.
