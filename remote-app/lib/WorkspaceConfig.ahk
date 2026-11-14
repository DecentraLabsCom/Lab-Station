; ============================================================================
; Shared AppControl workspace configuration
; ============================================================================

global APP_WORKSPACE_MAX_APPS := 5
global APP_WORKSPACE_CONFIG_ROOT := RTrim(A_AppDataCommon, "\") . "\DecentraLabs\Lab Station\RemoteApp\workspaces"
global WORKSPACE_CLOSE_TIMEOUT_MS := 10000
global WORKSPACE_SOFT_CLOSE_STAGE_TIMEOUT_MS := 1500
global WORKSPACE_COORDINATE_CLOSE_TIMEOUT_MS := 3000
global WORKSPACE_CLOSE_POLL_INTERVAL_MS := 50
global WORKSPACE_CLOSE_DEADLINE_MARGIN_MS := 50
