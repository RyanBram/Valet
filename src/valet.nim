import std/[asynchttpserver, asyncdispatch, json, os, osproc, strutils,
    strformat, times, net]

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

proc findAvailablePort(startPort: int = 8000): int =
  ## Find available port starting from startPort
  for port in startPort..65535:
    try:
      let sock = newSocket()
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(port))
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
      result.browserExe = browser{"executable"}.getStr("msedge")
      result.userDataDir = browser{"userDataDir"}.getStr(".valet_data")
      result.privateMode = browser{"privateMode"}.getBool(true)
      result.showToolbar = browser{"showToolbar"}.getBool(true)
    else:
      result.browserExe = "msedge"
      result.userDataDir = ".valet_data"
      result.privateMode = true
      result.showToolbar = true
  else:
    # Defaults if no valet section
    result.serverPort = 0 # auto-detect
    result.browserExe = "msedge"
    result.userDataDir = ".valet_data"
    result.privateMode = true
    result.showToolbar = true

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
      "server": {
        "port": 0
      },
      "browser": {
        "executable": "msedge",
        "userDataDir": ".valet_data",
        "privateMode": true,
        "showToolbar": true
      }
    }
  }
  writeFile(filename, defaultConfig.pretty())

proc getMimeType(ext: string): string =
  ## Determine MIME type based on file extension
  case ext.toLowerAscii()
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

proc handleRequest(req: Request, baseDir: string) {.async.} =
  ## Handle HTTP request
  var path = req.url.path

  # Root path -> index.html
  if path == "/" or path == "":
    path = "/index.html"

  # Combine with base directory
  let filePath = baseDir / path[1..^1] # Remove leading '/'

  try:
    if fileExists(filePath):
      let content = readFile(filePath)
      let ext = splitFile(filePath).ext
      let mimeType = getMimeType(ext)

      await req.respond(Http200, content, newHttpHeaders([
        ("Content-Type", mimeType),
        ("Cache-Control", "no-cache")
      ]))
    else:
      await req.respond(Http404, "404 - File Not Found")
  except:
    await req.respond(Http500, "500 - Internal Server Error")

proc startServer(port: int, baseDir: string) {.async.} =
  ## Start HTTP server
  var server = newAsyncHttpServer()

  proc callback(req: Request) {.async.} =
    await handleRequest(req, baseDir)

  echo &"[SERVER] Starting HTTP server on http://localhost:{port}"
  echo &"[SERVER] Serving files from: {baseDir}"

  server.listen(Port(port))

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
    else:
      @[browserName] # Use browser name as-is if unknown

  # Find existing path
  for path in possiblePaths:
    if fileExists(path):
      echo &"[BROWSER] Found browser at: {path}"
      return path

  # If not found, return browser name (try PATH)
  return browserName

proc launchBrowser(config: Config, url: string): Process =
  ## Launch browser with specified configuration
  ## Returns: Process object for monitoring
  var args: seq[string] = @[]

  # Use --app mode only if showToolbar is false (hide browser chrome)
  if not config.showToolbar:
    args.add(&"--app={url}")
    # Set window title (best effort - may not work in all browsers)
    if config.windowTitle.len > 0:
      args.add(&"--app-name={config.windowTitle}")

  # Window size
  args.add(&"--window-size={config.windowWidth},{config.windowHeight}")

  # Center window on screen (taskbar-aware)
  let workArea = getWorkArea()
  let posX = workArea.x + (workArea.width - config.windowWidth) div 2
  let posY = workArea.y + (workArea.height - config.windowHeight) div 2
  args.add(&"--window-position={posX},{posY}")

  # Default flags for clean environment (hardcoded)
  args.add("--disable-extensions") # Disable all browser extensions
  args.add("--disable-translate") # Disable Google Translate popup
  
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
    if config.browserExe.toLowerAscii().contains("edge"):
      args.add("--inprivate")
    else:
      args.add("--incognito")

  # Add URL at the end for toolbar mode
  if config.showToolbar:
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

    # Try Chrome as fallback
    let chromePath = findBrowserPath("chrome")
    try:
      result = startProcess(
        chromePath,
        args = args,
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
  echo "  VALET - NW.js Alternative Server & Launcher"
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
  asyncCheck startServer(port, baseDir)

  # Wait a bit for server to be ready
  echo "[INFO] Waiting for server to start..."
  sleep(2000) # 2 seconds
  
  # Launch browser (no monitoring in console mode)
  discard launchBrowser(config, url)

  echo ""
  echo "================================================"
  echo "  Application Running"
  echo "  Press Ctrl+C or close console to exit"
  echo "================================================"
  echo ""

  # Run event loop
  try:
    runForever()
  except:
    echo ""
    echo "[INFO] Shutting down..."
    quit(0)

when isMainModule:
  main()
