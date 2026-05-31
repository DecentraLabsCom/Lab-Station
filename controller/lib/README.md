# AppControl - Modular Structure

## 📁 File Organization

```
Lab Station/
└── controller/
    ├── AppControl.ahk         # Main entry point (~140 lines)
    └── lib/                       # Library modules
        ├── Config.ahk             # Configuration and constants
        ├── Utils.ahk              # Utility functions
        ├── WindowClosing.ahk      # Window closing logic
        ├── RdpMonitoring.ahk      # RDP event monitoring
        ├── SingleAppMode.ahk      # Single app mode implementation
        └── DualAppMode.ahk        # Dual app container mode implementation
```

## 📦 Module Descriptions

### Config.ahk
**Purpose:** Centralized configuration and global variables  
**Contains:**
- Configuration constants (timeouts, intervals, etc.)
- Global variables for app state
- RDP event IDs

### Utils.ahk
**Purpose:** General utility functions used across modules  
**Functions:**
- `Log(msg)` - Logging with timestamps
- `IsNumber(str)` - String validation
- `HasCustomTitleBar(hwnd)` - Detect app title bar type
- `WaitUntil(callback, timeoutMs?, intervalMs?)` - Polling helper for state transitions
- `GetWindowDimensions(hwnd)` / `EnsureWindowSized(...)` - Safe window sizing helpers
- `FindWindowCandidate(className, pid, isLauncher)` - Shared discovery logic for app windows
- `ApplyContainerPositioningDelay()` - Configurable pause before positioning embedded apps

### WindowClosing.ahk
**Purpose:** Window closing with multiple fallback methods  
**Functions:**
- `TryCustomGracefulClose(target, timeoutSec)` - Custom close methods
- `CloseWindowCascade(target, closeWait, isEmbedded)` - Standard close cascade
- `ForceCloseWindow(targetWin, closeWait)` - Main close function with dual mode handling

### RdpMonitoring.ahk
**Purpose:** RDP session event monitoring and handling  
**Functions:**
- `GetLatestRdpEventRecord(ids)` - Query Windows event log
- `CheckSessionEvents()` - Polling fallback for events
- `OnSessionChange(wParam, lParam, msg, hwnd)` - Session change handler
- `OnQueryEndSession(wParam, lParam, msg, hwnd)` - Shutdown/logoff handler
- `SetupRdpMonitoring(hwnd)` - Initialize monitoring

### SingleAppMode.ahk
**Purpose:** Single application management  
**Functions:**
- `CreateSingleApp(windowClass, appPath)` - Main single mode function
- `TestCustomClose()` - Test custom close coordinates/controls

### DualAppMode.ahk
**Purpose:** Dual application container with tabs  
**Functions:**
- `CreateDualAppContainer(class1, path1, class2, path2)` - Main dual mode function
- `SwitchTab_Container(tabCtrl, hwnd1, hwnd2)` - Tab switching logic
- `ResizeApps_Container(tabCtrl, hwnd1, hwnd2, container, appContainer)` - Resize handling

## 🚀 Usage

```powershell
# Single app mode
AppControl.ahk "Notepad" "notepad.exe"

# Single app mode with custom close
AppControl.ahk "LVWindow" "myVI.exe" --close-coords="330,484"

# Dual app mode
AppControl.ahk --dual "Class1" "App1.exe" "Class2" "App2.exe"

# Dual app mode with custom tabs
AppControl.ahk --dual "Class1" "App1.exe" "Class2" "App2.exe" --tab1="Camera" --tab2="Viewer"
```

## 📝 Development Notes

- **Order matters:** Modules must be included in dependency order
- **Global scope:** All modules share the same global scope
- **#Include paths:** Relative to the main script directory