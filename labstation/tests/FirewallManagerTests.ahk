#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\system\FirewallManager.ahk

global TEST_FAILURES := 0

RunFirewallManagerTests()

RunFirewallManagerTests() {
    try {
        TestFirewallAddressScopeTreatsFullLengthPrefixesAsHostAddresses()
        TestFirewallAddressScopeKeepsSubnetBoundariesStrict()
    } catch as err {
        LS_TestFail("Unhandled firewall-manager test exception: " . err.Message)
    }

    if (TEST_FAILURES > 0) {
        LS_TestOutput("FirewallManagerTests failed: " . TEST_FAILURES . " failure(s)" . Chr(10))
        ExitApp(1)
    }

    LS_TestOutput("FirewallManagerTests passed" . Chr(10))
    ExitApp(0)
}

TestFirewallAddressScopeTreatsFullLengthPrefixesAsHostAddresses() {
    script := LS_FirewallManager.PowerShellFirewallAddressHelpers()
        . "if (-not (Test-FirewallAddressScope -Expected @('10.7.74.241/32') -Actual @('10.7.74.241'))) { throw 'IPv4 /32 was not treated as the same host address' }`n"
        . "if (-not (Test-FirewallAddressScope -Expected @('2001:0DB8:0:0:0:0:0:1/128') -Actual @('2001:db8::1'))) { throw 'IPv6 /128 was not treated as the same host address' }`n"
        . "Write-Output 'FIREWALL_ADDRESS_HOST_NORMALIZATION_OK'`n"
    capture := LS_RunPowerShellCapture(script, "Test firewall address normalization")

    LS_TestAssert(capture["exitCode"] = 0, "firewall address normalization accepts host addresses with or without full-length prefixes")
    LS_TestAssert(InStr(capture["stdout"], "FIREWALL_ADDRESS_HOST_NORMALIZATION_OK") > 0, "firewall address normalization test completes in PowerShell")
}

TestFirewallAddressScopeKeepsSubnetBoundariesStrict() {
    script := LS_FirewallManager.PowerShellFirewallAddressHelpers()
        . "if (-not (Test-FirewallAddressScope -Expected @('10.7.74.0/024') -Actual @('10.7.74.0/24'))) { throw 'Equivalent CIDR prefix notation did not match' }`n"
        . "if (Test-FirewallAddressScope -Expected @('10.7.74.0/24') -Actual @('10.7.74.0/25')) { throw 'Different CIDR scopes were incorrectly treated as equal' }`n"
        . "Write-Output 'FIREWALL_ADDRESS_CIDR_SCOPE_OK'`n"
    capture := LS_RunPowerShellCapture(script, "Test firewall CIDR scope comparison")

    LS_TestAssert(capture["exitCode"] = 0, "firewall address normalization preserves CIDR scope boundaries")
    LS_TestAssert(InStr(capture["stdout"], "FIREWALL_ADDRESS_CIDR_SCOPE_OK") > 0, "firewall CIDR comparison test completes in PowerShell")
}
