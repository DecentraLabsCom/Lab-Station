; ============================================================================
; Lab Station - Secure Windows AutoAdminLogon configuration
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk

class LS_AutologonManager {
    static SecretName := "DefaultPassword"

    static Configure(user, password, domain := "") {
        if (!LS_EnsureAdmin())
            return false
        if (!user || user = "")
            user := "LABUSER"
        if (!password || password = "") {
            LS_LogError("Password required to configure AutoAdminLogon")
            return false
        }
        if (domain = "")
            domain := A_ComputerName

        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        if (!this.Disable())
            return false

        try {
            if (!this.StoreSecret(password))
                throw Error("LsaStorePrivateData failed to store the AutoAdminLogon secret")
            RegWrite(user, "REG_SZ", key, "DefaultUserName")
            RegWrite(domain, "REG_SZ", key, "DefaultDomainName")
            RegWrite("1", "REG_DWORD", key, "ForceAutoLogon")
            RegWrite("0", "REG_DWORD", key, "DisableCAD")
            if (!this.HasSecret())
                throw Error("The AutoAdminLogon LSA secret could not be verified")
            RegWrite("1", "REG_SZ", key, "AutoAdminLogon")

            if (!this.IsEnabledForUser(user))
                throw Error("AutoAdminLogon verification failed")

            LS_LogInfo("AutoAdminLogon configured with the Windows LSA secret store")
            return true
        } catch as e {
            try RegWrite("0", "REG_SZ", key, "AutoAdminLogon")
            try RegWrite("0", "REG_DWORD", key, "ForceAutoLogon")
            try this.RemoveWinlogonPassword(key)
            try this.DeleteSecret()
            LS_LogError("Unable to configure secure AutoAdminLogon: " . e.Message)
            return false
        }
    }

    static Disable() {
        if (!LS_EnsureAdmin())
            return false
        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        try RegWrite("0", "REG_SZ", key, "AutoAdminLogon")
        catch as e {
            if (this.IsAutoLogonEnabled())
                LS_LogError("Unable to disable AutoAdminLogon: " . e.Message)
        }
        try RegWrite("0", "REG_DWORD", key, "ForceAutoLogon")
        catch {
        }
        plaintextRemoved := this.RemoveWinlogonPassword(key)
        secretRemoved := false
        try secretRemoved := this.DeleteSecret()
        catch as e {
            LS_LogError("Unable to remove the LSA AutoAdminLogon secret: " . e.Message)
        }
        if (!plaintextRemoved || !secretRemoved || this.HasWinlogonPassword() || this.HasSecret() || this.IsAutoLogonEnabled()) {
            LS_LogError("Unable to fully disable AutoAdminLogon and remove its stored credential")
            return false
        }
        LS_LogInfo("AutoAdminLogon disabled and its stored secret removed")
        return true
    }

    static IsAutoLogonEnabled() {
        try {
            value := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon", "AutoAdminLogon")
            return value = 1 || value = "1"
        } catch {
            return false
        }
    }

    static HasSecret() {
        try return this.ReadSecretExists()
        catch as e {
            LS_LogWarning("Unable to inspect the AutoAdminLogon LSA secret: " . e.Message)
            return false
        }
    }

    static HasWinlogonPassword() {
        try {
            RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon", "DefaultPassword")
            return true
        }
        catch {
            return false
        }
    }

    static IsEnabledForUser(user) {
        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        try {
            enabled := RegRead(key, "AutoAdminLogon")
            configuredUser := RegRead(key, "DefaultUserName")
            return (enabled = 1 || enabled = "1")
                && StrLower(configuredUser) = StrLower(user)
                && !this.HasWinlogonPassword()
                && this.HasSecret()
        } catch {
            return false
        }
    }

    static RemoveWinlogonPassword(key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon") {
        try RegDelete(key, "DefaultPassword")
        return !this.HasWinlogonPassword()
    }

    static ReadSecretExists() {
        policy := this.OpenPolicy(0x0004) ; POLICY_GET_PRIVATE_INFORMATION
        key := this.MakeLsaString(this.SecretName)
        privateData := 0
        try {
            status := DllCall(
                "Advapi32\LsaRetrievePrivateData",
                "Ptr", policy,
                "Ptr", key["layout"].Ptr,
                "Ptr*", &privateData,
                "UInt"
            )
            if (status != 0 || !privateData)
                return false
            length := NumGet(privateData, 0, "UShort")
            bufferOffset := A_PtrSize = 8 ? 8 : 4
            secretBuffer := NumGet(privateData, bufferOffset, "Ptr")
            if (secretBuffer && length > 0)
                this.ZeroMemory(secretBuffer, length)
            return length > 0
        } finally {
            if (privateData)
                DllCall("Advapi32\LsaFreeMemory", "Ptr", privateData, "UInt")
            DllCall("Advapi32\LsaClose", "Ptr", policy, "UInt")
        }
    }

    static StoreSecret(value) {
        policy := this.OpenPolicy(0x0020) ; POLICY_CREATE_SECRET
        key := this.MakeLsaString(this.SecretName)
        secret := this.MakeLsaString(value)
        try {
            status := DllCall(
                "Advapi32\LsaStorePrivateData",
                "Ptr", policy,
                "Ptr", key["layout"].Ptr,
                "Ptr", secret["layout"].Ptr,
                "UInt"
            )
            return status = 0
        } finally {
            this.ZeroBuffer(secret["data"])
            DllCall("Advapi32\LsaClose", "Ptr", policy, "UInt")
        }
    }

    static DeleteSecret() {
        policy := this.OpenPolicy(0x0020) ; POLICY_CREATE_SECRET
        key := this.MakeLsaString(this.SecretName)
        try {
            status := DllCall(
                "Advapi32\LsaStorePrivateData",
                "Ptr", policy,
                "Ptr", key["layout"].Ptr,
                "Ptr", 0,
                "UInt"
            )
            return status = 0 || status = 0xC0000034 ; STATUS_OBJECT_NAME_NOT_FOUND
        } finally {
            DllCall("Advapi32\LsaClose", "Ptr", policy, "UInt")
        }
    }

    static OpenPolicy(access) {
        attributes := Buffer(6 * A_PtrSize, 0)
        NumPut("UInt", attributes.Size, attributes, 0)
        policy := 0
        status := DllCall(
            "Advapi32\LsaOpenPolicy",
            "Ptr", 0,
            "Ptr", attributes.Ptr,
            "UInt", access,
            "Ptr*", &policy,
            "UInt"
        )
        if (status != 0 || !policy)
            throw Error("LsaOpenPolicy failed with NTSTATUS 0x" . Format("{:08X}", status & 0xFFFFFFFF))
        return policy
    }

    static MakeLsaString(value) {
        data := Buffer((StrLen(value) + 1) * 2, 0)
        StrPut(value, data, "UTF-16")
        bufferOffset := A_PtrSize = 8 ? 8 : 4
        layout := Buffer(bufferOffset + A_PtrSize, 0)
        NumPut("UShort", StrLen(value) * 2, layout, 0)
        NumPut("UShort", (StrLen(value) + 1) * 2, layout, 2)
        NumPut("Ptr", data.Ptr, layout, bufferOffset)
        return Map("layout", layout, "data", data)
    }

    static ZeroMemory(address, size) {
        Loop size
            NumPut("UChar", 0, address, A_Index - 1)
    }

    static ZeroBuffer(buffer) {
        this.ZeroMemory(buffer.Ptr, buffer.Size)
    }
}
