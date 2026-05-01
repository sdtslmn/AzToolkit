# AzToolkit
Your Azure multitool — PowerShell modules and scripts for ops, automation, IaC, and governance.

A growing collection of PowerShell scripts for managing Azure environments at scale: cross-subscription reporting, governance enforcement, resource cleanup, and day-to-day operations. Built around the official `Az` module with a focus on safety, clarity, and reusability.

## Why this exists

Most Azure work eventually demands the same things over and over: *"list every X across every subscription," "find resources that don't meet our standard," "clean up the orphans."* This repo collects those scripts in one place, with consistent patterns, so they're easy to find, easy to read, and easy to extend.

## Requirements

- **PowerShell 7+** (Windows, macOS, or Linux) — verify with `$PSVersionTable.PSVersion`
- **Az PowerShell module** — `Install-Module Az -Scope CurrentUser`
- **Az.ResourceGraph module** — `Install-Module Az.ResourceGraph -Scope CurrentUser`
- An Azure account with at least **Reader** access to the subscriptions you want to query. Some governance scripts require **Contributor** to apply changes.

## Getting started

```powershell
