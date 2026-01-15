# Valet: Technical Overview & Architecture

Valet is a specialized local server and runner designed to host HTML5 applications and legacy NW.js games in a modern browser environment. It acts as a bridge, allowing desktop-like behavior (filesystem access, window management) within a standard web browser context.

## Core Philosophy

Valet aims to provide a "zero-install" runtime experience similar to Electron or NW.js but using the user's _existing_ installed browser (Edge, Chrome, or Firefox). This significantly reduces distribution size and leverages the security and performance updates of modern evergreen browsers.

### Key Principles

1.  **Browser Agnostic**: Works seamlessly with Microsoft Edge (Windows default), Google Chrome, and Mozilla Firefox.
2.  **NW.js Compatibility**: Simulates the NW.js environment (Node API, Window API) so legacy games run without modification.
3.  **Process Management**: Manages the browser process lifecycle, ensuring the server shuts down when the browser closes.
4.  **Zero-Configuration**: Auto-detects available browsers and uses sensible defaults derived from standard `package.json`.

---

## Browser Handling Strategy

A major challenge for Valet is normalizing behavior across different browser engines. While Chromium-based browsers (Edge, Chrome) share similar flags, Firefox requires significant customization to match "App Mode" behavior.

### 1. Chromium Family (Edge & Chrome)

Chromium browsers natively support "Application Mode" via command-line flags. Valet leverages these directly:

- **App Mode**: `--app=<url>` (Hides toolbar and address bar).
- **Window Management**: `--window-size=W,H`, `--window-position=X,Y`, `--start-maximized`.
- **Kiosk**: `--kiosk` (Exclusive fullscreen).
- **Profile**: `--user-data-dir` (Isolates session from user's main browser).

### 2. Mozilla Firefox

Firefox lacks native "App Mode" flags and command-line window positioning. Valet implements a complex "polyfill" strategy to achieve 1:1 parity with Chromium features:

#### **A. UI Customization (App Mode)**

Valet dynamically injects `userChrome.css` into the profile's `chrome` directory to hide UI elements when `showToolbar: false`:

```css
#TabsToolbar,
#nav-bar,
#PersonalToolbar {
  visibility: collapse !important;
}
```

_Note: Window controls (min/max/close) remain maintained._

#### **B. Window Management (Position & Size)**

Since Firefox lacks CLI flags for X/Y position, Valet pre-creates the `xulstore.json` file in the profile before launch. This JSON file dictates the window's restoring state:

```json
{
  "main-window": {
    "screenX": "300",
    "screenY": "150",
    "width": "1280",
    "height": "720",
    "sizemode": "maximized"
  }
}
```

#### **C. Behavior Normalization (user.js)**

Valet generates a strict `user.js` preference file to enforce behavior:

- **First-Run Bypass**: Disables "Welcome to Firefox", telemetry wizards, and "Restore Session" prompts.
- **Titlebar**: Forces `browser.tabs.drawInTitlebar = false` to ensure window controls are visible in App Mode.
- **Session Restore**: Disables `browser.sessionstore.resume_from_crash` to prevent "Restore Tabs?" infobars on restart.

---

## Node.js & NW.js API Simulation

To support applications written for NW.js (like RPG Maker MV/MZ games), Valet injects a `polyfill.js` script that mocks the Node.js environment.

### 1. The HTTP Bridge

Since browser JavaScript cannot access the OS filesystem directly, Valet exposes a set of internal HTTP endpoints. The polyfill translates synchronous Node calls into synchronous `XMLHttpRequest` calls (async versions use async XHR).

| Node API Call                  | HTTP Endpoint                 | Description            |
| :----------------------------- | :---------------------------- | :--------------------- |
| `fs.readFileSync(path)`        | `GET /__fs_read__?path=...`   | Reads file content     |
| `fs.writeFileSync(path, data)` | `POST /__fs_write__`          | Writes content to disk |
| `fs.existsSync(path)`          | `GET /__fs_exists__?path=...` | Checks file existence  |
| `fs.mkdirSync(path)`           | `POST /__fs_mkdir__`          | Creates directories    |

### 2. Node Global Objects

The polyfill recreates essential Node globals:

- `process`: Including `process.versions`, `process.platform`, `process.cwd()`.
- `require`: Custom implementation that returns mocks for `fs`, `path`, `os`, and `nw.gui`.
- `__dirname` / `__filename`: Calculated from the current URL.

### 3. NW.js Specifics

The `nw` global object is mocked to support window operations:

- `nw.Window.get()`: Maps to standard DOM `window` methods (e.g., `requestFullscreen()`, `resizeTo()`).
- `nw.App.argv`: Exposes command-line arguments.

---

## Lifecycle Management: The Heartbeat

To ensure the Valet server stops when the user closes the browser window, Valet implements a **Heartbeat Mechanism**:

1.  **Injection**: `heartbeat.js` is automatically injected into every served HTML page.
2.  **Ping**: The script sends a POST request to `/__heartbeat__` every 2 seconds.
3.  **Monitoring**: The Valet server tracks the last received heartbeat timestamp.
4.  **Shutdown**: If no heartbeat is received for **10 seconds** (configurable), Valet assumes the browser is closed and terminates its own process (as well as the browser process if configured).

---

## Configuration

Valet is configured via `package.json` in the root directory.

```json
{
  "name": "my-app",
  "browser": {
    "executable": "msedge", // "msedge", "chrome", "firefox", or absolute path
    "showToolbar": false, // false = App Mode / Kiosk-like
    "maximize": false, // Start window maximized
    "fullscreen": false, // Start in Kiosk/Exclusive Fullscreen mode
    "windowWidth": 1280,
    "windowHeight": 720,
    "userDataDir": ".valet_data" // Isolated profile directory
  },
  "valet": {
    "nodeApi": true // Enable Node.js/NW.js polyfills
  }
}
```
