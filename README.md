# Valet

**Valet** is a lightweight HTML5 games and standalone web applications launcher. It provides a built-in HTTP server and automated browser launcher with a clean, isolated environment.

## Features

- ✅ **Auto Port Detection** - No port conflicts
- ✅ **Tiny Size** - ~1 MB vs 200 MB for Electron/NW.js
- ✅ **Fast Startup** - 1-2 seconds
- ✅ **Console Output** - Always visible for debugging

## Quick Start

### Minimal Configuration

Create a `package.json` in your project directory:

```json
{
  "name": "my-app",
  "main": "index.html",
  "window": {
    "title": "My App",
    "width": 960,
    "height": 720
  }
}
```

Place `valet.exe` in the same directory and run:

```powershell
.\valet.exe
```

That's it! Valet will:

1. Auto-detect an available port
2. Start an HTTP server
3. Launch Edge/Chrome in app mode
4. Display console output for debugging

## Configuration

### Full Configuration Example

```json
{
  "name": "my-game",
  "main": "index.html",
  "chromium-args": "--force-color-profile=srgb",
  "window": {
    "title": "My Game",
    "width": 1280,
    "height": 720,
    "position": "center"
  },
  "valet": {
    "server": {
      "port": 8080
    },
    "browser": {
      "executable": "msedge",
      "userDataDir": ".valet_data",
      "incognitoMode": true
    }
  }
}
```

### Configuration Options

**NW.js Compatible Fields:**

- `name` - Application name (default: `"valet-app"`)
- `main` - Entry HTML file (default: `"index.html"`)
- `chromium-args` - Extra Chromium flags (default: `""`)
- `window.title` - Window title (default: `"Valet App"`)
- `window.width` - Window width in pixels (default: `960`)
- `window.height` - Window height in pixels (default: `720`)

**Valet-Specific Fields:**

- `valet.server.port` - HTTP server port, 0 = auto-detect (default: `0`)
- `valet.browser.executable` - Browser to use (default: `"msedge"`)
- `valet.browser.userDataDir` - User data directory (default: `".valet_data"`)
- `valet.browser.incognitoMode` - Use incognito mode (default: `true`)

### Clean Environment Defaults

Valet hardcodes these Chromium flags for a clean environment:

- `--disable-extensions` - Disables all browser extensions
- `--disable-translate` - Disables Google Translate popup
- `--incognito` - Private browsing mode (when `incognitoMode: true`)

## Compilation

### Prerequisites

1. Install Nim compiler from [nim-lang.org](https://nim-lang.org/)
2. Verify installation:
   ```powershell
   nim --version
   ```

### Build

**Using build script:**

```powershell
.\build.bat
```

**Manual compilation:**

```powershell
nim c -d:release --opt:size -o:valet.exe valet.nim
```

**Output:** `valet.exe` (~1 MB)

### Build Options

For maximum optimization:

```powershell
nim c -d:release --opt:size --passL:-s valet.nim
```

Flags explained:

- `-d:release` - Release mode with optimizations
- `--opt:size` - Optimize for smaller binary size
- `--passL:-s` - Strip debug symbols (even smaller)

## Supported File Types

Valet serves files with proper MIME types:

- **Web:** HTML, CSS, JavaScript, JSON
- **WebAssembly:** .wasm
- **Images:** PNG, JPG, GIF, SVG, ICO, WebP
- **Fonts:** WOFF, WOFF2, TTF
- **Audio:** MP3, OGG, WAV
- **Video:** MP4, WebM
- **Custom:** Any extension → `application/octet-stream`

## Use Cases

- 🎮 **RPG Maker MV/MZ Games** - Try your game before publishing to web
- 🌐 **HTML5 Standalone Apps** - Package web apps as desktop apps
- 📦 **Electron Alternative** - Lighter weight for simple apps
- 🔧 **Local Web Development** - Quick HTTP server with browser
- 🎨 **Interactive Presentations** - HTML-based presentations

## Console Mode

Valet always runs in console mode, displaying:

- Server startup information
- Auto-detected port
- Browser launch details
- HTTP request logs (optional)
- Error messages

**To exit:** Press `Ctrl+C` or close the console window

**Server Behavior:**

- **Browser closes** → Server continues running (you can refresh or reopen)
- **Console closes** → Server shuts down immediately (clean start next launch)

This ensures:

- ✅ Clean start every time you run `valet.exe`
- ✅ Page refreshing without server restart
- ✅ Opening multiple browser windows
- ✅ Server only runs when you want it (close console to stop)

## Migration from NW.js

Valet is designed as a drop-in replacement for NW.js:

1. **Backup your NW.js executable:**

   ```powershell
   copy nw.exe nw.exe.bak
   ```

2. **Replace with Valet:**

   ```powershell
   copy valet.exe nw.exe
   ```

3. **Update package.json** (optional):

   - Change `"reserve"` section to `"valet"` if present
   - Adjust paths as needed

4. **Run:**
   ```powershell
   .\nw.exe
   ```

Your existing `package.json` will work as-is!

### Differences from NW.js

| Feature        | Electron/NW.js | Valet          |
| -------------- | -------------- | -------------- |
| Size           | ~200 MB        | ~1 MB          |
| Startup Time   | 3-5 seconds    | 1-2 seconds    |
| Memory Usage   | ~150 MB        | ~50 MB         |
| Node.js APIs   | ✅ Yes         | ❌ No          |
| Console Output | Hidden         | Always visible |
| Auto Port      | No             | Yes            |

**Use Valet when:**

- Your app is pure HTML5/JavaScript
- You don't need Node.js APIs
- You want a smaller, faster package
- Target platform is Windows only

**Use Electron/NW.js when:**

- You need Node.js APIs (fs, child_process, etc.)
- Cross-platform support required
- Using NW.js-specific features

## Troubleshooting

### Browser Not Found

**Error:** `Failed to launch msedge`

**Solution:**

- Valet searches default installation paths
- Manually specify browser in package.json:
  ```json
  {
    "valet": {
      "browser": { "executable": "chrome" }
    }
  }
  ```

### Port Already in Use

**Error:** `Failed to bind port 8080`

**Solution:**

- Set `"port": 0` for auto-detection (default)
- Manually specify different port:
  ```json
  {
    "valet": {
      "server": { "port": 9000 }
    }
  }
  ```

### WebAssembly Not Loading

**Error:** `Uncaught TypeError: Failed to execute 'compile' on 'WebAssembly'`

**Solution:**

- Valet automatically serves .wasm files with correct MIME type
- Ensure .wasm files are in the served directory
- Check browser console for detailed errors

## License

MIT License - Feel free to use in your projects!

## Project Structure

```
my-app/
├── valet.exe           # Valet executable
├── package.json        # Configuration file
├── index.html          # Entry point
├── js/                 # JavaScript files
├── css/                # Stylesheets
└── assets/             # Images, fonts, etc.
```

## Credits

Built with [Nim](https://nim-lang.org/) programming language.

---

**Valet** - Lightweight local server 🚀
