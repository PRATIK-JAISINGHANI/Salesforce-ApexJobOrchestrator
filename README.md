# Apex Job Orchestration (AJO)

Configure, run and monitor scheduled Apex from records instead of from Setup. Six
heartbeat `CronTrigger` registrations plus one supervisor hold **seven** of the
org's 100 scheduled Apex slots and between them carry an unlimited number of
configured jobs.

Formerly *Optimus Job Orchestration* (`OJO`). Everything in the module now
carries the `AJO` prefix.

## Naming convention

| Kind | Convention | Examples |
| --- | --- | --- |
| Apex classes | `AJO` + role | `AJODispatcher`, `AJOLauncher`, `AJOWindow` |
| Custom objects | `AJO` + noun | `AJOJob__c`, `AJOJobRun__c`, `AJOSetting__c` |
| Custom fields | `AJO_` + noun | `AJO_CronExpression__c`, `AJO_EndDate__c` |
| Tabs / app / permission sets | `AJO` + noun | `AJOConsole`, `ApexJobOrchestration`, `AJOJobOrchestrationAdmin` |
| Scheduled registrations | `AJO ` + role | `AJO Heartbeat 00`…`50`, `AJO Supervisor` |

## The moving parts

| Class | Does |
| --- | --- |
| `AJODispatcher` | The heartbeat. Queries what is due and hands it to the launcher. |
| `AJOLauncher` | Decides what actually starts: breaker, dependency, overlap, dry run, throttle, minute deferral. |
| `AJOWindow` | The Start Date / End Date rule. See below. |
| `AJOCron` | Quartz-subset cron evaluator, always in an explicit time zone. |
| `AJOLegacyAdapter` | Runs an existing `Schedulable` / `Batchable` / `Queueable` class unchanged. |
| `AJORunLogger` | Opens, closes and reconciles run records; drives the circuit breaker. |
| `AJOSupervisor` | Daily sweep: re-arms missing heartbeats, reconciles async runs, reaps stuck ones, retires expired jobs, purges the log. |
| `AJOThrottle` | Keeps the org under the five-concurrent-batch ceiling. |
| `AJOInstaller` | Arms and disarms the seven permanent slots. |
| `AJODemoBatch`, `AJODemoDualScheduler` | Demonstration jobs. Their query locators are deliberately bounded (`LIMIT 200` / `LIMIT 50`): an unbounded locator over a real org's user table makes fifteen `execute()` calls where a test method allows one, so the suite passed in an 11-user playground and failed in a 2,885-user sandbox. |
| `AJOAdminController` | Back end for the `ajoJobConsole` LWC: the status headline, the preview of the next check, the activity table, and the permission gate. |

## Activation window

A job can be scheduled to run only between two dates — the case this was built
for is a bounded data correction that should run nightly for ten days and then
stop on its own, with nobody having to remember to switch it off.

| Field | Type | Meaning |
| --- | --- | --- |
| `AJO_StartDate__c` | Date | First day the job may run. Blank means "as soon as it is enabled". |
| `AJO_EndDate__c` | Date | Last day the job may run, **inclusive**. Blank means "for the lifetime of the org". |
| `AJO_Enabled__c` | Checkbox | The manual pause switch. |
| `AJO_IsActive__c` | Formula (Checkbox) | Derived: `Enabled && StartDate <= today <= EndDate`. |
| `AJO_WindowStatus__c` | Formula (Text) | `Paused` / `Starts <date>` / `Expired <date>` / `Active, no end date` / `Active, N day(s) left`. |

To schedule something for ten days: set the Start Date to today and the End Date
to today + 9. To run indefinitely: leave the End Date blank.

The rule is expressed in three places, and `AJOWindowTest.formulaFieldAgreesWithApex`
asserts all three against the same records so they cannot drift apart:

1. The `AJO_IsActive__c` formula, so record pages, list views and reports agree
   with the dispatcher.
2. `AJOWindow.SOQL_FILTER`, used by the heartbeat query. Real date comparisons
   rather than the formula field, because date fields are indexed and the
   heartbeat query has to stay selective.
3. `AJOWindow.isActive()`, for the code paths that already hold the record.

Behaviour that follows from it:

- `AJOLauncher.advance()` clears `AJO_NextRunAt__c` and sets the status to
  `Expired` once the next occurrence would fall past the End Date, so a finished
  job is not re-examined by every heartbeat forever.
- A job whose window has not opened yet is scheduled **from its Start Date**, so
  the Next Run column never advertises a run the job would refuse.
- `AJOAdminController.runNowById` refuses a job outside its window. These jobs
  process a bounded slice of data; the dates are the guarantee.
- `AJODeferredRunner` re-checks the window before starting, because up to ten
  minutes pass between a job being queued and its exact minute arriving.
- `AJOSupervisor.expireLapsed()` retires lapsed jobs daily. The dispatcher
  already refuses them — this is what makes a finished job *look* finished
  instead of reading as `Idle` forever.
- Day boundaries resolve in the automation user's time zone: `Date.today()` in
  Apex, `TODAY` in SOQL and `TODAY()` in the formula all agree. Cron *minutes*
  are still evaluated in each job's own `AJO_TimeZoneSidKey__c`.

## Getting started in an org

```bash
sf project deploy start -d force-app -o <alias>
sf org assign permset -n AJOJobOrchestrationAdmin -o <alias>
sf apex run test -n AJOWindowTest -n AJOFrameworkTest -n AJOCronTest -n AJOConsoleTest -o <alias>
```

The permission set assignment above is **not optional**. A Metadata API field
deploy carries no field-level security at all, so on a fresh org every field
lands invisible to every profile — including System Administrator. Only the
fields marked `Required` on a page layout carry implicit access, which is why an
unassigned org can read `AJO_ApexClassName__c`, `AJO_CronExpression__c`,
`AJO_ExecutionType__c` and `AJO_Job__c` and nothing else. The symptom is
`No such column 'AJO_Enabled__c' on entity 'AJOJob__c'` from Apex that plainly
compiles, and every test failing with *fields being inaccessible*. Assign
`AJOJobOrchestrationAdmin` and it goes away.

Then open the **Apex Job Orchestration** app, go to the **Apex Job Console** tab,
open **Setup** and choose *Install*. *Create demo jobs* on the same tab seeds one
job per execution shape, including two that demonstrate the activation window.

`force-app/main/default/settings/Deployment.settings-meta.xml` enables **Allow
deployments of components when corresponding Apex jobs are pending or in
progress**. Without it, deploying Apex while the scheduler is installed fails
with *"This schedulable class has jobs pending or in progress"*, and the only
alternative is to uninstall, deploy, and install again — which aborts the
`CronTrigger` registrations and loses their fire history.

## The console

Five tabs, split by who needs them. The first four are for whoever operates the
jobs; **Setup** is for whoever installed the framework and is gated on a custom
permission.

| Tab | Answers |
| --- | --- |
| **Next up** | What the next scheduled check will pick up, and for each job whether it will actually start. The verdict runs the launcher's own gates in the launcher's own order without launching anything, so *"its previous run is still going, so this one is skipped"* is visible before the fact rather than afterwards in the log. |
| **Activity** | Every run in one table, filtered by outcome, by the last 24 hours, by one job, or by a single scheduled check. `AJO_HeartbeatSlot__c` was recorded on every run from the start and never shown; it is the *Check* column, which is what makes "what did the :20 check do" answerable. |
| **Errors** | Failed and timed-out runs only, with the full error and the stack trace — `AJO_StackTrace__c` never used to reach the UI at all — and *Run it again* on the row. |
| **Jobs** | The configuration, six columns wide. Four row actions; deleting a job now lives inside the editor rather than one slip away from *Run it now*. |
| **Setup** | Install, uninstall, run the tidy-up by hand, seed demo jobs, and the framework's own diagnostics: slot use, batch ceiling, log size, the registered `CronTrigger` entries. |

The header carries one sentence — *"Running normally. 7 jobs are active; next
check at 14:20."* — built in `AJOAdminController.applySummary` so the console, a
report and a future digest email cannot disagree about what "running normally"
means. Beside it sits the only control most people need: **Pause all jobs**.

### Vocabulary

The framework's internal words leaked into the UI, where they meant nothing to
the people using it. The mechanics are unchanged; only the labels moved.

| Internally | In the console |
| --- | --- |
| Arm / disarm the framework | Install / uninstall the scheduler |
| Fire a heartbeat now | *removed* — see below |
| Run the supervisor | Run maintenance now |
| Engage the kill switch | Pause all jobs |
| Heartbeat | Scheduled check — "jobs are looked at every 10 minutes" |
| Scheduled Apex slot | Salesforce scheduled-job slot |
| Dry run / shadow mode | Test mode — records what it would do, runs nothing |
| Overlap policy: Skip / Queue / Allow | If the last run is still going: skip this run / try again at the next check / start it anyway |
| Pinned to its own CronTrigger | Must start on its exact minute |
| Reconciled / reaped / stuck | Closed out / timed out |
| Suspended | Switched off after failures |
| Expired | Finished — past its end date |

*Fire a heartbeat now* is gone. It called `AJODispatcher.run(0)` synchronously
inside the clicking user's transaction — reconciling runs, querying what was due
and really launching it, batches included, against that user's governor limits.
It existed to demonstrate the PoC without waiting for the clock, and it is still
available for that from anonymous Apex:

```bash
sf apex run -o <alias> <<< "System.debug(AJODispatcher.run(0));"
```

Per-job **Run it now** covers the legitimate case, and it still refuses a job
outside its start and end dates.

### The permission gate

`AJOJobOrchestrationViewer` grants access to `AJOAdminController`, and every
`@AuraEnabled` method on it is callable directly from the browser. Hiding the
Setup tab was therefore never a control: before this, a read-only user could
call `disarmFramework()` and stop every scheduled job in the org.

Installing, uninstalling, pausing everything, running maintenance and seeding
demo data now require the **Administer Apex Job Orchestration** custom
permission (`AJO_Administer`), granted by `AJOJobOrchestrationAdmin`, with a
fallback for any user holding Modify All Data so an administrator cannot lock
themselves out. Job configuration follows ordinary object permissions on
`AJOJob__c`, so the read-only Viewer set is read-only in fact and not only in
appearance. `AJOConsoleTest.aReadOnlyUserCannotTouchTheFramework` asserts it as
a real `System.runAs` user rather than trusting the markup.

## Retiring the old OJO components

The AJO module is live and the old `OJO*` components are disarmed and inert, but
they are still in the org. `manifest/retire-ojo/` removes them in two ordered
steps — Apex and UI first, then the objects, because the objects cannot be
dropped while Apex still references them:

```bash
# the old framework must be off its slots before its classes can be deleted
sf apex run -o <alias> <<< "System.debug(OJOInstaller.disarm());"

sf project deploy start -o <alias> --metadata-dir manifest/retire-ojo/1-components
sf project deploy start -o <alias> --metadata-dir manifest/retire-ojo/2-objects
```

Step 2 destroys data: 8 `OJOJob__c` records and roughly 1,000 `OJOJobRun__c` log
rows. The configuration is already migrated; CSV exports of both are kept
alongside the manifests. The run log was deliberately not migrated — it is
retention-managed transient data (14 days for successes, 90 for failures) and its
parent keys would not survive the move.

---

# Salesforce DX Project

Salesforce DX is a development approach that brings source-driven development, team collaboration, and continuous integration to the Salesforce Platform. Instead of working directly in an org through a web browser, you work with metadata as source files in a local DX project, track changes in version control, and deploy through automated processes.

This project template gets you started with the tools and structure you need to build Salesforce applications using source control, scratch orgs, and the Salesforce CLI.

## Prerequisites

Before you start, make sure you have:

- **Salesforce CLI** - Download from [developer.salesforce.com/tools/salesforcecli](https://developer.salesforce.com/tools/salesforcecli). See [Install Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm) for details.
- **VS Code with Salesforce Extension Pack** - See [Installation Instructions](https://developer.salesforce.com/docs/platform/sfvscode-extensions/guide/install.html) for details. Includes the Agentforce Vibes extension.
- **A development org** - Sign up for a free Developer Edition org [here](https://developer.salesforce.com/signup).
- **Dev Hub enabled** (optional, required to create scratch orgs) - You can enable Dev Hub in your development org under Setup > Dev Hub.  See [Provide Developers Access to Salesforce DX Tools](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_setup_dx_tools.htm).

## Project Structure

Your DX project follows this structure:

- **`force-app/main/default/`** - Your metadata source files live in this default package directory. You can configure additional package directories in the `sfdx-project.json` file.
- **`config/`** - Scratch org definitions and project settings
- **`scripts/`** - Automation scripts for common tasks
- **`sfdx-project.json`** - Project manifest that defines package directories, namespace, API version, and other project-level settings

See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm).

## Get Started

Ready to start developing? The [Get Started with Salesforce DX](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_get_started_dx.htm) guide walks you through your first project, from creating a scratch org to creating a simple Apex class or LWC to deploying your code to a sandbox.

## Common Salesforce CLI Commands

Here are common CLI commands that you'll use the most:

- `sf org login web`: Authorize an org
- `sf org open`: Open your org in a browser
- `sf org create scratch`: Create a scratch org
- `sf project deploy start`: Deploy metadata to your org
- `sf project retrieve start`: Retrieve metadata from your org
- `sf template generate <artifact>`: Scaffold new components, such as Apex classes and triggers, LWC components, Lightning apps, and more
- `sf apex <command>`: Run Apex tests, run anonymous Apex blocks, and view logs
- `sf data <command>`: Work with test data
- `sf alias <command>`: Manage org aliases
- `sf config <command>`: Configure CLI settings

## Use Agentforce Vibes to Build Lightning Apps

Transform your ideas into custom Lightning apps that extend CRM workflows directly in Lightning Experience. Through natural conversations with Agentforce Vibes, implement custom objects and fields, complex business logic, and dynamic UI components. See [Build a Lightning App Using Agentforce Vibes](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/lexapp-overview.html).

## Additional Resources

- [Agentforce Vibes Developer Guide](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/einstein-overview.html)
- [Salesforce CLI Installation Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/)
- [Salesforce CLI Plugin Development Guide](https://developer.salesforce.com/docs/platform/salesforce-cli-plugin/guide/conceptual-overview.html)
- [Salesforce VS Code Extensions Documentation](https://developer.salesforce.com/tools/vscode/)

