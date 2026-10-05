# Forever Addons

**Client:** World of Warcraft: Forever (`_classic_beta_`, Interface **16001**, build 1.60.x)

Public monorepo of Forever-compatible addons. Each folder under `addons/` is a separate installable product — take only what you need.

| Addon | Folder(s) | Version |
|---|---|---|
| **ElvUI Forever** | `ElvUI`, `ElvUI_Libraries`, `ElvUI_Options` | 1.0.0 |
| **Clique Forever** | `CliqueForever` | 1.0.0 |
| **Dynamic Panels** | `DynamicPanels` | 1.0.0 |

Not Tortoise 1.12, not WotLK 3.3.5, not retail Mainline.

## Install

1. Download this repo (or a [Release](../../releases) zip for one addon).
2. Copy the folder(s) you want into:
   `World of Warcraft\_classic_beta_\Interface\AddOns\`
3. Restart Forever (`WowB.exe`) or `/reload`, and enable the addons.

### ElvUI Forever

Copy all three: `ElvUI`, `ElvUI_Libraries`, `ElvUI_Options`.

Personal Forever port of [ElvUI](https://github.com/tukui-org/ElvUI) (retail **v15.13** Mainline load path + Forever fixes). **Not** an official Tukui / ElvUI release.

- Keep folder names `ElvUI*` (required by ElvUI’s license).
- GitHub only — do **not** republish on CurseForge or Wago.
- We will remove this port if the original authors request it.

### Clique Forever

Copy `CliqueForever`. Open the spellbook tab or `/clique`.

Forever port of Clique (click-casting). Folder name is `CliqueForever` so it does not collide with retail Clique.

### Dynamic Panels

Copy `DynamicPanels`. Hold **Ctrl+Shift** and drag Blizzard panel headers to move; resize from the bottom-right handle. Skips ElvUI frames. `/dp` for options.

## Releases

Prefer the per-addon zips on the [Releases](../../releases) page:

- `ElvUI-Forever-1.0.0.zip` — the three `ElvUI*` folders
- `CliqueForever-1.0.0.zip` — `CliqueForever`
- `DynamicPanels-1.0.0.zip` — `DynamicPanels`

## License

| Addon | Terms |
|---|---|
| ElvUI* | See `addons/ElvUI/LICENSE.txt`. Modifications for private use; **GitHub upload allowed**; do not rename folders; keep copyright notice. |
| Clique Forever | Upstream Clique terms ship in `addons/CliqueForever/LICENSE.txt` and `COPYING.txt`. Forever compatibility fork by orbit0r; remove on upstream request. |
| Dynamic Panels | orbit0r — free to use and modify for Forever. |

## Credits

- ElvUI: Elv, Simpy, and Tukui contributors
- Clique: Cladhaire / jnwhiteh
- Forever ports and Dynamic Panels: orbit0r
