# Hamster King Tier Autopilot — Chrome extension

Manifest V3, active-tab-only port of the documented Windows v1.20 visual workflow. It uses the Chrome DevTools Protocol debugger permission for tab screenshots and mouse input. It does not inspect page DOM, call game APIs, intercept network traffic, read process memory, or disguise automation.

## Carried-over capabilities

- One building, up to five, all visible markers (maximum configured), marker-check-only mode, and Tier-2 recovery mode.
- **Up one tier per building** mode: selects each visible Tier-1 marker, performs one upgrade transition, then rescans and moves to the next building. The selected target tier is ignored in this mode.
- Tier 4+, Tier 5, or Tier 5+ targets.
- Screen-color/shape recognition for tier markers, action buttons, reward dialogs and map road click points; stable-frame checks; guarded click confirmation; limited retries; safe stops on unknown states.
- Pause/resume, emergency stop, active-tab change pause, configurable timeout/building limits, marker rescans, and downloadable run logs/screenshots.

## Install / run

1. Go to `chrome://extensions`, enable **Developer mode**, and select **Load unpacked**.
2. Choose this `chrome-extension` directory.
3. Open Hamster King in Chrome. Set the map to the intended district and open Tier-1-only filter; close dialogs. Ensure sufficient resources.
4. Open the extension popup, choose a conservative mode/target, and press **Start (paused)**. Verify Chrome's debugger-access notice and the game state before pressing **Resume**.
5. Keep the game tab active and do not pan/zoom while automation runs. If Chrome detaches the debugger or the tab closes, inspect the game manually before restarting.

The debugger permission is powerful and Chrome displays its use. Automation only controls the selected tab and cannot choose a tab or bring Chrome to the foreground. Popup buttons replace F8/F9. Run artifacts are browser downloads; the extension cannot write directly to the original Windows `logs` directory. Chrome may suspend/reload extensions, so this is not guaranteed to resume an interrupted run. The Tier-2 recovery option is only for the same building interrupted after Tier 2; confirm the game screen before using it.

Recognition was tuned to the original near-1920x1040 screenshots. Chrome's debugger infobar may reduce screenshot height; the extension accepts a viewport from 850 to 1080 px and maps screenshot coordinates to CSS viewport input. Marker detection excludes HUD/navigation bands. Road-click detection recognizes original blue-slate, dark-slate, and the recent nearly neutral charcoal pavement palette, while still requiring a fully clear central patch and independently found points. A selected marker that does not produce a recognized building panel is recorded and excluded for the current run; the extension continues only if it positively recognizes and closes the panel or confirms the map is restored. Otherwise it stops rather than clicking blindly. If no safe road is recognized, the run log includes a candidate-count diagnosis and saves `road_detection_*.png`. Browser zoom, scaling, overlays, and UI changes can still invalidate assumptions. Test marker-check and one-building mode before larger runs; live-game compatibility is not guaranteed.
