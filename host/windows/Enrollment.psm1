#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Loading source only. An outbound connection starts solely on explicit UI action.
if (-not ('Knot.Enrollment.Client' -as [type])) {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'EnrollmentClient.cs'))) -ErrorAction Stop
}
function Start-KnotFileEnrollment([string] $Link) { return New-Object Knot.Enrollment.Client($Link) }
Export-ModuleMember -Function Start-KnotFileEnrollment
