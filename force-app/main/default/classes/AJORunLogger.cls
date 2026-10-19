/**
 * Opens, closes and reconciles run records, and drives the circuit breaker.
 * Retention is enforced by AJOSupervisor — the source org is at 212% of its data
 * storage allocation, so an unbounded log is not an option.
 */
public with sharing class AJORunLogger {

    public static AJOJobRun__c open(AJOJob__c job, Datetime scheduledFor,
                                    String triggeredBy, Integer slot) {
        AJOJobRun__c run = new AJOJobRun__c(
            AJO_Job__c          = job.Id,
            AJO_StartedAt__c    = Datetime.now(),
            AJO_Status__c       = 'Running',
            AJO_TriggeredBy__c  = triggeredBy,
            AJO_ScheduledFor__c = scheduledFor,
            AJO_HeartbeatSlot__c = slot
        );
        insert run;
        return run;
    }

    public static void close(AJOJobRun__c run, String status, Id asyncJobId) {
        run.AJO_FinishedAt__c = Datetime.now();
        run.AJO_Status__c     = status;
        run.AJO_AsyncApexJobId__c = asyncJobId;
        run.AJO_DurationSec__c = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);
        update patch(run);
    }

    /**
     * AJO_Job__c is a non-reparentable master-detail field, so it cannot appear in
     * an update payload — the platform rejects the whole DML with
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY. Writing through a fresh instance
     * keyed on Id sends only the fields that are actually mutable.
     */
    public static AJOJobRun__c patch(AJOJobRun__c run) {
        return new AJOJobRun__c(
            Id                = run.Id,
            AJO_Status__c         = run.AJO_Status__c,
            AJO_StartedAt__c      = run.AJO_StartedAt__c,
            AJO_FinishedAt__c     = run.AJO_FinishedAt__c,
            AJO_DurationSec__c    = run.AJO_DurationSec__c,
            AJO_AsyncApexJobId__c = run.AJO_AsyncApexJobId__c,
            AJO_ItemsProcessed__c = run.AJO_ItemsProcessed__c,
            AJO_ItemsFailed__c    = run.AJO_ItemsFailed__c,
            AJO_BatchSize__c      = run.AJO_BatchSize__c,
            AJO_Message__c        = run.AJO_Message__c,
            AJO_ErrorMessage__c   = run.AJO_ErrorMessage__c,
            AJO_StackTrace__c     = run.AJO_StackTrace__c
        );
    }

    public static void fail(AJOJobRun__c run, Exception e) {
        run.AJO_FinishedAt__c  = Datetime.now();
        run.AJO_Status__c      = 'Failed';
        run.AJO_ErrorMessage__c = truncate(e.getTypeName() + ': ' + e.getMessage(), 4000);
        run.AJO_StackTrace__c   = truncate(e.getStackTraceString(), 8000);
        run.AJO_DurationSec__c  = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);
        update patch(run);
    }

    /** A run that never started — throttled, skipped, or a dry run. */
    public static void note(AJOJob__c job, Datetime scheduledFor, String status,
                            String message, Integer slot) {
        insert new AJOJobRun__c(
            AJO_Job__c           = job.Id,
            AJO_StartedAt__c     = Datetime.now(),
            AJO_FinishedAt__c    = Datetime.now(),
            AJO_DurationSec__c   = 0,
            AJO_Status__c        = status,
            AJO_TriggeredBy__c   = 'Heartbeat',
            AJO_ScheduledFor__c  = scheduledFor,
            AJO_HeartbeatSlot__c = slot,
            AJO_ErrorMessage__c  = truncate(message, 4000)
        );
    }

    /**
     * Async work outlives the dispatcher transaction, so the run record is left
     * open with its AsyncApexJobId and closed here on a later heartbeat.
     */
    public static Integer reconcile() {
        List<AJOJobRun__c> openRuns = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c
            FROM   AJOJobRun__c
            WHERE  AJO_Status__c = 'Running'
              AND  AJO_AsyncApexJobId__c != null
              AND  AJO_StartedAt__c = LAST_N_DAYS:3
            LIMIT  500
        ];
        if (openRuns.isEmpty()) { return 0; }

        Set<Id> asyncIds = new Set<Id>();
        for (AJOJobRun__c r : openRuns) {
            try { asyncIds.add((Id) r.AJO_AsyncApexJobId__c); } catch (Exception e) { /* stale id */ }
        }
        if (asyncIds.isEmpty()) { return 0; }

        Map<Id, AsyncApexJob> jobs = new Map<Id, AsyncApexJob>([
            SELECT Id, Status, ExtendedStatus, NumberOfErrors,
                   JobItemsProcessed, TotalJobItems, CompletedDate
            FROM   AsyncApexJob
            WHERE  Id IN :asyncIds
        ]);

        List<AJOJobRun__c> toUpdate = new List<AJOJobRun__c>();
        Map<Id, String> jobOutcome = new Map<Id, String>();

        for (AJOJobRun__c r : openRuns) {
            AsyncApexJob a = jobs.get((Id) r.AJO_AsyncApexJobId__c);
            if (a == null) { continue; }
            if (a.Status == 'Completed' || a.Status == 'Failed' || a.Status == 'Aborted') {
                r.AJO_FinishedAt__c   = a.CompletedDate != null ? a.CompletedDate : Datetime.now();
                r.AJO_DurationSec__c  = seconds(r.AJO_StartedAt__c, r.AJO_FinishedAt__c);
                r.AJO_ItemsProcessed__c = a.JobItemsProcessed;
                r.AJO_ItemsFailed__c    = a.NumberOfErrors;
                Boolean ok = (a.Status == 'Completed' && a.NumberOfErrors == 0);
                r.AJO_Status__c = ok ? 'Success' : 'Failed';
                // AsyncApexJob counts chunks, not records: a 10,000-record batch
                // at a scope of 200 reports 50. Saying so on the record stops
                // Items Processed being read as a record count.
                if (r.AJO_Message__c == null || r.AJO_Message__c.startsWith('Launched as')) {
                    r.AJO_Message__c = 'Finished ' + a.JobItemsProcessed + ' of '
                        + a.TotalJobItems + ' batch(es)'
                        + (r.AJO_BatchSize__c == null
                           ? '' : ' at ' + r.AJO_BatchSize__c.intValue() + ' records each')
                        + '; ' + a.NumberOfErrors + ' error(s).';
                }
                if (!ok) {
                    r.AJO_ErrorMessage__c = truncate(
                        String.isBlank(a.ExtendedStatus)
                            ? a.Status + ' with ' + a.NumberOfErrors + ' errors'
                            : a.ExtendedStatus, 4000);
                }
                toUpdate.add(patch(r));
                jobOutcome.put(r.AJO_Job__c, r.AJO_Status__c);
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
            settleJobs(jobOutcome);
        }
        return toUpdate.size();
    }

    /**
      * Lets a batch close its own run record with real record counts.
      *
      * Call it from finish(). Reconciliation can only read AsyncApexJob, which
      * counts chunks — a 10,000 record batch at a scope of 200 reports 50 — so
      * Items Processed never meant what people read it to mean. A batch knows
      * the true figures and this is how it hands them over. Closing the run here
      * also takes it out of reconcile()'s reach, since that only considers runs
      * still marked Running, so nothing overwrites what you report.
      *
      * Safe to call from any batch, whether or not AJO launched it: when no open
      * run matches the job id it does nothing and returns false.
      */
    public static Boolean report(Id asyncJobId, Integer itemsProcessed,
                                 Integer itemsFailed, String message) {
        if (asyncJobId == null) { return false; }
        List<AJOJobRun__c> runs = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c
            FROM   AJOJobRun__c
            WHERE  AJO_AsyncApexJobId__c = :String.valueOf(asyncJobId)
              AND  AJO_Status__c = 'Running'
            LIMIT  1
        ];
        if (runs.isEmpty()) { return false; }

        AJOJobRun__c run = runs[0];
        run.AJO_ItemsProcessed__c = itemsProcessed;
        run.AJO_ItemsFailed__c    = itemsFailed;
        if (String.isNotBlank(message)) { run.AJO_Message__c = truncate(message, 4000); }
        run.AJO_FinishedAt__c  = Datetime.now();
        run.AJO_DurationSec__c = seconds(run.AJO_StartedAt__c, run.AJO_FinishedAt__c);

        Boolean ok = (itemsFailed == null || itemsFailed == 0);
        run.AJO_Status__c = ok ? 'Success' : 'Failed';
        if (!ok && String.isBlank(run.AJO_ErrorMessage__c)) {
            run.AJO_ErrorMessage__c = itemsFailed + ' record(s) could not be processed.';
        }
        update patch(run);
        settleJobs(new Map<Id, String>{ run.AJO_Job__c => run.AJO_Status__c });
        return true;
    }

    /** Applies a run outcome back onto the job: last-run fields and the breaker. */
    public static void settle(Id jobId, String outcome, Decimal durationSec, Id asyncJobId) {
        settleJobs(new Map<Id, String>{ jobId => outcome });
    }

    private static void settleJobs(Map<Id, String> outcomes) {
        if (outcomes.isEmpty()) { return; }
        List<AJOJob__c> jobs = [
            SELECT Id, AJO_Status__c, AJO_ConsecutiveFailures__c, AJO_MaxConsecutiveFailures__c,
                   AJO_LastRunStatus__c, AJO_LastRunAt__c, AJO_LastDurationSec__c,
                   AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c, AJO_NextRunAt__c
            FROM   AJOJob__c
            WHERE  Id IN :outcomes.keySet()
        ];
        for (AJOJob__c j : jobs) {
            String outcome = outcomes.get(j.Id);
            j.AJO_LastRunStatus__c = outcome;
            j.AJO_LastRunAt__c     = Datetime.now();

            if (outcome == 'Failed') {
                j.AJO_ConsecutiveFailures__c =
                    (j.AJO_ConsecutiveFailures__c == null ? 0 : j.AJO_ConsecutiveFailures__c) + 1;
                Decimal cap = j.AJO_MaxConsecutiveFailures__c;
                if (cap != null && cap > 0 && j.AJO_ConsecutiveFailures__c >= cap) {
                    j.AJO_Status__c = 'Suspended';
                } else {
                    j.AJO_Status__c = 'Idle';
                }
            } else {
                j.AJO_ConsecutiveFailures__c = 0;
                if (j.AJO_Status__c != 'Suspended') { j.AJO_Status__c = 'Idle'; }
            }

            // A job whose window closed while its last run was in flight settles
            // straight into Expired. Suspended outranks it: a circuit-broken job
            // still needs a human to look at it.
            if (j.AJO_Status__c != 'Suspended' && AJOWindow.hasExpired(j)) {
                j.AJO_Status__c = 'Expired';
                j.AJO_NextRunAt__c = null;
            }
        }
        update jobs;
    }

    public static Decimal seconds(Datetime a, Datetime b) {
        if (a == null || b == null) { return null; }
        return ((Decimal) (b.getTime() - a.getTime())) / 1000;
    }

    private static String truncate(String s, Integer n) {
        if (s == null) { return null; }
        return s.length() <= n ? s : s.substring(0, n);
    }
}