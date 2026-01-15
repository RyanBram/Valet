import std/[asynchttpserver, asyncdispatch, json, os, osproc, strutils,
    strformat, times, net, uri, atomics]

when defined(windows):
  type
    RECT {.pure.} = object
      left, top, right, bottom: int32
  
  proc SystemParametersInfoW(uiAction: uint32, uiParam: uint32, 
                              pvParam: pointer, fWinIni: uint32): int32 
                              {.stdcall, dynlib: "user32", importc.}
  const
    SPI_GETWORKAREA = 0x0030  # Get work area (screen minus taskbar)

proc getWorkArea(): tuple[x, y, width, height: int] =
  ## Get usable screen area (excluding taskbar)
  when defined(windows):
    var rect: RECT
    discard SystemParametersInfoW(SPI_GETWORKAREA, 0, addr rect, 0)
    result.x = rect.left
    result.y = rect.top
    result.width = rect.right - rect.left
    result.height = rect.bottom - rect.top
  else:
    # Fallback for non-Windows
    result.x = 0
    result.y = 0
    result.width = 1920
    result.height = 1080

type
  Config = object
    # NW.js compatible fields
    name: string
    main: string
    windowTitle: string
    windowWidth: int
    windowHeight: int
    chromiumArgs: string

    # Valet specific fields
    serverPort: int # 0 = auto-detect
    browserExe: string
    userDataDir: string
    privateMode: bool
    showToolbar: bool # false = app mode, true = regular browser with toolbar
    nodeApi: bool # true = enable Node.js API (require fs), false = plain web server
    maximize: bool # true = start window maximized
    fullscreen: bool # true = start in fullscreen/kiosk mode

proc findAvailablePort(startPort: int = 8000): int =
  ## Find available port starting from startPort
  for port in startPort..65535:
    try:
      let sock = newSocket()
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(port), "127.0.0.1")
      sock.close()
      return port
    except OSError:
      continue
  return 8080 # fallback

proc loadConfig(filename: string): Config =
  ## Load configuration from package.json (NW.js compatible)
  let jsonData = parseFile(filename)

  # NW.js fields with defaults
  result.name = jsonData{"name"}.getStr("valet-app")
  result.main = jsonData{"main"}.getStr("index.html")
  result.chromiumArgs = jsonData{"chromium-args"}.getStr("")

  # Window config (NW.js format)
  if jsonData.hasKey("window"):
    let window = jsonData["window"]
    result.windowTitle = window{"title"}.getStr("Valet App")
    result.windowWidth = window{"width"}.getInt(960)
    result.windowHeight = window{"height"}.getInt(720)
  else:
    result.windowTitle = "Valet App"
    result.windowWidth = 960
    result.windowHeight = 720

  # Valet-specific config (optional extensions)
  if jsonData.hasKey("valet"):
    let valet = jsonData["valet"]

    if valet.hasKey("server"):
      result.serverPort = valet["server"]{"port"}.getInt(0)
    else:
      result.serverPort = 0

    if valet.hasKey("browser"):
      let browser = valet["browser"]
      # Check if executable field exists and get its value
      # If browser section exists but executable is not specified, assume server-only mode
      if browser.hasKey("executable"):
        result.browserExe = browser["executable"].getStr("")
      else:
        result.browserExe = ""  # Server-only mode when executable field is missing
      
      # If browserExe is explicitly set to empty string, keep it empty (server-only mode)
      if result.browserExe == "":
        echo "[INFO] Browser executable not specified - running in server-only mode"
      result.userDataDir = browser{"userDataDir"}.getStr(".valet_data")
      result.privateMode = browser{"privateMode"}.getBool(false)
      result.showToolbar = browser{"showToolbar"}.getBool(true)
      result.maximize = browser{"maximize"}.getBool(false)
      result.fullscreen = browser{"fullscreen"}.getBool(false)
    else:
      result.browserExe = "msedge"
      result.userDataDir = ".valet_data"
      result.privateMode = false
      result.showToolbar = true
      result.maximize = false
      result.fullscreen = false
    
    # Node.js API toggle (default: false - plain web server mode)
    result.nodeApi = valet{"nodeApi"}.getBool(false)
  else:
    # Defaults if no valet section
    result.serverPort = 0 # auto-detect
    result.browserExe = "msedge"
    result.userDataDir = ".valet_data"
    result.privateMode = false
    result.showToolbar = true
    result.maximize = false
    result.fullscreen = false
    result.nodeApi = false  # Plain web server by default

proc createDefaultPackageJson(filename: string) =
  ## Create a default package.json file with standard fields
  let defaultConfig = %*{
    "name": "valet-app",
    "main": "index.html",
    "window": {
      "title": "Valet App",
      "width": 960,
      "height": 720
    },
    "valet": {
      "nodeApi": false,
      "server": {
        "port": 0
      },
      "browser": {
        "executable": "msedge",
        "userDataDir": ".valet_data",
        "privateMode": false,
        "showToolbar": true,
        "maximize": false,
        "fullscreen": false
      }
    }
  }
  writeFile(filename, defaultConfig.pretty())

proc getCompoundExt(filename: string): string =
  ## Get compound extension for Unity WebGL files (e.g., ".data.gz", ".wasm.br")
  let lowerName = filename.toLowerAscii()
  # Check for Unity compound extensions first (order matters - check longest first)
  const compoundExts = [
    ".symbols.json.gz", ".symbols.json.br", ".symbols.json",
    ".framework.js.gz", ".framework.js.br",
    ".data.gz", ".data.br", ".wasm.gz", ".wasm.br", ".js.gz", ".js.br"
  ]
  for ext in compoundExts:
    if lowerName.endsWith(ext):
      return ext
  # Fall back to simple extension
  return splitFile(filename).ext

proc getMimeType(filename: string): string =
  ## Determine MIME type based on file extension (supports compound extensions)
  let ext = getCompoundExt(filename)
  case ext.toLowerAscii()
  # Unity WebGL compressed files (gzip)
  of ".data.gz": "application/octet-stream"
  of ".wasm.gz": "application/wasm"
  of ".js.gz", ".framework.js.gz": "application/javascript"
  of ".symbols.json.gz": "application/octet-stream"
  # Unity WebGL compressed files (brotli)
  of ".data.br": "application/octet-stream"
  of ".wasm.br": "application/wasm"
  of ".js.br", ".framework.js.br": "application/javascript"
  of ".symbols.json.br": "application/octet-stream"
  # Unity WebGL uncompressed files
  of ".data": "application/octet-stream"
  of ".symbols.json": "application/octet-stream"
  of ".unityweb": "application/octet-stream"
  # Standard web files
  of ".html", ".htm": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".wasm": "application/wasm"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".mp3": "audio/mpeg"
  of ".wav": "audio/wav"
  of ".ogg": "audio/ogg"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".txt": "text/plain"
  else: "application/octet-stream"

proc getContentEncoding(filename: string): string =
  ## Get Content-Encoding for compressed files (gzip or brotli)
  let lowerName = filename.toLowerAscii()
  if lowerName.endsWith(".gz"):
    return "gzip"
  elif lowerName.endsWith(".br"):
    return "br"
  return ""

# Polyfill script for NW.js compatibility
const polyfillJs = staticRead("polyfill.js")

# Heartbeat script for browser alive detection
const heartbeatJs = """
<script>
(function() {
  function sendHeartbeat() {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', '/__heartbeat__', true);
      xhr.send();
    } catch(e) {}
  }
  setInterval(sendHeartbeat, 2000); // Every 2 seconds
  sendHeartbeat(); // Initial heartbeat
})();
</script>
"""

# Global heartbeat timestamp (thread-safe)
var lastHeartbeat: Atomic[int64]
var heartbeatInitialized: Atomic[bool]

proc updateHeartbeat() =
  lastHeartbeat.store(epochTime().int64)
  heartbeatInitialized.store(true)

proc getHeartbeatAge(): float =
  if not heartbeatInitialized.load:
    return 0.0
  return epochTime() - lastHeartbeat.load.float

proc handleRequest(req: Request, baseDir: string, nodeApiEnabled: bool) {.async.} =
  ## Handle HTTP request - includes filesystem API endpoints if enabled
  var path = req.url.path

  # URL decode path (handles %20 for spaces, etc.)
  path = decodeUrl(path)

  # ==========================================================================
  # HEARTBEAT ENDPOINT (always enabled for browser exit detection)
  # ==========================================================================
  
  if path == "/__heartbeat__" and req.reqMethod == HttpPost:
    updateHeartbeat()
    await req.respond(Http200, "ok", newHttpHeaders([("Content-Type", "text/plain")]))
    return

  # ==========================================================================
  # FILESYSTEM API ENDPOINTS (only when nodeApi is enabled)
  # These endpoints allow browser JavaScript to perform filesystem operations
  # ==========================================================================

  if nodeApiEnabled:
    # Serve polyfill.js
    if path == "/__polyfill__.js":
      await req.respond(Http200, polyfillJs, newHttpHeaders([
        ("Content-Type", "application/javascript"),
        ("Cache-Control", "no-cache")
      ]))
      return

    # Get base directory
    if path == "/__get_base_dir__":
      await req.respond(Http200, baseDir, newHttpHeaders([
        ("Content-Type", "text/plain"),
        ("Cache-Control", "no-cache")
      ]))
      return

    # Check file/dir existence
    if path == "/__fs_exists__":
      let filePath = decodeUrl(req.url.query.split("=")[^1])
      let exists = fileExists(filePath) or dirExists(filePath)
      await req.respond(Http200, if exists: "true" else: "false", newHttpHeaders([
        ("Content-Type", "text/plain"),
        ("Cache-Control", "no-cache")
      ]))
      return

    # Write file (POST)
    if path == "/__fs_write__" and req.reqMethod == HttpPost:
      try:
        let data = parseJson(req.body)
        let filePath = data["path"].getStr()
        let content = data["content"].getStr()
        writeFile(filePath, content)
        await req.respond(Http200, "ok", newHttpHeaders([("Content-Type", "text/plain")]))
      except:
        await req.respond(Http500, "Write failed: " & getCurrentExceptionMsg())
      return

    # Read file (GET)
    if path == "/__fs_read__":
      let filePath = decodeUrl(req.url.query.split("=")[^1])
      try:
        if fileExists(filePath):
          let content = readFile(filePath)
          await req.respond(Http200, content, newHttpHeaders([
            ("Content-Type", "application/octet-stream"),
            ("Cache-Control", "no-cache")
          ]))
        else:
          await req.respond(Http404, "File not found")
      except:
        await req.respond(Http500, "Read failed: " & getCurrentExceptionMsg())
      return

    # Create directory (POST)
    if path == "/__fs_mkdir__" and req.reqMethod == HttpPost:
      try:
        let data = parseJson(req.body)
        let dirPath = data["path"].getStr()
        createDir(dirPath)
        await req.respond(Http200, "ok", newHttpHeaders([("Content-Type", "text/plain")]))
      except:
        await req.respond(Http200, "ok")  # Directory might exist, that's OK
      return

    # Delete file (POST)
    if path == "/__fs_unlink__" and req.reqMethod == HttpPost:
      try:
        let data = parseJson(req.body)
        let filePath = data["path"].getStr()
        removeFile(filePath)
        await req.respond(Http200, "ok", newHttpHeaders([("Content-Type", "text/plain")]))
      except:
        await req.respond(Http500, "Delete failed: " & getCurrentExceptionMsg())
      return

    # List directory (GET)
    if path == "/__fs_list_dir__":
      let dirPath = decodeUrl(req.url.query.split("=")[^1])
      try:
        var files: seq[string] = @[]
        for kind, name in walkDir(dirPath):
          files.add(extractFilename(name))
        await req.respond(Http200, $(%files), newHttpHeaders([
          ("Content-Type", "application/json"),
          ("Cache-Control", "no-cache")
        ]))
      except:
        await req.respond(Http200, "[]", newHttpHeaders([("Content-Type", "application/json")]))
      return
  # End of nodeApi block

  # ==========================================================================
  # STANDARD FILE SERVING
  # ==========================================================================

  # Root path -> index.html
  if path == "/" or path == "":
    path = "/index.html"

  # Combine with base directory
  let filePath = baseDir / path[1..^1] # Remove leading '/'

  try:
    if fileExists(filePath):
      var content = readFile(filePath)
      let mimeType = getMimeType(filePath)
      let contentEncoding = getContentEncoding(filePath)

      # Inject scripts into HTML files
      if mimeType == "text/html":
        var injectedScripts = ""
        
        # Always inject heartbeat for browser exit detection
        injectedScripts = injectedScripts & heartbeatJs
        
        # Inject polyfill only when nodeApi is enabled
        if nodeApiEnabled:
          injectedScripts = injectedScripts & """<script src="/__polyfill__.js"></script>"""
        
        # Insert before </head> or at start of <body>
        if injectedScripts.len > 0:
          if content.contains("</head>"):
            content = content.replace("</head>", injectedScripts & "\n</head>")
          elif content.contains("<body"):
            let bodyIdx = content.find("<body")
            let endTag = content.find(">", bodyIdx)
            if endTag > 0:
              content = content[0..endTag] & "\n" & injectedScripts & content[endTag+1..^1]

      # Build headers with optional Content-Encoding for compressed files
      var headers = @[
        ("Content-Type", mimeType),
        ("Cache-Control", "no-cache")
      ]
      if contentEncoding.len > 0:
        headers.add(("Content-Encoding", contentEncoding))

      await req.respond(Http200, content, newHttpHeaders(headers))
    else:
      await req.respond(Http404, "404 - File Not Found")
  except:
    await req.respond(Http500, "500 - Internal Server Error")

proc startServer(port: int, baseDir: string, nodeApiEnabled: bool) {.async.} =
  ## Start HTTP server
  var server = newAsyncHttpServer()

  proc callback(req: Request) {.async.} =
    await handleRequest(req, baseDir, nodeApiEnabled)

  echo &"[SERVER] Starting HTTP server on http://localhost:{port}"
  echo &"[SERVER] Serving files from: {baseDir}"

  # Bind to localhost only to avoid Windows Firewall prompts
  server.listen(Port(port), "127.0.0.1")

  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(callback)
    else:
      await sleepAsync(100)

proc findBrowserPath(browserName: string): string =
  ## Find full browser path in default Windows installation locations
  let possiblePaths =
    case browserName.toLowerAscii()
    of "msedge", "edge":
      @[
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        getEnv("PROGRAMFILES(X86)") / r"Microsoft\Edge\Application\msedge.exe",
        getEnv("PROGRAMFILES") / r"Microsoft\Edge\Application\msedge.exe"
      ]
    of "chrome", "google-chrome":
      @[
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        getEnv("PROGRAMFILES") / r"Google\Chrome\Application\chrome.exe",
        getEnv("PROGRAMFILES(X86)") / r"Google\Chrome\Application\chrome.exe",
        getEnv("LOCALAPPDATA") / r"Google\Chrome\Application\chrome.exe"
      ]
    of "firefox":
      @[
        r"C:\Program Files\Mozilla Firefox\firefox.exe",
        r"C:\Program Files (x86)\Mozilla Firefox\firefox.exe",
        getEnv("PROGRAMFILES") / r"Mozilla Firefox\firefox.exe",
        getEnv("PROGRAMFILES(X86)") / r"Mozilla Firefox\firefox.exe"
      ]
    else:
      @[browserName] # Use browser name as-is if unknown

  # Find existing path
  for path in possiblePaths:
    if fileExists(path):
      echo &"[BROWSER] Found browser at: {path}"
      return path

  # If not found, return browser name (try PATH)
  return browserName

proc setupFirefoxAppMode(profilePath: string, config: Config) =
  ## Setup Firefox profile with userChrome.css for app mode and xulstore.json for window state
  
  let chromeDir = profilePath / "chrome"
  let userChromePath = chromeDir / "userChrome.css"
  let userJsPath = profilePath / "user.js"
  let xulStorePath = profilePath / "xulstore.json"
  
  # Always ensure profile directory exists
  if not dirExists(profilePath):
    createDir(profilePath)
  
  # Create/overwrite xulstore.json to set window position, size, and maximize state
  # Always overwrite to ensure package.json settings are respected
  let workArea = getWorkArea()
  let posX = workArea.x + (workArea.width - config.windowWidth) div 2
  let posY = workArea.y + (workArea.height - config.windowHeight) div 2
  
  # Determine sizemode: "maximized" or "normal"
  var sizeMode = "normal"
  if config.maximize:
    sizeMode = "maximized"
  
  # Firefox xulstore.json format for main browser window
  let xulStore = &"""{{
  "chrome://browser/content/browser.xhtml": {{
    "main-window": {{
      "screenX": "{posX}",
      "screenY": "{posY}",
      "width": "{config.windowWidth}",
      "height": "{config.windowHeight}",
      "sizemode": "{sizeMode}"
    }}
  }}
}}"""
  writeFile(xulStorePath, xulStore)
  echo &"[BROWSER] Firefox window state configured (position: {posX},{posY}, size: {config.windowWidth}x{config.windowHeight}, mode: {sizeMode})"
  
  if not config.showToolbar:
    # Create chrome directory if not exists
    if not dirExists(chromeDir):
      createDir(chromeDir)
    
    # Create userChrome.css to hide browser chrome (toolbar, tabs)
    # NOTE: Keep #titlebar visible so window controls (min/max/close) remain accessible
    let userChromeCss = """/* Firefox App Mode - Generated by Valet */
/* Hide browser chrome for app-like experience */
/* Keep window controls (minimize, maximize, close) visible */

/* Hide tab bar */
#TabsToolbar { visibility: collapse !important; }

/* Hide navigation bar (address bar, back/forward buttons) */
#nav-bar { visibility: collapse !important; }

/* Hide bookmark bar if visible */
#PersonalToolbar { visibility: collapse !important; }
"""
    writeFile(userChromePath, userChromeCss)
    echo "[BROWSER] Firefox app mode enabled (toolbar hidden via userChrome.css)"
  else:
    # showToolbar is true - remove app mode CSS if exists
    if fileExists(userChromePath):
      removeFile(userChromePath)
      echo "[BROWSER] Firefox toolbar restored (userChrome.css removed)"
  
  # Always create/update user.js with preferences (both app mode and normal mode)
  let userJsContent = """// Firefox preferences - Generated by Valet
// Enable userChrome.css customization
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Show proper titlebar with window controls (min/max/close) - CRITICAL FOR WINDOWS
user_pref("browser.tabs.drawInTitlebar", false);
user_pref("browser.tabs.inTitlebar", 0);

// Disable session restore prompts ("Restore previous session?" message)
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.sessionstore.warnOnQuit", false);
user_pref("browser.sessionstore.restore_pinned_tabs_on_demand", false);
user_pref("browser.startup.page", 1);  // 1 = homepage, not session restore
user_pref("browser.startup.couldRestoreSession.count", 3);  // Pretend opened 3+ times

// Disable first-run wizards and welcome pages
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("startup.homepage_override_url", "");
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.uitour.enabled", false);

// Disable telemetry and data collection prompts
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);

// Disable CFR (Contextual Feature Recommendations) - tips and suggestions
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);

// Disable other popups and UI tips
user_pref("browser.rights.3.shown", true);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.discovery.enabled", false);
user_pref("extensions.pocket.enabled", false);
"""
  writeFile(userJsPath, userJsContent)

proc launchBrowser(config: Config, url: string): Process =
  ## Launch browser with specified configuration
  ## Returns: Process object for monitoring
  var args: seq[string] = @[]
  
  let browserLower = config.browserExe.toLowerAscii()
  let isEdge = browserLower.contains("edge")
  let isFirefox = browserLower.contains("firefox")
  
  if isFirefox:
    # ========================================================================
    # FIREFOX SPECIFIC FLAGS
    # Firefox uses different command line syntax than Chromium
    # ========================================================================
    
    # Firefox doesn't have app mode, just open URL
    args.add("-new-window")
    args.add(url)
    
    # Window size (Firefox uses -width and -height)
    if not config.maximize and not config.fullscreen:
      args.add("-width")
      args.add($config.windowWidth)
      args.add("-height")
      args.add($config.windowHeight)
    
    # Fullscreen mode (Firefox uses -kiosk)
    if config.fullscreen:
      args.add("-kiosk")
    # Note: Firefox doesn't have --start-maximized equivalent
    
    # Profile directory (Firefox uses -profile)
    let currentDir = getCurrentDir()
    let userDataPath = currentDir / config.userDataDir
    if not dirExists(userDataPath):
      createDir(userDataPath)
    
    # Setup Firefox app mode and window state
    setupFirefoxAppMode(userDataPath, config)
    
    args.add("-profile")
    args.add(userDataPath)
    
    # Private mode (Firefox uses -private-window but conflicts with -new-window)
    # Skip if privateMode as it requires different approach
    if config.privateMode:
      echo "[BROWSER] Note: Firefox private mode not fully supported in this configuration"
    
    # Firefox headless cleanup flags (skip unsupported ones gracefully)
    args.add("-no-remote")  # Don't connect to existing Firefox instance
    
  else:
    # ========================================================================
    # CHROMIUM-BASED FLAGS (Edge, Chrome)
    # ========================================================================
    
    # Use --app mode only if showToolbar is false AND not in kiosk mode
    # (kiosk mode already hides browser chrome, so --app is redundant and may conflict)
    if not config.showToolbar and not config.fullscreen:
      args.add(&"--app={url}")
      # Set window title (best effort - may not work in all browsers)
      if config.windowTitle.len > 0:
        args.add(&"--app-name={config.windowTitle}")

    # Window size and position (skip when maximized or fullscreen)
    if not config.maximize and not config.fullscreen:
      args.add(&"--window-size={config.windowWidth},{config.windowHeight}")
      
      # Center window on screen (taskbar-aware)
      let workArea = getWorkArea()
      let posX = workArea.x + (workArea.width - config.windowWidth) div 2
      let posY = workArea.y + (workArea.height - config.windowHeight) div 2
      args.add(&"--window-position={posX},{posY}")

    # Default flags for clean environment (browser-specific)
    if isEdge:
      # Microsoft Edge specific flags
      args.add("--no-first-run")
      args.add("--no-default-browser-check")
      args.add("--disable-sync")
      args.add("--disable-features=msEdgeWhatsNewUI,msEdgeSyncAndIdentity")
      args.add("--disable-notifications")
      args.add("--disable-extensions")
      args.add("--disable-translate")
      args.add("--disable-background-networking")
    else:
      # Chrome/Chromium flags
      args.add("--no-first-run")
      args.add("--no-default-browser-check")
      args.add("--disable-sync")
      args.add("--disable-features=TranslateUI")
      args.add("--disable-notifications")
      args.add("--disable-extensions")
      args.add("--disable-translate")
      args.add("--disable-infobars")
      args.add("--disable-component-update")
      args.add("--disable-background-networking")
    
    # Window state flags
    if config.fullscreen:
      args.add("--kiosk")  # True kiosk mode (same as Firefox -kiosk)
    elif config.maximize:
      args.add("--start-maximized")
    
    # Chromium args from package.json (appended to defaults)
    if config.chromiumArgs.len > 0:
      # Split chromium args by space and add them
      let extraArgs = config.chromiumArgs.split(" ")
      for arg in extraArgs:
        if arg.len > 0:
          args.add(arg)

    # Always use user data directory for consistent window sizing
    let currentDir = getCurrentDir()
    let userDataPath = currentDir / config.userDataDir
    args.add(&"--user-data-dir={userDataPath}")

    # Add incognito/inprivate flag if requested (alongside user-data-dir)
    if config.privateMode:
      # Edge uses --inprivate, Chrome uses --incognito
      if isEdge:
        args.add("--inprivate")
      else:
        args.add("--incognito")

    # Add URL at the end for toolbar mode OR kiosk/fullscreen mode
    # (In app mode, URL is already part of --app={url})
    if config.showToolbar or config.fullscreen:
      args.add(url)

  # Find actual browser path
  let browserPath = findBrowserPath(config.browserExe)
  let argsStr = args.join(" ")
  echo &"[BROWSER] Launching {browserPath}"
  echo &"[BROWSER] Arguments: {argsStr}"

  # Try launching browser
  try:
    result = startProcess(
      browserPath,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    echo "[BROWSER] Browser launched successfully"
  except OSError as e:
    echo &"[ERROR] Failed to launch {browserPath}"
    echo &"[ERROR] Error message: {e.msg}"
    echo "[INFO] Trying Chrome as fallback..."

    # Try Chrome as fallback - rebuild args for Chromium compatibility
    let chromePath = findBrowserPath("chrome")
    var chromeArgs: seq[string] = @[]
    
    # Rebuild Chromium-compatible args (can't reuse Firefox args)
    if not config.showToolbar and not config.fullscreen:
      chromeArgs.add(&"--app={url}")
    
    if not config.maximize and not config.fullscreen:
      chromeArgs.add(&"--window-size={config.windowWidth},{config.windowHeight}")
      let workArea = getWorkArea()
      let posX = workArea.x + (workArea.width - config.windowWidth) div 2
      let posY = workArea.y + (workArea.height - config.windowHeight) div 2
      chromeArgs.add(&"--window-position={posX},{posY}")
    
    # Chrome default flags
    chromeArgs.add("--no-first-run")
    chromeArgs.add("--no-default-browser-check")
    chromeArgs.add("--disable-sync")
    chromeArgs.add("--disable-features=TranslateUI")
    chromeArgs.add("--disable-notifications")
    chromeArgs.add("--disable-extensions")
    
    if config.fullscreen:
      chromeArgs.add("--kiosk")
    elif config.maximize:
      chromeArgs.add("--start-maximized")
    
    let currentDir = getCurrentDir()
    let userDataPath = currentDir / config.userDataDir
    chromeArgs.add(&"--user-data-dir={userDataPath}")
    
    if config.privateMode:
      chromeArgs.add("--incognito")
    
    if config.showToolbar or config.fullscreen:
      chromeArgs.add(url)
    
    try:
      result = startProcess(
        chromePath,
        args = chromeArgs,
        options = {poUsePath, poStdErrToStdOut}
      )
      echo "[BROWSER] Chrome launched successfully"
    except OSError as e2:
      echo &"[ERROR] Failed to launch Chrome: {chromePath}"
      echo &"[ERROR] Error message: {e2.msg}"
      echo "[ERROR] Please make sure Edge or Chrome is installed"
      quit(1)

proc main() =
  echo "================================================"
  echo "  VALET - Lightweight Local Webserver"
  echo "================================================"
  echo ""

  # Configuration file location
  let configFile = getCurrentDir() / "package.json"

  if not fileExists(configFile):
    echo "[CONFIG] package.json not found, creating default..."
    createDefaultPackageJson(configFile)
    echo "[CONFIG] Created package.json with default settings"

  # Load configuration
  echo "[CONFIG] Loading configuration from package.json..."
  let config = loadConfig(configFile)

  echo &"[CONFIG] App: {config.name}"
  echo &"[CONFIG] Main: {config.main}"
  echo &"[CONFIG] Title: {config.windowTitle}"
  echo &"[CONFIG] Window Size: {config.windowWidth}x{config.windowHeight}"
  echo &"[CONFIG] Browser: {config.browserExe}"
  echo &"[CONFIG] Node.js API: {config.nodeApi}"
  if config.chromiumArgs.len > 0:
    echo &"[CONFIG] Chromium Args: {config.chromiumArgs}"
  echo ""

  # Get current directory as base directory for server
  let baseDir = getCurrentDir()

  # Auto-detect port if not configured
  let port = if config.serverPort == 0:
               let detected = findAvailablePort()
               echo &"[SERVER] Auto-detected port: {detected}"
               detected
             else:
               echo &"[SERVER] Using configured port: {config.serverPort}"
               config.serverPort

  # URL for browser
  let url = &"http://localhost:{port}/{config.main}"

  # Start server in async thread
  asyncCheck startServer(port, baseDir, config.nodeApi)

  # Wait a bit for server to be ready
  echo "[INFO] Waiting for server to start..."
  sleep(2000) # 2 seconds
  
  # Launch browser only if browser executable is specified
  if config.browserExe != "":
    discard launchBrowser(config, url)
  else:
    echo "[INFO] Server-only mode - no browser will be launched"
    echo &"[INFO] You can access the application at: {url}"

  echo ""
  echo "================================================"
  if config.browserExe != "":
    echo "  Application Running"
    echo "  Server will auto-shutdown when browser closes"
  else:
    echo "  Server Running (Server-Only Mode)"
    echo &"  URL: {url}"
    echo "  Press Ctrl+C or close console to exit"
  echo "================================================"
  echo ""

  # Heartbeat timeout (seconds) - shutdown after no heartbeat for this long
  const heartbeatTimeout = 10.0
  
  # Run event loop with heartbeat monitoring
  try:
    if config.browserExe != "":
      # Browser mode - monitor heartbeat and auto-shutdown
      while true:
        poll(100)  # Process async events
        
        # Check heartbeat timeout only after first heartbeat received
        let age = getHeartbeatAge()
        if heartbeatInitialized.load and age > heartbeatTimeout:
          echo ""
          echo "[INFO] Browser closed - no heartbeat for ", age.int, " seconds"
          echo "[INFO] Shutting down server..."
          break
    else:
      # Server-only mode - run forever
      runForever()
  except:
    echo ""
    echo "[INFO] Shutting down..."
  
  quit(0)

when isMainModule:
  main()
