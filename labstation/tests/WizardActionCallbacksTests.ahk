#Requires AutoHotkey v2.0
#Include ..\setup\Wizard.ahk

CheckSteps(modeName, steps, expectedLen, &errors) {
    if !IsObject(steps) {
        errors.Push(modeName . ": steps is not an object")
        return
    }

    if (steps.Length != expectedLen) {
        errors.Push(modeName . ": expected " . expectedLen . " steps but got " . steps.Length)
    }

    for index, step in steps {
        if !IsObject(step) {
            errors.Push(modeName . " step " . index . ": step is not an object")
            continue
        }

        if (!step.Has("label")) {
            errors.Push(modeName . " step " . index . ": missing label")
        }

        if (!step.Has("action")) {
            errors.Push(modeName . " step " . index . ": missing action")
            continue
        }

        action := step["action"]
        if !HasMethod(action, "Call") {
            errors.Push(modeName . " step " . index . ": action is not callable")
        }
    }
}

errors := []

try {
    serverSteps := LS_WizardServerSteps()
    CheckSteps("server", serverSteps, 6, &errors)
} catch as e {
    errors.Push("server: exception while building steps - " . e.Message)
}

try {
    hybridSteps := LS_WizardHybridSteps()
    CheckSteps("hybrid", hybridSteps, 6, &errors)
} catch as e {
    errors.Push("hybrid: exception while building steps - " . e.Message)
}

if (errors.Length > 0) {
    for _, msg in errors {
        FileAppend(msg . "`n", "*")
    }
    ExitApp(1)
}

FileAppend("WizardActionCallbacksTests passed`n", "*")
ExitApp(0)
