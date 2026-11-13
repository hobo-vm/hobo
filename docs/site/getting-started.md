---
title: Getting started
description: Install hobo, build a VM from a recipe, and log in.
---

## Requirements

- An Apple Silicon Mac running macOS 27 or later.
- To build from source: Xcode 27 (Swift 6.4 or later) and `brew install lld go`.
- For Windows guests, a Windows on Arm ISO from
  [Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64).

## Install

```sh
git clone https://github.com/ggal625/hobo.git
cd hobo
make install      # builds and signs hobo, installs /usr/local/bin/hobo and /usr/local/share/hobo
```

`make install` may ask for your password if `/usr/local` needs it. `PREFIX=<dir> make install`
installs under another directory instead.

## Your first VM

```sh
hobo init --os linux     # write a Hobo.toml for the newest Ubuntu LTS
hobo create dev          # build a VM named dev from it
hobo start dev           # boot it in the background
hobo ssh dev             # log in as hobo
hobo stop dev
```

For a macOS guest, run `hobo images` to pick a build and `hobo init <build>` to pin the recipe to
it. Then read about [recipes](../features/recipes.md) and the rest of the features in the sidebar.
